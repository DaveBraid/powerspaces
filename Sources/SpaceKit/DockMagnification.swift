// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 来自用户确认的独立原型：映射边界而非独立缩放中心，保证连续让位。
public struct DockMagnification {
    public let base: CGFloat
    public let maximum: CGFloat
    public let progress: CGFloat
    public let focus: CGFloat

    /// 输入基础尺寸、峰值、进出进度及静止坐标系中的焦点。
    public init(base: CGFloat, maximum: CGFloat, progress: CGFloat, focus: CGFloat) {
        self.base = max(1, base)
        self.maximum = max(self.base, maximum)
        self.progress = min(1, max(0, progress))
        self.focus = focus
    }

    /// 正弦边界映射；半径为三个基础图标，远处只平移、不继续放大。
    public func map(_ coordinate: CGFloat) -> CGFloat {
        let radius = 3 * base
        let amplitude = (maximum - base) / (2 * sin(.pi * base / (4 * radius)))
        let distance = max(-1, min(1, (coordinate - focus) / radius))
        return coordinate + amplitude * progress * sin(.pi * distance / 2)
    }

    /// 按剩余尺寸差计算进出时长，保留原型 fishSpeed=42 的毫秒关系。
    public static func duration(sizeDifference: CGFloat) -> TimeInterval {
        floor(42 * log(max(0, sizeDifference) / 2 + 1) + 1) / 1000
    }

    /// 绝对时间的余弦缓动，反向时从当前进度续接，不依赖帧数。
    public static func interpolate(from: CGFloat, to: CGFloat, fraction: Double) -> CGFloat {
        let t = min(1, max(0, fraction))
        return from + (to - from) * CGFloat((1 - cos(.pi * t)) / 2)
    }
}
