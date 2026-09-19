// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 固定背景和尺寸的光学对照；仅供 --preview-glass 使用，不读取真实桌面。
@MainActor
final class GlassComparisonWindow {
    private static var window: NSWindow?

    /// 同时展示原生与增强透光的 64 点玻璃，确保比较时背景和几何一致。
    static func show() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                              styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        self.window = window
        window.title = "Liquid Glass — public clear / native Dock recipe"
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let backdrop = ComparisonBackdrop(frame: window.contentLayoutRect)
        window.contentView = backdrop
        for (index, nativeDock) in [false, true].enumerated() {
            let glass = GlassSurfaceView(frame: NSRect(x: 40, y: 230 - index * 150, width: 680, height: 64))
            glass.allowsNativeDockMaterial = nativeDock
            glass.dockMode = true
            glass.backgroundTransparency = 0.8
            glass.cornerRadius = 20
            backdrop.addSubview(glass)
            // 前景始终归属现有 AppKit 容器，只有背景材质不同。
            let symbols = NSStackView()
            symbols.spacing = 35
            for name in ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal"] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                    let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
                    icon.imageScaling = .scaleProportionallyUpOrDown
                    icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
                    symbols.addArrangedSubview(icon)
                }
            }
            let title = DockButton()
            title.isBordered = false
            let titleFont = NSFont.systemFont(ofSize: 18, weight: .medium)
            title.attributedTitle = NSAttributedString(string: "Ghostty 标题", attributes: [
                .foregroundColor: NSColor.clear, .font: titleFont,
            ])
            title.setAdaptiveTitle("Ghostty 标题", font: titleFont)
            title.widthAnchor.constraint(equalToConstant: 150).isActive = true
            title.heightAnchor.constraint(equalToConstant: 44).isActive = true
            symbols.addArrangedSubview(title)
            let divider = DockDividerView(verticalDock: false, length: 42, gap: 8, crossSize: 44)
            symbols.addArrangedSubview(divider)
            glass.glassContent.addSubview(symbols)
            divider.align(to: glass)
            symbols.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                symbols.centerXAnchor.constraint(equalTo: glass.glassContent.centerXAnchor),
                symbols.centerYAnchor.constraint(equalTo: glass.glassContent.centerYAnchor),
            ])
        }
        window.center()
        window.orderFrontRegardless()
    }
}

/// 两行共用相同条纹与文字，便于观察透镜形变和明暗边界。
private final class ComparisonBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for row in 0..<2 {
            let y = CGFloat(230 - row * 150)
            for column in 0..<19 {
                (column.isMultiple(of: 2) ? NSColor.black : NSColor.white).setFill()
                NSRect(x: CGFloat(column * 40), y: y - 12, width: 40, height: 88).fill()
            }
            let label = row == 0 ? "Public clear · 80% transparency" : "Native Dock recipe · windowAppearsActive · 80%"
            (label as NSString).draw(at: NSPoint(x: 40, y: y + 87), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
            ])
        }
    }
}
