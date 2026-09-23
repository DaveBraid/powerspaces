// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics
import Foundation

/// 把一个应用的窗口搬到指定 Space。
///
/// 用的是系统 Dock「选项 → 分配给 → 这个桌面」背后的**进程级**接口
/// （`CGSProcessAssignToSpace`）：它改变的是「该进程的窗口属于哪个桌面」，
/// 因此已有窗口会立即跟着过去，后续新窗口也落在那里——正是这条菜单项的语义。
///
/// 为什么不走窗口级那套（`CGSAddWindowsToSpaces` / `CGSMoveWindowsToManagedSpace`）：
/// 那两个在开启 SIP 的系统上是静默 no-op（实测 macOS 27 上四种调用顺序全部无效），
/// 而进程级接口可用且不需要关闭 SIP。
///
/// 私有符号通过 `dlsym` 动态解析：系统移除它时应用照常运行，只是该策略降级为警告。
public enum WindowSpaceMover {

    /// 程序坞点击优先使用点击屏幕的桌面；未提供屏幕时才使用快照的活动桌面。
    public static func destinationSpace(dockSpace: SpaceID?, snapshotActiveSpace: SpaceID) -> SpaceID {
        dockSpace ?? snapshotActiveSpace
    }

    public enum MoveError: Error {
        /// 系统未提供该私有接口（未来版本可能移除）。
        case apiUnavailable
        /// 调用后重新读取归属仍未到达目标 Space。
        case notMoved
        /// 窗口已搬移，但桌面记忆未保存。
        case assignmentNotSaved
    }

    private typealias AssignToSpace = @convention(c) (CGSConnectionID, pid_t, UInt64) -> Void

    /// 动态解析一次的符号；nil 表示本系统不提供。
    private static let assignToSpace: AssignToSpace? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let symbol = dlsym(handle, "CGSProcessAssignToSpace") else { return nil }
        return unsafeBitCast(symbol, to: AssignToSpace.self)
    }()

    /// 本机是否可用该能力；调用方据此决定是否把策略列为可选。
    public static var isAvailable: Bool { assignToSpace != nil }

    /// 把 `pid` 的全部窗口分配到 `targetSpaceID`。
    ///
    /// - Parameter confirmedSpaces: 读取某个 pid 当前窗口所属 Space 的闭包，用于确认结果；
    ///   由调用方注入，便于用假数据测试。
    /// - Returns: 实际落到的 Space。
    @discardableResult
    public static func assign(pid: pid_t, to targetSpaceID: SpaceID,
                              confirmedSpaces: (pid_t) -> Set<SpaceID>) throws -> SpaceID {
        guard let assignToSpace else { throw MoveError.apiUnavailable }
        assignToSpace(CGSMainConnectionID(), pid, UInt64(targetSpaceID))
        // 私有接口不返回错误且归属更新可能稍晚；有限等待实际窗口归属，避免误报失败。
        let confirmed = pollUntil(timeout: 0.5, interval: 50_000) {
            let landed = confirmedSpaces(pid)
            return !landed.isEmpty && landed == [targetSpaceID]
        }
        guard confirmed else { throw MoveError.notMoved }
        return targetSpaceID
    }

    /// 搬移确认后覆盖系统桌面记忆；若记忆失败，明确区分已完成的窗口搬移。
    @discardableResult
    public static func assignAndRemember(pid: pid_t, to targetSpaceID: SpaceID,
                                         confirmedSpaces: (pid_t) -> Set<SpaceID>) throws -> SpaceID {
        try assign(pid: pid, to: targetSpaceID, confirmedSpaces: confirmedSpaces)
        // 进程分配不会跨退出保存；确认搬移后再覆盖原生 Dock 的持久绑定。
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            throw MoveError.assignmentNotSaved
        }
        do {
            try DesktopAssignment.remember(bundleID: bundle, spaceID: targetSpaceID,
                                           provider: CGSSpaceProvider())
        } catch {
            Log.error("Desktop assignment could not be saved: \(bundle): \(error)")
            throw MoveError.assignmentNotSaved
        }
        return targetSpaceID
    }

    // MARK: - 切回桌面（兜底）

    /// 系统是否提供「切换当前桌面」的私有接口。
    public static var canSwitchSpace: Bool { setCurrentSpace != nil && activeSpace != nil }

    /// 当前桌面（Space ID）；读取失败返回 nil。
    public static func currentSpace() -> SpaceID? {
        guard let activeSpace else { return nil }
        let value = activeSpace(CGSMainConnectionID())
        return value == 0 ? nil : SpaceID(value)
    }

    /// 把当前显示的桌面切回 `spaceID`。
    ///
    /// 用途仅为**兜底**：少数应用（如设置了 `NSWindowCollectionBehavior.moveToActiveSpace`
    /// 的 ChatGPT）会在被激活时自己把桌面拉走，外部无法改写该行为（AX 不暴露
    /// collection behavior）。搬移完成后若发现桌面被带走，用这里切回用户原本所在桌面。
    /// 代价是一次可见的桌面闪动，因此只在确实被带走时才调用。
    @discardableResult
    public static func switchBack(to spaceID: SpaceID) -> Bool {
        guard let setCurrentSpace,
              let display = mainDisplayIdentifier() else { return false }
        setCurrentSpace(CGSMainConnectionID(), display, UInt64(spaceID))
        return true
    }

    private typealias GetActiveSpace = @convention(c) (CGSConnectionID) -> UInt64
    private typealias SetCurrentSpace = @convention(c) (CGSConnectionID, CFString, UInt64) -> Void
    private typealias CopyDisplaySpaces = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?

    private static let activeSpace: GetActiveSpace? = symbol("CGSGetActiveSpace")
    private static let setCurrentSpace: SetCurrentSpace? = symbol("CGSManagedDisplaySetCurrentSpace")
    private static let copyDisplaySpaces: CopyDisplaySpaces? = symbol("CGSCopyManagedDisplaySpaces")

    /// 主显示器的标识符（每次读取，显示器热插拔后会变，不能缓存）。
    private static func mainDisplayIdentifier() -> CFString? {
        guard let copyDisplaySpaces,
              let displays = copyDisplaySpaces(CGSMainConnectionID())?
                  .takeRetainedValue() as? [[String: Any]],
              let identifier = displays.first?["Display Identifier"] as? String else { return nil }
        return identifier as CFString
    }

    /// 从 SkyLight 动态取符号；系统移除时返回 nil，调用方走降级路径。
    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
