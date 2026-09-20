// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 按元素整体背景亮度选择纯黑或纯白，避免逐像素反色造成混色。
class AdaptiveDockLabel: NSTextField {
    private var luminanceLayer: CALayer?
    private var luminanceObserver: DockLuminanceObserver?
    private var usesWhite: Bool?
    /// 面板下发的统一颜色；非 nil 时优先于逐元素采样。
    private var forcedTextColor: NSColor?

    /// 面板层统一判定使用：按背景亮度选纯黑或纯白。
    ///
    /// 判定必须**整块程序坞一次**，不能让每个元素各自采样：圆点背后是图标映上来的
    /// 亮玻璃、分割线是 1pt 细线采到暗色，逐元素判定会出现白圆点配黑分割线。
    /// 迟滞（0.57 / 0.43）避免临界亮度来回翻转。
    static func unifiedTextColor(luminance: Double, previous: Bool?) -> NSColor {
        guard luminance.isFinite, (0...1).contains(luminance) else { return .white }
        let white = previous.map { $0 ? luminance < 0.57 : luminance < 0.43 } ?? (luminance < 0.5)
        return white ? .white : .black
    }

    /// 面板下发统一颜色；传入后停止逐元素采样，保证同一块玻璃上只有一个颜色。
    func applyUnifiedTextColor(_ color: NSColor?) {
        forcedTextColor = color
        luminanceLayer?.removeFromSuperlayer()
        luminanceLayer = nil
        luminanceObserver = nil
        if let color {
            textColor = color
            needsDisplay = true
        }
    }

    /// 当前是否由面板统一指定颜色。
    var hasUnifiedTextColor: Bool { forcedTextColor != nil }

    /// 合成器只返回整个元素区域的平均亮度；不读取像素，不增加应用侧轮询。
    private func installLuminanceTracking() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }
        let backdrop = type.init()
        guard ["setTracksLuma:", "setCaptureOnly:", "setWindowServerAware:"].allSatisfy({
            backdrop.responds(to: NSSelectorFromString($0))
        }) else { return }
        let observer = DockLuminanceObserver()
        observer.changed = { [weak self] value in self?.applyLuminance(value) }
        backdrop.delegate = observer
        backdrop.setValue(true, forKey: "captureOnly") // 只统计背景，不绘制第二层玻璃。
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "tracksLuma")
        luminanceLayer = backdrop
        luminanceObserver = observer
    }

    /// 使用迟滞避免临界亮度闪烁，整段文字或整条线始终只有一种颜色。
    /// 面板已下发统一颜色时不做任何事——否则又会退回逐元素判定。
    private func applyLuminance(_ value: Double) {
        guard forcedTextColor == nil else { return }
        guard value.isFinite, (0...1).contains(value) else {
            usesWhite = nil
            textColor = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
            needsDisplay = true
            return
        }
        let white = usesWhite.map { $0 ? value < 0.57 : value < 0.43 } ?? (value < 0.5)
        guard usesWhite != white else { return }
        usesWhite = white
        textColor = white ? .white : .black
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateLuminanceRegion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if usesWhite == nil { applyLuminance(.nan) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLuminanceRegion()
    }

    /// 采样层必须是文字层下方的兄弟层，避免细线覆盖采样区并形成颜色反馈。
    private func updateLuminanceRegion() {
        guard forcedTextColor == nil, let sample = luminanceLayer else { return }
        guard let parent = superview, let foreground = layer else {
            sample.removeFromSuperlayer()
            return
        }
        parent.wantsLayer = true
        guard let parentLayer = parent.layer else { return }
        if sample.superlayer !== parentLayer {
            sample.removeFromSuperlayer()
            parentLayer.insertSublayer(sample, below: foreground)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sample.frame = foreground.frame
        CATransaction.commit()
    }

    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 创建不接管鼠标的标题；未知系统回退语义色。
    init(text: String, font: NSFont, gray: Bool = false) {
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        textColor = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        wantsLayer = true
        installLuminanceTracking()

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 复用文字的背景感知合成，只绘制几何标记，避免字体基线影响圆点位置。
final class AdaptiveDockMark: AdaptiveDockLabel {
    /// 标记形状。
    enum Shape {
        /// 实心圆点：表示运行中（或合并模式下的窗口计数）。
        case circle
        /// 分隔线用的长条。
        case bar
        /// 空心胶囊：应用在运行、但当前桌面没有窗口。方向跟随停靠方向，
        /// 与图标行平行，比空心圆更容易和实心圆点区分。
        case capsule
    }

    // 几何标记不能继承文字控件左右各 2 点的对齐边距。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    private let circular: Bool
    private let shape: Shape
    /// 空心标记：只描边不填充，用于表示「应用在运行、但当前桌面没有窗口」。
    var isHollow = false {
        didSet { if isHollow != oldValue { needsDisplay = true } }
    }
    /// 胶囊是否沿竖直方向（左右停靠时为真）。
    var capsuleIsVertical = false {
        didSet { if capsuleIsVertical != oldValue { needsDisplay = true } }
    }

    init(circular: Bool, gray: Bool = false) {
        self.circular = circular
        self.shape = circular ? .circle : .bar
        super.init(text: "", font: .systemFont(ofSize: 1), gray: gray)
        setAccessibilityElement(false)
    }

    /// 空心胶囊专用初始化。
    init(capsule: Bool, gray: Bool = false) {
        self.circular = false
        self.shape = .capsule
        super.init(text: "", font: .systemFont(ofSize: 1), gray: gray)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let color = textColor ?? .secondaryLabelColor
        switch shape {
        case .circle:
            let path = NSBezierPath(ovalIn: bounds)
            guard isHollow else { color.setFill(); path.fill(); return }
            // 描边宽度按尺寸收敛，避免小圆点被描边糊成一个实心点。
            color.setStroke()
            path.lineWidth = max(1, min(bounds.width, bounds.height) * 0.22)
            path.stroke()
        case .bar:
            color.setFill()
            NSBezierPath(rect: bounds).fill()
        case .capsule:
            // 圆角半径取短边的一半即得胶囊；长边由调用方按停靠方向给定。
            let radius = min(bounds.width, bounds.height) / 2
            let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            color.setStroke()
            path.lineWidth = max(1, radius * 0.5)
            path.stroke()
        }
    }
}

/// 系统亮度回调签名已核对；受保护的背景回退语义色，不尝试绕过保护。
private final class DockLuminanceObserver: NSObject, CALayerDelegate {
    var changed: ((Double) -> Void)?
    @objc func backdropLayer(_ layer: CALayer, didChangeLuma value: Double) {
        changed?(value)
    }
    @objc func backdropLayer(_ layer: CALayer, didSampleProtectedLuma protected: Bool) {
        if protected { changed?(.nan) }
    }
}

/// 分割线独占两侧留白；标记直接对齐玻璃中心，不继承图标贴边及缩放位置。
final class DockDividerView: NSView {
    let mark = AdaptiveDockMark(circular: false)
    private let verticalDock: Bool
    init(verticalDock: Bool, length: CGFloat, gap: CGFloat, crossSize: CGFloat, thickness: CGFloat = 1) {
        self.verticalDock = verticalDock
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: verticalDock ? crossSize : gap * 2 + thickness),
            heightAnchor.constraint(equalToConstant: verticalDock ? gap * 2 + thickness : crossSize),
            mark.widthAnchor.constraint(equalToConstant: verticalDock ? length : thickness),
            mark.heightAnchor.constraint(equalToConstant: verticalDock ? thickness : length),
        ])
    }
    /// 加入共同视图树后绑定玻璃中心，四边停靠与放大均保持居中。
    func align(to glass: NSView) {
        NSLayoutConstraint.activate(verticalDock ? [
            mark.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] : [
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 玻璃层亮度采样回调桥接（`CABackdropLayer` 的 delegate 需要 Objective-C 方法）。
///
/// 与逐元素采样用的是同一套合成器回调，区别只是采样区域是**整块玻璃**。
final class DockLuminanceBridge: NSObject, CALayerDelegate {
    private let changed: (Double) -> Void
    init(changed: @escaping (Double) -> Void) { self.changed = changed }
    @objc func backdropLayer(_ layer: CALayer, didChangeLuma value: Double) { changed(value) }
    @objc func backdropLayer(_ layer: CALayer, didSampleProtectedLuma protected: Bool) {
        if protected { changed(.nan) }
    }
}
