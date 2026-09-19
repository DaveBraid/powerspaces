// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 共用背景：macOS 26 起使用原生 Liquid Glass，旧系统保留原有材质。
@MainActor
final class GlassSurfaceView: NSView {
    private let surface: NSView
    let glassContent = NSView()
    var dockMode = false { didSet { refresh() } }
    var settingsMode = false { didSet { refresh() } }
    private var hostsContent: Bool { dockMode || settingsMode }
    var material: NSVisualEffectView.Material = .hudWindow { didSet { refresh() } }
    var cornerRadius: CGFloat = 16 { didSet { refresh() } } // 与程序坞现有圆角保持一致。
    var solid = false { didSet { refresh() } }
    var opacity: CGFloat = 1 { didSet { refresh() } }
    var highlightStrength: Double = 1 { didSet { refresh() } }
    var highlightWidth: Double = 1 { didSet { refresh() } }
    var enhancesEdges = true { didSet { refresh() } }
    var backgroundTransparency: Double = 0 { didSet { refresh() } }
    var tintColor: NSColor? { didSet { refresh() } }

    /// 创建原生玻璃及前景容器；保留内容交互和悬停放大区域。
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = TunableGlassEffectView()
            glass.style = .regular
            surface = glass
        } else {
            let blur = NSVisualEffectView()
            blur.state = .active
            blur.blendingMode = .behindWindow
            surface = blur
        }
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        surface.clipsToBounds = false
        glassContent.clipsToBounds = false
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = glassContent // 让系统管理前景与玻璃的自适应关系。
        } else {
            glassContent.frame = bounds
            glassContent.autoresizingMask = [.width, .height]
            addSubview(glassContent)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refresh()
    }

    /// 旧系统的染色位于材质之上、前景之下，降低透明度也不能遮住图标。
    func installTintOverlay(_ overlay: NSView) {
        addSubview(overlay, positioned: .above, relativeTo: surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按辅助功能和颜色配置更新背景；降低透明度时使用不透明填充。
    @objc private func refresh() {
        layer?.cornerRadius = cornerRadius
        let opaque = SystemDisplay.reduceTransparency || solid
        // Dock 的光学层保持完整，浓度只调染色；不能把前景和高光一起淡出。
        alphaValue = hostsContent || SystemDisplay.reduceTransparency ? 1 : opacity
        if hostsContent {
            if opaque {
                if glassContent.superview !== self {
                    if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                        glass.contentView = nil
                    }
                    glassContent.removeFromSuperview()
                    glassContent.frame = bounds
                    glassContent.autoresizingMask = [.width, .height]
                    addSubview(glassContent)
                }
            } else if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView,
                      glassContent.superview === self {
                glassContent.removeFromSuperview()
                glass.contentView = glassContent
            }
        }
        let toneColor: NSColor = material == .menu ? .black
            : material == .popover ? .white : .windowBackgroundColor
        surface.isHidden = opaque
        layer?.backgroundColor = opaque
            ? (tintColor ?? toneColor).withAlphaComponent(SystemDisplay.reduceTransparency ? 1 : opacity).cgColor : nil
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            if let tunable = glass as? TunableGlassEffectView {
                tunable.highlightStrength = highlightStrength
                tunable.highlightWidth = highlightWidth
                tunable.enhancesEdges = dockMode && !opaque && enhancesEdges
                tunable.backgroundTransparency = dockMode && !opaque ? backgroundTransparency : 0
            }
            glass.cornerRadius = cornerRadius
            glass.style = dockMode ? .clear : .regular // 设置文字密集，使用系统自适应可读性材质。
            if #available(macOS 27.0, *) { glass.effectIsInteractive = dockMode }

            // 明暗通过独立 appearance 强制生效，自定义染色不再覆盖明暗选择。
            glass.appearance = material == .menu ? NSAppearance(named: .darkAqua)
                : material == .popover ? NSAppearance(named: .aqua) : nil
            if dockMode {
                // clear 保留透镜与轮廓，浅色／深色使用轻微染色，避免大块灰底。
                let neutral: NSColor? = material == .menu ? .black
                    : material == .popover ? .white : nil
                glass.tintColor = tintColor.map { $0.withAlphaComponent(opacity) }
                    ?? neutral?.withAlphaComponent(0.18 * opacity)
            } else {
                glass.tintColor = tintColor
            }
        } else if let blur = surface as? NSVisualEffectView {
            blur.alphaValue = SystemDisplay.reduceTransparency ? 1 : opacity
            blur.material = material
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.masksToBounds = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// 前景正常接收事件，空白区继续交给窗口或程序坞拖放容器。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hostsContent else { return nil }
        let local = convert(point, from: superview)
        let contentPoint = glassContent.convert(local, from: self)
        for child in glassContent.subviews.reversed() {
            // NSView.hitTest 接受父视图坐标，不能重复转换成子视图坐标。
            if let hit = child.hitTest(contentPoint) { return hit }
        }
        return nil
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}

