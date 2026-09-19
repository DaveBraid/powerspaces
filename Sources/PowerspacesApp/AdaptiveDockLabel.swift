// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 仅对标题使用背景感知黑白映射；合成器读取背景，不截图、不轮询、不改变图标。
final class AdaptiveDockLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 创建不接管鼠标的标题；未知系统回退语义色。
    init(text: String, font: NSFont) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        textColor = .labelColor
        wantsLayer = true
        if #available(macOS 27.0, *), ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
           let type = NSClassFromString("CAFilter") as? NSObject.Type,
           type.responds(to: NSSelectorFromString("filterWithType:")),
           let filter = type.perform(NSSelectorFromString("filterWithType:"), with: "vibrantColorMatrix")?.takeUnretainedValue() as? NSObject,
           filter.responds(to: NSSelectorFromString("inputKeys")),
           let keys = filter.value(forKey: "inputKeys") as? [String],
           ["inputColorMatrix", "inputBackdropAware", "inputClamp"].allSatisfy(keys.contains) {
            // 灰度亮度反向映射并钳位：暗底白字、亮底黑字，中间保持连续过渡。
            let row: [Float] = [-0.8504, -2.8608, -0.2888, 0, 2]
            let values = row + row + row + [0, 0, 0, 1, 0]
            let matrix = values.withUnsafeBufferPointer {
                NSValue(bytes: $0.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
            }
            filter.setValue(matrix, forKey: "inputColorMatrix")
            filter.setValue(true, forKey: "inputBackdropAware")
            filter.setValue(true, forKey: "inputClamp")
            textColor = .white
            layer?.filters = [filter]
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
