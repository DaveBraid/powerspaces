// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// 激活应用时把它的窗口搬到当前桌面。
///
/// 前提是系统设置里「切换到应用程序时，切换到有打开窗口的空间」
/// （`AppleSpacesSwitchOnActivate`）已关闭：那时激活一个在他桌面的应用不会再跳桌面，
/// 于是只剩「把它搬过来」这一步。
///
/// 与 `.moveHere` 策略的区别：那是**按应用**手动指定；这里对**所有应用**在激活时自动生效。
///
/// 触发条件很严，宁可不做也不误搬：只在「前台变化 + 应用仅在他桌面有窗口 +
/// 当前 Space 没有变化」时动作。**绝不采用「先跳过去再搬回来」**——若跳转已经发生，
/// 这次就直接放弃，不做事后纠正。
/// 并发说明：实例在创建时注入全部依赖，之后只读；`scheduleSwitchBack` 的延迟回调
/// 只调用不可变的注入闭包，不共享可变状态，因此标为 `@unchecked Sendable`。
public final class ActivatedAppMover: @unchecked Sendable {

        /// 前台应用的变化：由调用方在已有的轮询里比较相邻两次前台得到。
    ///
    /// 本机实测 `NSWorkspace.didActivateApplicationNotification` 与
    /// `activeSpaceDidChangeNotification` 均不送达（macOS 27），因此不依赖通知；
    /// 判定只认"前台 pid 变了"这一个事实，仍是纯值、可用假数据测试。
    public struct ForegroundChange: Equatable {
        public let previousPID: pid_t?
        public let currentPID: pid_t?
        /// 被测进程自身 pid（PowerSpaces 自己成为前台时不应触发）。
        public let ownPID: pid_t

        public init(previousPID: pid_t?, currentPID: pid_t?, ownPID: pid_t) {
            self.previousPID = previousPID
            self.currentPID = currentPID
            self.ownPID = ownPID
        }

        /// 前台是否发生了值得处理的切换：换了应用，且新前台不是自己。
        public var isNewActivation: Bool {
            guard let currentPID else { return false }
            guard currentPID != ownPID else { return false }
            return currentPID != previousPID
        }
    }

    /// 一次判定所需的最小输入；由调用方从现有 `SpaceProvider` 取得。
    public struct Input {
        /// 当前 Space。
        public let activeSpaceID: SpaceID
        /// 刚被激活的应用。
        public let target: AppTarget
        /// 该应用所在进程；用于进程级搬移。
        public let pid: pid_t?
        /// 读取某个进程全部窗口当前所属 Space，用于搬移后确认；由调用方从真实 provider 取得。
        public let confirmSpaces: (pid_t) -> Set<SpaceID>

        public init(activeSpaceID: SpaceID, target: AppTarget, pid: pid_t?,
                    confirmSpaces: @escaping (pid_t) -> Set<SpaceID>) {
            self.activeSpaceID = activeSpaceID
            self.target = target
            self.pid = pid
            self.confirmSpaces = confirmSpaces
        }
    }

    /// 判定结果，便于调用方决定是否记录。
    public enum Outcome: Equatable {
        /// 偏好未开启。
        case disabled
        /// 系统未提供搬移接口。
        case unavailable
        /// 当前 Space 刚变过（多半是用户在切桌面），一律不搬。
        case spaceChanged
        /// 该应用在当前桌面已有窗口——无需搬。
        case alreadyHere
        /// 该应用只在其它桌面有窗口——已搬移并确认落到当前桌面。
        case moved
        /// 已搬移，但应用自己把桌面拉走了，已切回用户原本所在的桌面（兜底）。
        case movedAndSwitchedBack
        /// 没有可搬的窗口，或搬移后未落到当前桌面。
        case notMoved
    }

    private let isEnabled: () -> Bool
    /// 当前 Space 是否刚刚变过（用户在切桌面）。切桌面时前台也会变，必须排除。
    private let spaceRecentlyChanged: () -> Bool
    /// 搬移实现；默认走 `WindowSpaceMover`，测试可替换。
    private let move: (pid_t, SpaceID, @escaping (pid_t) -> Set<SpaceID>) throws -> SpaceID
    /// 当前显示的桌面；用于判定应用是否把桌面拉走。
    private let currentSpace: () -> SpaceID?
    /// 切回指定桌面（兜底）；返回是否发起。
    private let switchBack: (SpaceID) -> Bool
    /// 兜底前等待的秒数：`moveToActiveSpace` 类应用在激活后极短时间内才抢桌面。
    private let settleDelay: TimeInterval
    /// 延迟调度器；测试注入立即执行版本，避免依赖真实计时。
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    public init(isEnabled: @escaping () -> Bool,
                spaceRecentlyChanged: @escaping () -> Bool = { false },
                available: @escaping () -> Bool = { WindowSpaceMover.isAvailable },
                move: ((pid_t, SpaceID, @escaping (pid_t) -> Set<SpaceID>) throws -> SpaceID)? = nil,
                currentSpace: @escaping () -> SpaceID? = { WindowSpaceMover.currentSpace() },
                switchBack: @escaping (SpaceID) -> Bool = { WindowSpaceMover.switchBack(to: $0) },
                settleDelay: TimeInterval = 0.4,
                schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.isEnabled = isEnabled
        self.spaceRecentlyChanged = spaceRecentlyChanged
        self.isAvailable = available
        self.move = move ?? { pid, space, confirm in
            try WindowSpaceMover.assign(pid: pid, to: space, confirmedSpaces: confirm)
        }
        self.currentSpace = currentSpace
        self.switchBack = switchBack
        self.settleDelay = settleDelay
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private let isAvailable: () -> Bool

    /// 按一次前台变化判定并（必要时）搬移。
    ///
    /// 归属判断只走快照：`snapshot.windows(of:)` + 每个窗口的 `spaceIDs`，
    /// 不在这里另写一套判断。
    @discardableResult
    public func consider(_ input: Input, snapshot: SpaceSnapshot) -> Outcome {
        guard isEnabled() else { return .disabled }
        guard isAvailable() else { return .unavailable }
        // 用户在切桌面时前台也会变：这一条把它们排除在外。
        guard !spaceRecentlyChanged() else { return .spaceChanged }
        let windows = snapshot.windows(of: input.target)
        guard !windows.isEmpty else { return .notMoved }
        // 当前桌面已有窗口 → 无需搬（此时激活会聚焦那个窗口，不该动别的）。
        guard !windows.contains(where: { $0.isOn(input.activeSpaceID) }) else { return .alreadyHere }
        guard windows.contains(where: { !$0.spaceIDs.isEmpty }), let pid = input.pid else {
            return .notMoved
        }
        do {
            // 搬移实现自带「重新读取归属确认」，失败会抛错。
            _ = try move(pid, input.activeSpaceID, input.confirmSpaces)
        } catch {
            // 搬不动就什么都不做：不跳桌面、不关窗口、不反复重试。
            return .notMoved
        }
        // 兜底：少数应用（moveToActiveSpace，如 ChatGPT）会在激活后极短时间内自己把桌面
        // 拉走，外部无法改写该行为。这里**异步**等一小段再检查并切回，绝不阻塞调用方
        // （激活回调在主线程上）。只有确实被带走才切回，代价是一次可见的桌面闪动。
        let alreadyHijacked = currentSpace() != input.activeSpaceID
        schedule(settleDelay) { [weak self] in
            guard let self, self.currentSpace() != input.activeSpaceID else { return }
            _ = self.switchBack(input.activeSpaceID)
        }
        return alreadyHijacked ? .movedAndSwitchedBack : .moved
    }
}
