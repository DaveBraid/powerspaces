// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

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

    public enum MoveError: Error {
        /// 系统未提供该私有接口（未来版本可能移除）。
        case apiUnavailable
        /// 调用后重新读取归属仍未到达目标 Space。
        case notMoved
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
        // 私有接口不返回错误，只能按结果确认：窗口必须都落在目标桌面。
        let landed = confirmedSpaces(pid)
        guard !landed.isEmpty, landed == [targetSpaceID] else { throw MoveError.notMoved }
        return targetSpaceID
    }
}
