// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 从静止内容计算有效比例；悬停只预留空间，不参与重新求解，避免布局反馈抖动。
public enum DockAdaptiveSizing {
    /// 输入可用长轴、可缩放内容与固定占位，返回不超过用户尺寸的比例。
    public static func scale(available: CGFloat, content: CGFloat, fixed: CGFloat,
                             hoverExpansion: CGFloat = 0) -> CGFloat {
        let total = content + max(0, hoverExpansion)
        guard total > 0, available.isFinite, total.isFinite else { return 1 }
        return min(1, max(0.001, (available - max(0, fixed)) / total))
    }
}
