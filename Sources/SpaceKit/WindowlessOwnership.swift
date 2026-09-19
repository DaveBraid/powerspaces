// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 无窗口进程没有 Space 属性；在会话内保留最后可见归属，退出即清理。
public struct WindowlessOwnership {
    private var scopes: [pid_t: Set<String>] = [:]
    public init() {}

    /// 输入存活进程、窗口状态和可见归属；首次无窗口进程归入当前桌面，不跨桌面复制。
    public mutating func update(livePIDs: Set<pid_t>, pidsWithWindows: Set<pid_t>,
                                visibleScopes: [pid_t: Set<String>], fallbackScope: String) {
        scopes = scopes.filter { livePIDs.contains($0.key) }
        for pid in livePIDs {
            if let visible = visibleScopes[pid], !visible.isEmpty {
                scopes[pid] = visible
            } else if scopes[pid] == nil, !pidsWithWindows.contains(pid), !fallbackScope.isEmpty {
                scopes[pid] = [fallbackScope]
            }
        }
    }

    /// 查询无窗口应用是否属于指定显示器桌面；未知归属保持隐藏。
    public func contains(_ pid: pid_t, scope: String) -> Bool {
        scopes[pid]?.contains(scope) == true
    }
}
