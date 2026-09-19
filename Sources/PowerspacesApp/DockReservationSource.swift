// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import SpaceKit

/// 汇总各显示器程序坞的静止预留，实现 SpaceKit 的查询协议。
///
/// 预留由 `DockPanel` 提供（只含可见玻璃厚度），这里只做按显示器标识的索引；
/// 面板集合每次变化都不缓存，避免程序坞重建后留下过期几何。
@MainActor
final class DockReservationStore: DockReservationProviding {
    private let docks: () -> [DockReservation]

    init(docks: @escaping () -> [DockReservation]) {
        self.docks = docks
    }

    nonisolated func reservation(forDisplayID displayID: UInt32) -> DockReservation? {
        MainActor.assumeIsolated {
            docks().first { $0.displayID == displayID }
        }
    }
}
