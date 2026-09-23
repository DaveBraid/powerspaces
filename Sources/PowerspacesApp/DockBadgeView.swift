// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import QuartzCore

/// 徽章独立绘制且不参与命中；原文作为 tooltip 保留，不把 99+ 或文字转成数字。
final class DockBadgeView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            toolTip = text
            // 只对纯数字做计数过渡；99+ 和文字原样显示，不能捏造中间内容。
            if notification, !SystemDisplay.reduceMotion, let target = Int(text), target >= 0,
               target <= 9999, let start = Int(displayedText.isEmpty ? "0" : displayedText) {
                countFrom = start
                countTo = target
                countStarted = CACurrentMediaTime()
                if countLink == nil {
                    let link = displayLink(target: self, selector: #selector(tickCount(_:)))
                    link.add(to: .main, forMode: .common)
                    countLink = link
                }
            } else {
                countLink?.invalidate()
                countLink = nil
                displayedText = text
            }
            needsDisplay = true
        }
    }
    var notification = true
    var textFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var displayedText = ""
    private var countLink: CADisplayLink?
    private var countFrom = 0
    private var countTo = 0
    private var countStarted: CFTimeInterval = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 用屏幕刷新节拍滚动数字，到达目标后立即停表，保持原始徽章文字不变。
    @objc private func tickCount(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - countStarted) / 0.32)
        let eased = 1 - pow(1 - progress, 3)
        displayedText = String(Int((Double(countFrom) + Double(countTo - countFrom) * eased).rounded()))
        needsDisplay = true
        if progress >= 1 {
            displayedText = text
            link.invalidate()
            countLink = nil
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { countLink?.invalidate(); countLink = nil }
    }

    /// 以实际图标矩形而非按钮宽度定位，因而适配标题、四向停靠及缩放。
    func place(relativeTo icon: NSRect, flipped: Bool) {
        let side = max(1, min(icon.width, icon.height))
        let height = side * (notification ? 0.38 : 0.29)
        var fontSize = side * (notification ? 0.25 : 0.19)
        textFont = .systemFont(ofSize: fontSize, weight: .medium)
        var textWidth = (text as NSString).size(withAttributes: [.font: textFont]).width
        let available = max(height, side * 1.1) - height * 0.5
        if textWidth > available {
            fontSize *= available / textWidth
            textFont = .systemFont(ofSize: fontSize, weight: .medium)
            textWidth = available
        }
        let width = max(height, ceil(textWidth + height * 0.5))
        // 红色通知占右上；蓝灰窗口数移到右下，不与通知或底部运行圆点重叠。
        let upper = notification
        let y = (upper != flipped) ? icon.maxY - height * 0.85 : icon.minY - height * 0.15
        frame = NSRect(x: icon.maxX - width + side * 0.03, y: y, width: width, height: height)
        needsDisplay = true
    }

    /// 使用固定红底白字，不随玻璃明暗切换；小尺寸为圆，大内容自然扩成胶囊。
    override func draw(_ dirtyRect: NSRect) {
        (notification ? NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
                      : NSColor(srgbRed: 0.28, green: 0.36, blue: 0.46, alpha: 1)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: NSColor.white]
        let size = (displayedText as NSString).size(withAttributes: attributes)
        (displayedText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                         y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
