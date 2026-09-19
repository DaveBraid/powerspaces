// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The seam between the pure decision logic and the live window server.
/// The real implementation (`CGSSpaceProvider`) talks to private CGS APIs;
/// tests inject a fake that returns hand-built snapshots.
///
/// The protocol carries exactly what the app drives polymorphically: the world
/// `snapshot()` and the per-display layout `displays()` (the per-display dock's
/// input — load-bearing, so it belongs on the seam). `currentSpaceID()` /
/// `currentSpaceUUID()` stay concrete on `CGSSpaceProvider`: only the CLI and the
/// snapshot builder call them, always on the live provider, never through a fake.
public protocol SpaceProviding {
    func snapshot() throws -> SpaceSnapshot
    func displays() -> [DisplaySpaceInfo]
    func spaceUUIDs() -> [SpaceID: String]
}

public extension SpaceProviding {
    /// 假数据提供器默认提供可见桌面；真实实现还提供隐藏桌面，以便立即识别移窗。
    func spaceUUIDs() -> [SpaceID: String] {
        Dictionary(displays().map { ($0.currentSpaceID, $0.currentSpaceUUID) },
                   uniquingKeysWith: { first, _ in first })
    }
}

public enum SpaceError: Error, CustomStringConvertible, Sendable {
    case cgsUnavailable
    case noCurrentSpace

    public var description: String {
        switch self {
        case .cgsUnavailable: return "CGS window-server APIs returned no data (is a GUI session active?)"
        case .noCurrentSpace: return "Could not determine the current Space from the display layout"
        }
    }
}
