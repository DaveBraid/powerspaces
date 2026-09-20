// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

private final class HoverPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 缩略图按钮只在点击时执行窗口操作；标题、占位与图片由同一次展开更新。
/// 预览卡片右下角的「全屏」标记：Liquid Glass 胶囊 + 系统全屏图标。
///
/// 用于区分全屏窗口与当前桌面窗口——全屏窗口独占一个 Space，点它需要跳到那个 Space。
/// 图标用 `arrow.up.left.and.arrow.down.right`：这正是 macOS「进入全屏」的系统图标，
/// 比缩到 26pt 的应用图标清晰得多（应用图标在这个尺寸下会糊成一团）。
private final class FullscreenBadge: NSView {
    private let icon = NSImageView()
    /// macOS 26+ 的玻璃材质；旧系统回退为半透明深色胶囊。
    private func makeGlass() -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = 9
            return view
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true
        return blur
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let surface = makeGlass()
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = bounds.insetBy(dx: 5, dy: 5)
        icon.autoresizingMask = [.width, .height]
        // 模板图：跟随系统前景色，深浅玻璃上都清晰。
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = .labelColor
        addSubview(icon)
        setAccessibilityElement(false)
        toolTip = L10n.string("Full screen")
    }
    required init?(coder: NSCoder) { nil }
}

private final class HoverPreviewCard: NSButton {
    let thumbnail = NSImageView()
    let caption = NSTextField(labelWithString: "")
    let placeholder = NSTextField(wrappingLabelWithString: "")
    /// 全屏窗口才有；置于缩略图右下角，平时隐藏。
    let fullscreenBadge = FullscreenBadge(frame: .zero)
    var select: (() -> Void)?
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 166))
        isBordered = false
        self.title = ""
        target = self
        action = #selector(clicked)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        caption.stringValue = title
        setAccessibilityLabel(title)
        toolTip = title
        caption.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 12)
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        fullscreenBadge.isHidden = true
        for view in [thumbnail, caption, placeholder, fullscreenBadge] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        thumbnail.frame = NSRect(x: 8, y: 28, width: bounds.width - 16, height: bounds.height - 36)
        placeholder.frame = NSRect(x: 12, y: bounds.midY - 24, width: bounds.width - 24, height: 48)
        caption.frame = NSRect(x: 8, y: 7, width: bounds.width - 16, height: 17)
        // 缩略图右下角（留 10pt 边距）；右下不与标题、也不与左上角的窗口内容冲突。
        let side: CGFloat = 26
        fullscreenBadge.frame = NSRect(x: bounds.maxX - side - 10,
                                       y: thumbnail.frame.maxY - side - 10,
                                       width: side, height: side)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc private func clicked() { select?() }
}

/// 全局仅一个预览会话；350ms 展开、300ms 跨间隙收起，关闭即释放图片并淘汰异步结果。
@MainActor final class WindowHoverPreview {
    static let shared = WindowHoverPreview()
    private weak var owner: DockPanel?
    private weak var anchor: DockButton?
    private var app: DockApp?
    private var space = ""
    private var generation = UUID()
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var panel: HoverPreviewPanel?
    private var cards: [CGWindowID: HoverPreviewCard] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
    }

    /// 悬停仅排一次延迟任务；窗口枚举和截图不在事件回调内执行。
    func hover(_ app: DockApp, button: DockButton, dock: DockPanel) {
        guard Preferences.shared.windowPreviewEnabled, app.pid != nil, !app.isLauncher,
              !dock.isContextMenuOpen, !dock.isReordering, !dock.isExternalDragging,
              let space = dock.spaceUUID else { return }
        if owner === dock, self.app?.pid == app.pid, self.space == space {
            anchor = button
            closeWork?.cancel(); closeWork = nil
            reposition()
            return
        }
        close()
        owner = dock; anchor = button; self.app = app; self.space = space
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            guard self.anchorHit(NSEvent.mouseLocation) else { self.close(); return }
            self.openWork = nil
            self.open()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.350, execute: work)
    }

    /// 命中实际顶层窗口，防止被其他应用覆盖后仍保留悬停。
    private func anchorHit(_ point: NSPoint) -> Bool {
        guard let anchor, let owner, owner.isVisible else { return false }
        let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return rect.contains(point) && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == owner.windowNumber
    }

    /// 图标与浮层共用离开倒计时，容许经过间隙并核对遮挡。
    func pointerMoved(for dock: DockPanel) {
        guard owner === dock else { return }
        let point = NSEvent.mouseLocation
        let inPanel = panel.map { $0.isVisible && $0.frame.contains(point)
            && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == $0.windowNumber } ?? false
        if anchorHit(point) || inPanel {
            closeWork?.cancel(); closeWork = nil
        } else if closeWork == nil {
            if panel == nil { close(); return }
            let work = DispatchWorkItem { [weak self] in self?.close() }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.300, execute: work)
        }
    }

    func keepsOpen(_ dock: DockPanel) -> Bool { owner === dock && panel != nil }
    func close(for dock: DockPanel) { if owner === dock { close() } }

    /// 先撤销会话，再恢复 Dock 退出动画；任何捕获回调必须匹配新会话令牌。
    func close() {
        let oldOwner = owner
        owner = nil; anchor = nil; app = nil
        generation = UUID()
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
        WindowThumbnailService.shared.cancel()
        // AppKit 可暂留旧视图，主动清空图像，不能仅依赖窗口释放。
        for card in cards.values { card.thumbnail.image = nil; card.select = nil }
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
        cards.removeAll()
        oldOwner?.endMagnificationIfPointerLeft(at: NSEvent.mouseLocation, deliveredElsewhere: true)
        oldOwner?.previewDidClose()
    }

    /// 到达展开阈值后才检查权限；不在悬停时主动弹授权框。
    private func open() {
        guard Preferences.shared.windowPreviewEnabled, owner != nil, app != nil else { close(); return }
        if !CGPreflightScreenCaptureAccess() {
            showMessage("Enable Screen Recording in Settings → Effects for window previews.")
            return
        }
        loadWindows()
    }

    /// 查询在已有启动队列上执行；回调仅在会话与桌面仍有效时更新 UI。
    private func loadWindows() {
        guard let owner, let app else { return }
        showMessage("Loading window previews…")
        let token = generation
        owner.onPreviewWindows?(app, space) { [weak self] windows in
            guard let self, self.generation == token, let owner = self.owner else { return }
            guard let windows else { self.showMessage("Window preview unavailable"); return }
            guard !windows.isEmpty else { self.showMessage("No windows on this desktop"); return }
            self.show(windows, app: app)
            // 一律允许离屏：全屏窗口所在的 Space 不可见，不允许离屏就只会在卡片上写
            // "Window is on another desktop"，而这正是本功能要消除的情况。
            WindowThumbnailService.shared.capture(windows, allowOffscreen: true) { [weak self, weak owner] id, title, image, error in
                guard let self, owner != nil, self.generation == token, let card = self.cards[id] else { return }
                if let title, !title.isEmpty {
                    card.caption.stringValue = title
                    card.setAccessibilityLabel(title)
                    card.toolTip = title
                }
                card.thumbnail.image = image
                card.placeholder.stringValue = error.map(L10n.string) ?? ""
            }
        }
    }

    /// 不激活的浮层使用系统 popover 材质；所有卡片可滚动，不截断窗口数量。
    private func present(_ content: NSView, size: NSSize) {
        guard let owner else { return }
        let panel = self.panel ?? HoverPreviewPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true // 进入浮层后仍向现有鼠标监听发送移动事件，取消跨间隙收起。
        panel.hasShadow = true
        panel.setContentSize(size) // 先确定窗口尺寸，避免零尺寸内容视图使文字的自动布局偏移。
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover; background.state = .active; background.blendingMode = .behindWindow
        background.wantsLayer = true; background.layer?.cornerRadius = 14; background.layer?.masksToBounds = true
        panel.contentView = background
        content.frame = background.bounds.insetBy(dx: 8, dy: 8)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
    }

    /// 用明确占位表示加载、空列表或权限缺失。
    private func showMessage(_ text: String) {
        cards.removeAll()
        let label = NSTextField(wrappingLabelWithString: L10n.string(text))
        label.alignment = .center
        label.maximumNumberOfLines = 0
        let width = min(290, (owner?.boundScreen?.visibleFrame.width ?? 320) - 24)
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 16, height: 1000)).height ?? 60
        present(label, size: NSSize(width: width, height: max(76, ceil(measured) + 24)))
    }

    /// 为所有归属窗口构建可滚动列表，点击才触发精确聚焦。
    private func show(_ windows: [WindowInfo], app: DockApp) {
        guard let owner else { return }
        cards.removeAll()
        let vertical = Preferences.shared.barPosition.isVertical
        let available = (owner.boundScreen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 800, height: 600)
        let cardSize = NSSize(width: min(220, max(80, available.width - 32)), height: min(166, max(70, available.height - 32)))
        let document = NSView(frame: NSRect(x: 0, y: 0,
            width: vertical ? cardSize.width : cardSize.width * CGFloat(windows.count),
            height: vertical ? cardSize.height * CGFloat(windows.count) : cardSize.height))
        let token = generation, space = self.space
        // 全屏窗口独立标记：需要跳到它的 Space，因此卡片右上角加一层玻璃图标。
        let fullscreenSpaces = owner.onFullscreenSpaceIDs?() ?? []
        var fullscreenWindowIDs: Set<CGWindowID> = []
        for (index, info) in windows.enumerated() {
            let card = HoverPreviewCard(title: app.name + " · " + String(index + 1))
            if WindowPreview.isFullscreen(info, fullscreenSpaceIDs: fullscreenSpaces) {
                card.fullscreenBadge.isHidden = false
                card.setAccessibilityLabel(app.name + " · " + L10n.string("Full screen"))
                fullscreenWindowIDs.insert(info.windowID)
            }
            card.frame = NSRect(x: vertical ? 0 : CGFloat(index) * cardSize.width,
                                y: vertical ? CGFloat(windows.count - index - 1) * cardSize.height : 0,
                                width: cardSize.width, height: cardSize.height)
            card.placeholder.stringValue = L10n.string("Loading window previews…")
            card.select = { [weak self, weak owner] in
                guard let self, self.generation == token else { return }
                self.close()
                guard AccessibilityPermission.isTrusted else { AccessibilityPermission.showAuthorizationGuide(); return }
                if fullscreenWindowIDs.contains(info.windowID) {
                    owner?.onPreviewSelectFullscreen?(app, info.windowID)
                } else {
                    owner?.onPreviewSelect?(app, info.windowID, space)
                }
            }
            document.addSubview(card); cards[info.windowID] = card
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = !vertical; scroll.hasVerticalScroller = vertical
        scroll.autohidesScrollers = true; scroll.documentView = document
        present(scroll, size: NSSize(width: min(document.frame.width + 16, available.width - 16),
                                    height: min(document.frame.height + 16, available.height - 16)))
    }

    /// 只移动浮层，不重新截图；按实际图标和玻璃范围定位，限制在所属屏幕可见区域。
    func reposition() {
        guard let panel, let owner, let anchor, let screen = owner.boundScreen ?? NSScreen.main else { return }
        let icon = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let dock = owner.previewGlassFrame.union(icon)
        let size = panel.frame.size
        var origin: NSPoint
        switch Preferences.shared.barPosition {
        case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: dock.maxY + 8)
        case .top: origin = NSPoint(x: icon.midX - size.width / 2, y: dock.minY - size.height - 8)
        case .left: origin = NSPoint(x: dock.maxX + 8, y: icon.midY - size.height / 2)
        case .right: origin = NSPoint(x: dock.minX - size.width - 8, y: icon.midY - size.height / 2)
        }
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
    /// 独立内存／布局回归，不读取用户窗口或申请权限，使用临时设置和合成图片。
    static func checkLayout() -> Bool {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return false }
        let preview = WindowHoverPreview()
        let prefs = Preferences.shared
        prefs.windowPreviewEnabled = true
        var passed = true
        func buttons(_ view: NSView) -> [DockButton] {
            if let button = view as? DockButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        for position in [BarPosition.bottom, .top, .left, .right] {
            prefs.barPosition = position
            let dock = DockPanel(screen: screen)
            let app = DockApp(bundleID: "preview.fixture", name: "Preview", pid: 1, windowCount: 8)
            dock.update(apps: [app], animateChanges: false)
            dock.show()
            guard let root = dock.contentView, let button = buttons(root).first else { return false }
            preview.owner = dock; preview.anchor = button; preview.app = app; preview.space = "test"
            let windows = (1...8).map { WindowInfo(windowID: UInt32($0), pid: 1,
                ownerName: "Preview", bundleID: "preview.fixture", spaceIDs: [1]) }
            preview.show(windows, app: app)
            guard let panel = preview.panel else { return false }
            let contentFits = panel.contentView.map { root in root.subviews.allSatisfy { root.bounds.contains($0.frame) } } ?? false
            let bounded = screen.visibleFrame.contains(panel.frame) && contentFits
            let noFocus = !panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow
                && panel.acceptsMouseMovedEvents
            let allCards = preview.cards.count == 8
            let oldGeneration = preview.generation
            weak var releasedImage: NSImage?
            autoreleasepool {
                let image = NSImage(size: NSSize(width: 40, height: 40))
                releasedImage = image
                preview.cards[1]?.thumbnail.image = image
                preview.close()
            }
            let cleared = releasedImage == nil && preview.cards.isEmpty && preview.panel == nil
                && preview.generation != oldGeneration
            print("Window preview \(position): bounds=\(bounded) nonactivating=\(noFocus) allWindows=\(allCards) released=\(cleared)")
            passed = passed && bounded && noFocus && allCards && cleared
            // 延迟归属结果在关闭后到达，必须不能重建浮层或触发捕获。
            var delayed: (([WindowInfo]?) -> Void)?
            dock.onPreviewWindows = { _, _, reply in delayed = reply }
            preview.owner = dock; preview.anchor = button; preview.app = app; preview.space = "test"
            preview.loadWindows()
            if let root = preview.panel?.contentView {
                passed = passed && root.subviews.allSatisfy { root.bounds.contains($0.frame) }
            } else { passed = false }
            preview.close()
            delayed?(windows)
            let staleIgnored = preview.panel == nil && preview.cards.isEmpty
            print("Window preview stale query: \(staleIgnored)")
            passed = passed && staleIgnored
            if CommandLine.arguments.contains("--hold-preview"), position == .bottom {
                dock.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    preview.owner = dock; preview.anchor = button; preview.app = app; preview.space = "test"
                    preview.showMessage("Enable Screen Recording in Settings → Effects for window previews.")
                }
                NSApplication.shared.run()
            }
            dock.close()
        }
        try? FileManager.default.removeItem(at: DevelopmentTools.previewDirectory)
        return passed
    }

}
