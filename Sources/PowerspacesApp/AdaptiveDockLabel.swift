// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 按元素整体背景亮度选择纯黑或纯白，避免逐像素反色造成混色。
class AdaptiveDockLabel: NSTextField {
    private var luminanceLayer: CALayer?
    private var luminanceObserver: DockLuminanceObserver?
    private var usesWhite: Bool?

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
    private func applyLuminance(_ value: Double) {
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
        guard let sample = luminanceLayer else { return }
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
    // 几何标记不能继承文字控件左右各 2 点的对齐边距。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    private let circular: Bool
    init(circular: Bool, gray: Bool = false) {
        self.circular = circular
        super.init(text: "", font: .systemFont(ofSize: 1), gray: gray)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        (textColor ?? .secondaryLabelColor).setFill()
        let path = circular ? NSBezierPath(ovalIn: bounds) : NSBezierPath(rect: bounds)
        path.fill()
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
