// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// 单次布局尝试的结果，供日志与诊断使用。
public struct WindowLayoutOutcome: Sendable, Equatable {
    public let source: String
    public let command: WindowLayoutCommand
    public let identity: WindowIdentity
    public let target: CGRect
    public let actual: CGRect
    public let success: Bool
    public let isRestore: Bool
    /// 失败时是否保留了还原记录（成功还原才清除）。
    public let recordRetained: Bool
    public let frames: Int
    public let elapsedMilliseconds: Double

    public init(source: String, command: WindowLayoutCommand, identity: WindowIdentity,
                target: CGRect, actual: CGRect, success: Bool, isRestore: Bool,
                recordRetained: Bool, frames: Int, elapsedMilliseconds: Double) {
        self.source = source
        self.command = command
        self.identity = identity
        self.target = target
        self.actual = actual
        self.success = success
        self.isRestore = isRestore
        self.recordRetained = recordRetained
        self.frames = frames
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// 提前接管窗口布局操作，用动画直接调整到「避开程序坞」的目标尺寸，
/// 避免系统先最大化、再突然收缩的观感。
///
/// 设计要点（均由原型实测得出，见 `docs/development-experience.md`）：
/// - 无法可靠识别时一律放行原操作，绝不吞掉用户输入。
/// - 命中查询预算 100ms；系统对该查询的 p99 实测 46.7–48.6ms，50ms 会误拒。
/// - 命中元素的 PID 必须属于目标窗口，否则视为被其它窗口遮挡并放行。
/// - 窗口身份只用 pid 与窗口 ID；`launchDate` 对部分进程恒为 nil。
/// - 位置与尺寸分段提交，并在动画结束时补写一次，绕开系统对合并写入的拒绝。
/// - 菜单关闭会重建窗口的 AX 元素，动画前必须重新解析。
public final class WindowLayoutInterceptor {

    /// 事件来源标识，写入日志便于区分入口。
    public enum Source: String, Sendable {
        case optionGreen = "option-green"
        case titleDoubleClick = "title-double-click"
        case systemKey = "system-key"
        case windowMenu = "window-menu"
    }

    /// 诊断与结果回调；始终在主线程调用。
    public var onLog: (@MainActor (String) -> Void)?
    public var onOutcome: (@MainActor (WindowLayoutOutcome) -> Void)?
    /// 提供给布局计算的屏幕列表。在主线程调用（事件 tap 回调即在主线程），
    /// 解析结果随事务传入动画队列，避免动画线程回头访问主线程。
    public var screensProvider: (@MainActor () -> [WindowLayoutScreen])?

    /// 前台应用或屏幕配置变化后刷新窗口观测。调用方：应用激活通知、屏幕参数通知。
    public func refreshObservation() {
        observeFrontmostApplication()
    }

    /// 当前布局屏列表；供诊断使用。
    @MainActor
    public var currentScreens: [WindowLayoutScreen] { screensProvider?() ?? [] }

    private let reservations: DockReservationProviding
    private let queue = DispatchQueue(label: "com.powerspaces.window-layout")

    /// 前台应用窗口的几何观测，用于处理不由事件 tap 触发的改尺寸
    /// （第三方最大化、Option＋拖动）。观测覆盖前台应用的全部窗口，
    /// 不要求先被接管过一次；纠正规则限定为「变大导致的越界」，
    /// 因此手动移动或缩小窗口不受影响。
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: Set<WindowIdentity> = []
    /// 每个被观测窗口上一次已知的几何，用于判断本次变化是「变大」还是移动/缩小。
    private var observedFrames: [WindowIdentity: CGRect] = [:]
    private var snapWorkItems: [WindowIdentity: DispatchWorkItem] = [:]
    /// 指针是否处于按下状态。拖动/缩放过程中不纠正窗口，避免与用户抢几何；
    /// 松手后由左键抬起分支立即纠正一次。
    private var pointerIsDown = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var swallowMouseUp = false
    private var swallowedKeys = Set<Int64>()
    private var generationSequence = 0
    /// 已接管窗口的还原快照与代际，受 `stateLock` 保护。
    private var snapshots: [WindowIdentity: (element: AXUIElement, restore: CGRect, lastWritten: CGRect)] = [:]
    private var generations: [WindowIdentity: Int] = [:]
    private var activeTargets: [WindowIdentity: Bool] = [:]
    private let stateLock = NSLock()

    /// 识别整条链的截止时间，避免在事件回调里长时间阻塞。
    private let recognitionBudgetSeconds: Double = 0.10

    public init(reservations: DockReservationProviding) {
        self.reservations = reservations
    }

    public var isRunning: Bool { tap != nil }

    // MARK: - 生命周期

    /// 创建事件 tap 并接入主运行循环；失败时返回 false，调用方应保持原行为。
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<WindowLayoutInterceptor>.fromOpaque(context).takeUnretainedValue()
                return interceptor.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        observeFrontmostApplication()
        return true
    }

    /// 停止拦截并取消所有进行中的动画；已接管的窗口保持当前几何。
    public func stop() {
        cancelAnimations(reason: "stop")
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        observedWindows.removeAll()
        observedFrames.removeAll()
        for (_, item) in snapWorkItems { item.cancel() }
        snapWorkItems.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
    }

    /// 取消所有进行中的动画；正在执行的 AX 写入返回后不再继续。
    public func cancelAnimations(reason: String) {
        stateLock.lock()
        for identity in activeTargets.keys {
            generations[identity, default: 0] += 1
            log("CANCEL identity=\(identity.logDescription) reason=\(reason)")
        }
        activeTargets.removeAll()
        stateLock.unlock()
    }

    // MARK: - 事件处理

    /// 事件 tap 回调：只吞掉已确认的接管，其余原样放行。
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            cancelAnimations(reason: "tap-disabled")
            log("TAP_DISABLED type=\(type.rawValue)")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            return handleKey(type, event)
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            pointerIsDown = false
            return nil
        case .leftMouseUp:
            // 松手即纠正：拖动过程中不打扰用户，抬起后立刻贴合程序坞。
            pointerIsDown = false
            scheduleSnapCheck(after: 0.0)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            return handleMouseDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 左键按下：分别识别 Option＋绿色按钮、标题栏双击与菜单命令。
    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        pointerIsDown = true
        // 指针按下即取消进行中的动画，避免用户拖动与动画互相打架。
        let optionClick = event.flags.contains(.maskAlternate)
        let doubleClick = !optionClick && event.getIntegerValueField(.mouseEventClickState) == 2
        guard event.flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty else {
            cancelAnimations(reason: "pointer-down-modifier")
            return passthrough
        }
        cancelAnimations(reason: "pointer-down")

        let point = event.location
        guard let hit = element(at: point) else { return passthrough }
        // 遮挡判定：命中元素必须属于目标应用，否则放行。
        guard let hitPID = pid(of: hit) else { return passthrough }

        if !optionClick && !doubleClick {
            if handleWindowMenu(hit, hitPID: hitPID) { swallowMouseUp = true; return nil }
            return passthrough
        }
        guard let window = enclosingWindow(of: hit, pid: hitPID) else { return passthrough }
        guard let identity = identity(of: window) else { return passthrough }

        if doubleClick {
            guard isTitleBarBlank(point: point, window: window) else {
                log("REJECT doubleClick notTitleBarBlank point=\(point)")
                return passthrough
            }
            if beginLayout(window: window, identity: identity, command: .fill,
                           source: .titleDoubleClick) {
                swallowMouseUp = true
                return nil
            }
            return passthrough
        }

        // Option＋绿色按钮：先按元素同一性判断，再用角色／子角色与命中范围补足——
        // 同一枚绿色按钮在部分应用会返回不同的 AX 代理对象（实测邮箱大师）。
        let controls = [kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
            .compactMap { attribute(window, $0) }
        let identityMatch = controls.contains { CFEqual($0, hit) }
        let role = attribute(hit, kAXRoleAttribute) as? String
        let subrole = attribute(hit, kAXSubroleAttribute) as? String
        let semanticMatch = role == kAXButtonRole
            && (subrole == "AXFullScreenButton" || subrole == "AXZoomButton")
            && (frame(of: hit)?.contains(point) ?? false)
        guard identityMatch || semanticMatch else {
            log("REJECT greenButton identity=\(identityMatch) semantic=\(semanticMatch)")
            return passthrough
        }
        let command: WindowLayoutCommand = isOwned(identity) ? .restore : .fill
        if beginLayout(window: window, identity: identity, command: command,
                       source: .optionGreen) {
            swallowMouseUp = true
            return nil
        }
        return passthrough
    }

    /// 系统平铺快捷键：只接管 Fn＋Control＋F（填充）与 R（还原）。
    ///
    /// 方向键不接管——外接键盘的方向键可能自带 `maskSecondaryFn`，
    /// 与真正的 Fn＋Control 在事件层无法区分，接管会吞掉 Ctrl＋方向键。
    private func handleKey(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, swallowedKeys.remove(code) != nil { return nil }
        if type == .keyDown, swallowedKeys.contains(code) { return nil }
        guard type == .keyDown,
              event.flags.contains([.maskControl, .maskSecondaryFn]),
              event.flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty,
              let command = Self.keyCommands[code],
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return passthrough }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        guard let focusedValue = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return passthrough }
        let window = focusedValue as! AXUIElement
        guard let identity = identity(of: window) else { return passthrough }
        if beginLayout(window: window, identity: identity, command: command, source: .systemKey) {
            swallowedKeys.insert(code)
            return nil
        }
        return passthrough
    }

    /// Fn＋Control 快捷键到命令的固定映射；未列出的组合一律放行。
    ///
    /// **不再接管方向键**：实测外接键盘的方向键自带 `maskSecondaryFn` 标志
    /// （未按 Fn 也会满足条件），在事件层无法与真正的 Fn＋Control 区分，
    /// 会吃掉用户原本的 Ctrl＋方向键（切桌面／系统平铺）。方向键交回系统。
    private static let keyCommands: [Int64: WindowLayoutCommand] = [
        3: .fill,        // F
        15: .restore,    // R
    ]
}

// MARK: - 识别

extension WindowLayoutInterceptor {

    /// 命中查询。预算内失败一律返回 nil，由调用方放行原操作。
    private func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Float(recognitionBudgetSeconds))
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        if error != .success {
            log("REJECT hitError=\(error.rawValue)")
            return nil
        }
        return hit
    }

    /// 自命中元素上溯到窗口；超过限制则视为无法确认。
    private func enclosingWindow(of element: AXUIElement, pid: pid_t) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if attribute(node, kAXRoleAttribute) as? String == kAXWindowRole { return node }
            guard let parent = attribute(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    /// 标题栏空白判定：点必须落在「窗口顶边 → 交通灯按钮底边」的带内，
    /// 且不在任何交通灯按钮上。
    ///
    /// 不能用「命中元素的角色是窗口或标题栏」来判断：实测该区域在真实应用里
    /// 多报告为 AXStaticText、AXRadioButton/AXTabButton 或 AXButton，
    /// 全宽窗口上纯空白区仅约 12pt 宽，按角色判定会让绝大多数双击被拒。
    private func isTitleBarBlank(point: CGPoint, window: AXUIElement) -> Bool {
        guard let bounds = frame(of: window), bounds.contains(point) else { return false }
        let controlFrames = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute,
                             kAXZoomButtonAttribute, kAXFullScreenButtonAttribute]
            .compactMap { attribute(window, $0) }
            .filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
            .compactMap { frame(of: $0 as! AXUIElement) }
        guard !controlFrames.isEmpty else { return false }
        let controlsBottom = controlFrames.map(\.maxY).max() ?? bounds.minY + 30
        guard point.y <= controlsBottom else { return false }
        return !controlFrames.contains { $0.insetBy(dx: -5, dy: -5).contains(point) }
    }

    private func identity(of window: AXUIElement) -> WindowIdentity? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != getpid() else { return nil }
        guard let windowID = windowID(of: window) else { return nil }
        return WindowIdentity(pid: pid, windowID: windowID)
    }

    private func windowID(of window: AXUIElement) -> CGWindowID? {
        var identifier: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func isOwned(_ identity: WindowIdentity) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshots[identity] != nil
    }
}

// MARK: - 菜单识别

extension WindowLayoutInterceptor {

    /// 「窗口」菜单的布局命令映射。
    ///
    /// 来源校验不使用菜单栏归属：实测 Safari 的菜单父链既不连到 `AXMenuBar`，
    /// 也没有「窗口」菜单栏项。改用「最外层菜单必须包含多个系统布局命令成员」
    /// 这一集合特征，并要求命中元素属于目标应用。
    private func handleWindowMenu(_ hit: AXUIElement, hitPID: pid_t) -> Bool {
        guard attribute(hit, kAXRoleAttribute) as? String == kAXMenuItemRole,
              (attribute(hit, kAXEnabledAttribute) as? Bool) == true,
              let title = attribute(hit, kAXTitleAttribute) as? String,
              !Self.excludedMenuTitles.contains(title) else { return false }

        var current: AXUIElement? = hit
        var topMenu: AXUIElement?
        var innerMenu: AXUIElement?
        var parentMenu: AXUIElement?
        var path: [String] = []
        for _ in 0..<12 {
            guard let node = current else { break }
            let role = attribute(node, kAXRoleAttribute) as? String
            if role == kAXMenuRole {
                if topMenu == nil { topMenu = node }
                if parentMenu == nil { parentMenu = node }
                if innerMenu == nil { innerMenu = node }
            } else if role == kAXMenuItemRole,
                      let name = attribute(node, kAXTitleAttribute) as? String, !name.isEmpty {
                path.append(name)
            }
            guard let parent = attribute(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        guard let menu = topMenu else { return false }

        // 歧义消解：同一菜单内用禁用的分组标题（二等分／四等分／排列）划分区段，
        // 「左侧」等标题在多个区段里含义不同，必须看该标题之前最近的分组标题。
        var section = ""
        if let siblings = parentMenu.flatMap({ attribute($0, kAXChildrenAttribute) as? [AXUIElement] }) {
            for sibling in siblings {
                if CFEqual(sibling, hit) { break }
                let name = attribute(sibling, kAXTitleAttribute) as? String ?? ""
                if Self.sectionTitles.contains(name) { section = name }
            }
        }
        guard let command = Self.command(title: title, section: section) else { return false }

        let members = (attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .map { attribute($0, kAXTitleAttribute) as? String ?? "" }
        guard members.filter({ Self.layoutMarkers.contains($0) }).count >= 2 else {
            log("REJECT menu notLayoutMenu top=\(members.prefix(6).joined(separator: "|"))")
            return false
        }
        guard pid(of: hit) == hitPID, hitPID != getpid() else { return false }
        guard let focusedValue = attribute(AXUIElementCreateApplication(hitPID), kAXFocusedWindowAttribute),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let window = focusedValue as! AXUIElement
        guard let identity = identity(of: window) else { return false }
        // 菜单取消必须作用在最内层菜单上，否则返回 errAECoercionFail(-25204)。
        return beginLayout(window: window, identity: identity, command: command,
                           source: .windowMenu, menuToCancel: innerMenu ?? menu)
    }

    /// 命令解析：精确项与父级无关，歧义项按所在区段解释。
    public static func command(title: String, section: String) -> WindowLayoutCommand? {
        if let exact = exactCommands[title] { return exact }
        if section == "四等分" || section == "Quarters" { return quarterCommands[title] }
        if section == "二等分" || section == "Halves" { return bisectCommands[title] }
        return nil
    }

    private static let exactCommands: [String: WindowLayoutCommand] = [
        "填充": .fill, "Fill": .fill,
        "缩放": .fill, "Zoom": .fill,
        "恢复上一个大小": .restore, "Return to Previous Size": .restore,
    ]
    private static let bisectCommands: [String: WindowLayoutCommand] = [
        "左侧": .left, "Left": .left,
        "右侧": .right, "Right": .right,
        "顶部": .top, "Top": .top,
        "底部": .bottom, "Bottom": .bottom,
    ]
    private static let quarterCommands: [String: WindowLayoutCommand] = [
        "左上": .topLeft, "Top Left": .topLeft,
        "右上": .topRight, "Top Right": .topRight,
        "左下": .bottomLeft, "Bottom Left": .bottomLeft,
        "右下": .bottomRight, "Bottom Right": .bottomRight,
    ]
    /// 分组标题：只用于消歧，本身不是命令。
    private static let sectionTitles: Set<String> = ["二等分", "Halves", "四等分", "Quarters", "排列", "Arrange"]
    /// 来源校验用的系统布局菜单成员。
    private static let layoutMarkers: Set<String> = [
        "填充", "Fill", "居中", "Center", "移动与调整大小", "Move & Resize",
        "二等分", "Halves", "四等分", "Quarters", "排列", "Arrange",
        "全屏幕平铺", "Full Screen Tile", "左侧", "Right",
        "恢复上一个大小", "Return to Previous Size",
    ]
    /// 必须保持系统行为的项：全屏、屏幕分屏与多窗口排列。
    private static let excludedMenuTitles: Set<String> = [
        "全屏幕平铺", "Full Screen Tile", "屏幕左侧", "屏幕右侧", "Screen Left", "Screen Right",
        "左侧与右侧", "左侧与四等分", "右侧与左侧", "右侧与四等分",
        "顶部与底部", "顶部与四等分", "底部与顶部", "底部与四等分",
        "Left & Right", "Right & Left", "Top & Bottom", "Bottom & Top",
    ]
}

// MARK: - 布局执行

extension WindowLayoutInterceptor {

    /// 提交一次布局事务：解析目标、取消菜单、记录快照并启动动画。
    /// 任一前置条件不满足即返回 false，由调用方放行原操作。
    @discardableResult
    private func beginLayout(window: AXUIElement, identity: WindowIdentity,
                             command: WindowLayoutCommand, source: Source,
                             menuToCancel: AXUIElement? = nil) -> Bool {
        guard let original = frame(of: window) else { return false }
        let availableScreens = MainActor.assumeIsolated { screensProvider?() ?? [] }
        guard let screen = screen(containing: original, in: availableScreens) else { return false }

        let isRestore: Bool
        let target: CGRect
        if command == .restore {
            stateLock.lock()
            let snapshot = snapshots[identity]
            stateLock.unlock()
            guard let snapshot, near(snapshot.lastWritten, original) else {
                log("REJECT restore ownership identity=\(identity.logDescription)")
                return false
            }
            isRestore = true
            target = snapshot.restore
        } else {
            guard let computed = screen.target(for: command) else { return false }
            stateLock.lock()
            let owned = snapshots[identity] != nil && near(snapshots[identity]!.lastWritten, original)
            stateLock.unlock()
            isRestore = false
            target = computed
            _ = owned
        }

        // 取消菜单成功之后才提交事务；失败则原样放行本次点击。
        if let menuToCancel {
            let result = AXUIElementPerformAction(menuToCancel, "AXCancel" as CFString)
            guard result == .success else {
                log("MENU_CANCEL error=\(result.rawValue)")
                return false
            }
        }

        stateLock.lock()
        generationSequence += 1
        let token = generationSequence
        generations[identity] = token
        if snapshots[identity] == nil {
            snapshots[identity] = (window, original, original)
        } else if isRestore {
            snapshots[identity] = (window, snapshots[identity]!.restore, original)
        } else {
            snapshots[identity] = (window, snapshots[identity]!.restore, original)
        }
        activeTargets[identity] = isRestore
        stateLock.unlock()

        if let reservation = screen.reservation {
            log("RESERVE display=\(screen.displayID) edge=\(reservation.edge.rawValue) thickness=\(reservation.thickness) allowed=\(screen.allowedFrame)")
        }
        // 接管后顺带确保该窗口已被观测（前台应用切换时窗口集合会变）。
        observe(identity: identity, window: window)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.30
        let framesPerSecond = Double(screen.frame.isEmpty ? 60 : 60)
        log("INTERCEPT source=\(source.rawValue) command=\(command.rawValue) identity=\(identity.logDescription) generation=\(token) screen=\(screen.frame) original=\(original) target=\(target) restore=\(isRestore)")

        queue.async { [weak self] in
            guard let self else { return }
            // 菜单关闭会重建窗口的 AX 元素；动画开始前按 pid 重新解析，
            // 并对几何读取做短暂重试（实测存在「读取成功但取不到值」的过渡态）。
            let resolved = self.resolveWindow(pid: identity.pid) ?? window
            guard let start = self.readFrame(resolved) else {
                self.log("ABORT noFrame identity=\(identity.logDescription)")
                return
            }
            self.tick(window: resolved, identity: identity, token: token, from: start,
                      target: target, began: ProcessInfo.processInfo.systemUptime,
                      duration: duration, framesPerSecond: framesPerSecond,
                      isRestore: isRestore, source: source, frames: 0)
        }
        return true
    }

    /// 按 pid 重新解析聚焦窗口；失败时保留原引用。
    private func resolveWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let value = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// 几何读取带短暂重试：菜单关闭瞬间窗口元素可能返回成功但取不到值。
    private func readFrame(_ element: AXUIElement) -> CGRect? {
        for attempt in 0..<10 {
            if let result = frame(of: element) { return result }
            Thread.sleep(forTimeInterval: 0.02 * Double(attempt + 1))
        }
        return nil
    }

    /// 单帧推进：按实际时间插值，跳过过时帧，代际变化立即停止。
    private func tick(window: AXUIElement, identity: WindowIdentity, token: Int, from source: CGRect,
                      target: CGRect, began: Double, duration: Double,
                      framesPerSecond: Double, isRestore: Bool, source entry: Source, frames: Int) {
        guard generationMatches(identity, token) else { return }
        guard let current = frame(of: window) else {
            finish(identity: identity, token: token, command: entry, target: target,
                   actual: .zero, success: false, isRestore: isRestore, frames: frames,
                   began: began, cancelled: true)
            return
        }
        // 用户手动改动或外部程序改尺寸时放弃本次动画。
        stateLock.lock()
        let expected = snapshots[identity]?.lastWritten
        stateLock.unlock()
        guard let expected, near(current, expected) else {
            stateLock.lock()
            generations[identity, default: 0] += 1
            activeTargets.removeValue(forKey: identity)
            stateLock.unlock()
            log("CANCEL identity=\(identity.logDescription) reason=external-geometry actual=\(current)")
            return
        }

        let progress = duration == 0 ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
        let eased = (1 - cos(progress * .pi)) / 2
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        let next = CGRect(x: mix(source.minX, target.minX), y: mix(source.minY, target.minY),
                          width: mix(source.width, target.width), height: mix(source.height, target.height))
        guard generationMatches(identity, token) else { return }
        let wrote = write(next, to: window, previous: current)
        guard let actual = frame(of: window) else {
            finish(identity: identity, token: token, command: entry, target: target,
                   actual: .zero, success: false, isRestore: isRestore, frames: frames,
                   began: began, cancelled: true)
            return
        }
        stateLock.lock()
        if snapshots[identity] != nil { snapshots[identity]!.lastWritten = actual }
        stateLock.unlock()

        let finished = progress >= 1 || !wrote
        if finished {
            var finalWrote = wrote
            var finalActual = actual
            if !near(actual, target) {
                // 位置与尺寸分段补写：系统会拒绝把两者放在同一次快速写入里。
                Thread.sleep(forTimeInterval: 0.10)
                guard generationMatches(identity, token) else { return }
                _ = write(target, to: window, previous: actual)
                Thread.sleep(forTimeInterval: 0.10)
                guard generationMatches(identity, token) else { return }
                finalWrote = commitSize(target, to: window)
                finalActual = frame(of: window) ?? actual
            }
            finish(identity: identity, token: token, command: entry, target: target,
                   actual: finalActual, success: finalWrote && near(finalActual, target),
                   isRestore: isRestore, frames: frames + 1, began: began, cancelled: false)
            return
        }
        queue.asyncAfter(deadline: .now() + 1 / max(30, min(120, framesPerSecond))) { [weak self] in
            self?.tick(window: window, identity: identity, token: token, from: source, target: target,
                       began: began, duration: duration, framesPerSecond: framesPerSecond,
                       isRestore: isRestore, source: entry, frames: frames + 1)
        }
    }

    /// 结束一次事务并汇报结果；成功还原才清除快照。
    private func finish(identity: WindowIdentity, token: Int, command: Source, target: CGRect,
                        actual: CGRect, success: Bool, isRestore: Bool, frames: Int,
                        began: Double, cancelled: Bool) {
        stateLock.lock()
        guard generations[identity] == token else { stateLock.unlock(); return }
        activeTargets.removeValue(forKey: identity)
        let retained = !isRestore || !success
        if isRestore && success {
            snapshots.removeValue(forKey: identity)
            generations.removeValue(forKey: identity)
        }
        stateLock.unlock()
        guard !cancelled else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
        log("RESULT source=\(command.rawValue) identity=\(identity.logDescription) target=\(target) actual=\(actual) success=\(success) restore=\(isRestore) recordRetained=\(retained) frames=\(frames) elapsedMs=\(elapsed)")
        let outcome = WindowLayoutOutcome(source: command.rawValue, command: layoutCommand(command),
                                          identity: identity, target: target, actual: actual,
                                          success: success, isRestore: isRestore,
                                          recordRetained: retained, frames: frames,
                                          elapsedMilliseconds: elapsed)
        Task { @MainActor [weak self] in self?.onOutcome?(outcome) }
    }

    private func layoutCommand(_ source: Source) -> WindowLayoutCommand {
        switch source {
        case .optionGreen: return .fill
        case .titleDoubleClick: return .fill
        case .systemKey: return .fill
        case .windowMenu: return .fill
        }
    }

    private func generationMatches(_ identity: WindowIdentity, _ token: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generations[identity] == token
    }

    /// 分段写入：先位置、再尺寸；返回尺寸写入是否成功。
    private func write(_ rect: CGRect, to window: AXUIElement, previous: CGRect) -> Bool {
        var origin = rect.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        return commitSize(rect, to: window)
    }

    private func commitSize(_ rect: CGRect, to window: AXUIElement) -> Bool {
        var size = rect.size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    /// 目标窗口所在屏幕；按窗口中心点判定，保证多屏下用对那块屏的预留。
    /// 列表由调用方在主线程解析后传入。
    private func screen(containing rect: CGRect, in screens: [WindowLayoutScreen]) -> WindowLayoutScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { $0.frame.contains(center) }
    }

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private func log(_ message: String) {
        WindowLayoutDiagnostics.record(message)
        Task { @MainActor [weak self] in self?.onLog?(message) }
    }
}

// MARK: - 屏幕几何采集

/// 应用层提供的屏幕输入。SpaceKit 不依赖 AppKit 的显示扩展，
/// 只接收已解析好的矩形与显示器标识，便于用假数据测试。
public struct WindowLayoutScreenInput: Sendable {
    /// AppKit 屏幕物理边界（左下原点）。
    public let frame: CGRect
    /// AppKit 系统可用区域（左下原点）。
    public let visibleFrame: CGRect
    public let displayID: UInt32

    public init(frame: CGRect, visibleFrame: CGRect, displayID: UInt32) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displayID = displayID
    }
}

public enum WindowLayoutScreens {

    /// 把 AppKit 屏幕几何换算为 AX 坐标的布局屏列表。
    /// 主屏高度用于把左下原点换算成 AX 的左上原点。
    public static func make(inputs: [WindowLayoutScreenInput],
                            primaryHeight: CGFloat,
                            reservations: DockReservationProviding) -> [WindowLayoutScreen] {
        inputs.map { input in
            WindowLayoutScreen(
                frame: flip(input.frame, primaryHeight: primaryHeight),
                visibleFrame: flip(input.visibleFrame, primaryHeight: primaryHeight),
                displayID: input.displayID,
                reservation: reservations.reservation(forDisplayID: input.displayID))
        }
    }

    /// AppKit 左下原点 → AX 左上原点。
    private static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - 外部改尺寸后的纠正

extension WindowLayoutInterceptor {

    /// 为前台应用的窗口装几何观测。应用切换、屏幕变化与接管成功后都要调用。
    ///
    /// 观测覆盖前台应用的全部标准窗口——入口 4、5（第三方最大化、Option＋拖动）
    /// 不经过事件 tap，若只在接管后才观测，就必须先触发一次入口 1～3 才能生效。
    func observeFrontmostApplication() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return }
        let pid = front.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        guard let value = attribute(application, kAXWindowsAttribute),
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            guard let identity = identity(of: window) else { continue }
            observe(identity: identity, window: window)
        }
    }

    /// 为单个窗口装观测；同一窗口只装一次。
    private func observe(identity: WindowIdentity, window: AXUIElement) {
        stateLock.lock()
        if let previous = frame(of: window) { observedFrames[identity] = previous }
        let already = observedWindows.contains(identity)
        if !already { observedWindows.insert(identity) }
        stateLock.unlock()
        guard !already else { return }

        var observer = observers[identity.pid]
        if observer == nil {
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let interceptor = Unmanaged<WindowLayoutInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                // 指针按下期间（拖动/缩放中）不纠正，交给松手后的检查；
                // 外部工具改尺寸时指针未按下，则尽快纠正以缩短可见闪烁。
                guard !interceptor.pointerIsDown else { return }
                interceptor.scheduleSnapCheck(after: 0.04)
            }
            guard AXObserverCreate(identity.pid, callback, &created) == .success, let created else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observers[identity.pid] = created
            observer = created
        }
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
    }

    /// 合并短时间内的多次几何变化，稳定后再核对一次。
    func scheduleSnapCheck(after delay: Double) {
        stateLock.lock()
        let pending = Array(observedWindows)
        stateLock.unlock()
        guard !pending.isEmpty else { return }
        for identity in pending {
            snapWorkItems[identity]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.snapWorkItems.removeValue(forKey: identity)
                self?.snapOffDock(identity: identity)
            }
            snapWorkItems[identity] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// 若窗口因**变大**而压住程序坞，把它收进可用区。
    ///
    /// 判定逻辑在 `WindowLayoutCorrection.correction`（纯函数，可对四个停靠方向自检）。
    func snapOffDock(identity: WindowIdentity) {
        guard !pointerIsDown else { return }   // 拖动中不打断
        stateLock.lock()
        guard let element = elementFor(identity) else { stateLock.unlock(); return }
        let previous = observedFrames[identity]
        stateLock.unlock()
        let window = element
        guard let current = frame(of: window) else { return }
        stateLock.lock()
        observedFrames[identity] = current
        stateLock.unlock()

        let availableScreens = MainActor.assumeIsolated { screensProvider?() ?? [] }
        guard let screen = screen(containing: current, in: availableScreens) else { return }
        let outcome = WindowLayoutCorrection.correction(
            current: current, allowed: screen.allowedFrame,
            edge: screen.reservation?.edge ?? .bottom, previous: previous)
        guard let target = outcome.target else { return }
        guard !generationInFlight(identity) else { return }   // 正在动画中不打断
        let wrote = write(target, to: window, previous: current)
        let actual = frame(of: window) ?? current
        log("SNAP_OFF_DOCK identity=\(identity.logDescription) from=\(current) target=\(target) actual=\(actual) wrote=\(wrote)")
        stateLock.lock()
        snapshots[identity]?.lastWritten = actual
        observedFrames[identity] = actual
        stateLock.unlock()
    }

    /// 取某个身份对应的窗口元素：优先已接管窗口的快照，其次按窗口列表匹配。
    private func elementFor(_ identity: WindowIdentity) -> AXUIElement? {
        if let snapshot = snapshots[identity] { return snapshot.element }
        let application = AXUIElementCreateApplication(identity.pid)
        guard let value = attribute(application, kAXWindowsAttribute),
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows where self.identity(of: window) == identity { return window }
        return nil
    }

    /// 该窗口是否有进行中的动画事务。
    private func generationInFlight(_ identity: WindowIdentity) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeTargets[identity] != nil
    }
}
