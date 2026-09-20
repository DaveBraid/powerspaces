// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 共用背景：macOS 26 起使用原生 Liquid Glass，旧系统保留原有材质。
@MainActor
final class GlassSurfaceView: NSView {
    private let surface: NSView
    private var nativeDockSurface: NativeDockMaterialView?
    private var nativeDockFailed = false
    var allowsNativeDockMaterial = true { didSet { refresh() } } // 开发验证可强制公开材质回退。
    var usesNativeDockMaterial: Bool { nativeDockSurface?.isHidden == false }
    let glassContent = NSView()

    /// 整块玻璃背景亮度变化时回调（参数为 0…1 的平均亮度，无法采样时为 .nan）。
    var onLuminanceChanged: ((Double) -> Void)?
    /// 采样区域（玻璃坐标系）；nil 表示整块玻璃。由面板指向指示灯条带。
    var luminanceRegion: (() -> NSRect)? {
        didSet { needsLayout = true }
    }
    /// 采样层：覆盖采样区域，只统计背景、不参与绘制。
    private var luminanceLayer: CALayer?
    private var luminanceObserver: DockLuminanceBridge?

    /// 安装整块玻璃的亮度采样。
    ///
    /// 判定必须一次做在整块程序坞上：`AdaptiveDockLabel` 原先每个元素各采样自己那一小块，
    /// 圆点背后是图标映上来的亮玻璃、分割线是 1pt 细线采到暗色，于是出现白圆点配黑分割线。
    func installLuminanceTracking() {
        guard luminanceLayer == nil,
              ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }
        let backdrop = type.init()
        guard ["setTracksLuma:", "setCaptureOnly:", "setWindowServerAware:"].allSatisfy({
            backdrop.responds(to: NSSelectorFromString($0))
        }) else { return }
        let bridge = DockLuminanceBridge { [weak self] value in self?.onLuminanceChanged?(value) }
        backdrop.delegate = bridge
        backdrop.setValue(true, forKey: "captureOnly")
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "tracksLuma")
        layer?.addSublayer(backdrop)
        luminanceLayer = backdrop
        luminanceObserver = bridge
    }

    var dockMode = false { didSet { refresh() } }
    var settingsMode = false { didSet { refresh() } }
    private var hostsContent: Bool { dockMode || settingsMode }
    var material: NSVisualEffectView.Material = .hudWindow { didSet { refresh() } }
    var cornerRadius: CGFloat = 16 { didSet { refresh() } } // 与程序坞现有圆角保持一致。
    var solid = false { didSet { refresh() } }
    var opacity: CGFloat = 1 { didSet { refresh() } }
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
        glassContent.autoresizingMask = [.width, .height]
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

    /// 窗口动态扩容时同步原生前景尺寸，避免内容容器停在旧宽度而裁掉标题与图标。
    override func layout() {
        super.layout()
        surface.frame = bounds
        nativeDockSurface?.frame = bounds
        if let sample = luminanceLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sample.frame = luminanceRegion?() ?? bounds
            CATransaction.commit()
        }
        if hostsContent { glassContent.frame = bounds }
        if dockMode {
            // AppKit 在图层重建时可能恢复裁切；仅背景有圆角，放大前景必须能越过玻璃边界。
            clipsToBounds = false
            layer?.masksToBounds = false
        }
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
        if dockMode, allowsNativeDockMaterial, !nativeDockFailed, nativeDockSurface == nil,
           let recipe = NativeDockRecipe.shared {
            let native = NativeDockMaterialView(recipe: recipe)
            native.frame = bounds
            native.autoresizingMask = [.width, .height]
            native.onFailure = { [weak self] in self?.fallBackToPublicGlass() }
            addSubview(native, positioned: .above, relativeTo: surface)
            nativeDockSurface = native
        }
        let nativeEnabled = dockMode && allowsNativeDockMaterial && nativeDockSurface != nil && !opaque
        nativeDockSurface?.isHidden = !nativeEnabled
        // Dock 的光学层保持完整，浓度只调染色；不能把前景和高光一起淡出。
        alphaValue = hostsContent || SystemDisplay.reduceTransparency ? 1 : opacity
        if hostsContent {
            if opaque || nativeEnabled {
                if glassContent.superview !== self {
                    if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                        glass.contentView = nil
                    }
                    glassContent.removeFromSuperview()
                    glassContent.translatesAutoresizingMaskIntoConstraints = true // 脱离原生 contentView 后恢复手动尺寸管理。
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
        surface.isHidden = opaque || nativeEnabled
        if nativeEnabled {
            let neutral: NSColor? = material == .menu ? .black : material == .popover ? .white : nil
            nativeDockSurface?.update(radius: cornerRadius,
                tint: tintColor.map { $0.withAlphaComponent(opacity) } ?? neutral?.withAlphaComponent(0.18 * opacity),
                appearance: material == .menu ? NSAppearance(named: .darkAqua)
                    : material == .popover ? NSAppearance(named: .aqua) : nil,
                transparency: backgroundTransparency)
        }
        layer?.backgroundColor = opaque
            ? (tintColor ?? toneColor).withAlphaComponent(SystemDisplay.reduceTransparency ? 1 : opacity).cgColor : nil
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            if let tunable = glass as? TunableGlassEffectView {
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

    /// 渲染探测失败后本视图不再重试私有材质，前景返回现有公开玻璃层。
    private func fallBackToPublicGlass() {
        nativeDockFailed = true
        nativeDockSurface?.removeFromSuperview()
        nativeDockSurface = nil
        refresh()
        needsLayout = true
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

