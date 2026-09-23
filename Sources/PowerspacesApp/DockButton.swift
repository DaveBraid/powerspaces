// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import QuartzCore
import SpaceKit

/// A dock icon button: reports right-clicks, shows a hover effect, and turns a
/// long-press into a left/right drag so the user can reorder the dock.
/// 标题与图标使用明确分区，避免 NSButtonCell 根据原始大图尺寸挤掉文字。
final class DockItemCell: NSButtonCell {
    var layoutScale: CGFloat = 1
    var iconOpacity: CGFloat = 1

    /// 只改变图标绘制透明度，运行灯和徽章保留独立状态与可读性。
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        guard iconOpacity < 1, let context = NSGraphicsContext.current?.cgContext else {
            super.drawImage(image, withFrame: frame, in: controlView)
            return
        }
        context.saveGState()
        context.setAlpha(iconOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil) // NSButtonCell 会重设内部 alpha，整组图标在合成时调暗。
        super.drawImage(image, withFrame: frame, in: controlView)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard imagePosition == .imageLeading else { return super.imageRect(forBounds: rect) }
        let side = rect.height * 0.7
        return NSRect(x: rect.minX + 4 * layoutScale, y: rect.midY - side / 2, width: side, height: side)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard imagePosition == .imageLeading else { return super.titleRect(forBounds: rect) }
        let left = imageRect(forBounds: rect).maxX + 8 * layoutScale
        let height = ceil((font?.ascender ?? 12) - (font?.descender ?? -4)) + 4
        return NSRect(x: left, y: rect.midY - height / 2,
                      width: max(0, rect.maxX - left - 8 * layoutScale), height: height)
    }
}

final class DockButton: NSButton {
    var onPointerLeft: (() -> Void)?
    var onPointerMoved: ((NSPoint) -> Void)? // 即时屏幕坐标，不重用布局前的事件坐标。
    var onIndicatorChanged: (() -> Void)?
    var usesSharedMagnification = false
    var restingWidth: CGFloat = 0
    var layoutScale: CGFloat = 1 // 拥挤时圆点间距随静止布局缩小，独立于悬停倍率。
    var crossAxisCenteringOffset: CGFloat = 0 {
        didSet {
            if oldValue != crossAxisCenteringOffset { invalidateIntrinsicContentSize(); needsUpdateConstraints = true; needsLayout = true }
        }
    }

    /// 侧边停靠时平移布局对齐框，让不同宽度的标题组合都居中；不改变按钮尺寸和点击区域。
    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        insets.left += crossAxisCenteringOffset
        insets.right -= crossAxisCenteringOffset
        return insets
    }
    private var runningDot: AdaptiveDockMark?
    /// 额外的窗口计数圆点（合并模式）。第一个圆点复用 `runningDot`，
    /// 因此拆分模式与「仅运行」的单点行为完全不变。
    private var extraDots: [AdaptiveDockMark] = []
    private var displayedIndicator: Indicator = .none
    private var requestedIndicator: Indicator?
    private var indicatorTransition = 0
    private var opacityLink: CADisplayLink?
    private var opacityFrom: CGFloat = 1
    private var opacityTo: CGFloat = 1
    private var opacityStarted: CFTimeInterval = 0

    /// 图标下方的运行/窗口指示。
    enum Indicator: Equatable {
        /// 不显示指示（已退出、或该条目不是应用）。
        case none
        /// 单个实心圆点：应用在运行且有窗口（拆分模式，或合并模式的一个窗口）。
        case running
        /// 合并模式：当前桌面有 `count` 个窗口 → `count` 个实心圆点。
        case windows(Int)
        /// 应用在运行但**当前桌面没有窗口** → 一个空心胶囊。
        /// 两种模式通用：拆分模式同样用它表示「没退出但本桌面没有窗口」。
        case emptyApp(vertical: Bool)
    }

    /// 空心胶囊沿停靠轴的长度与厚度（点）。比实心圆点长，视觉上一眼可分。
    private static let capsuleLength: CGFloat = 14
    private static let capsuleThickness: CGFloat = 4

    /// 设置指示标记。合并模式的圆点数量严格等于当前桌面的窗口数；
    /// 无窗口但仍在运行时用空心圆表示「没有完全退出」。
    func setIndicator(_ indicator: Indicator) {
        displayedIndicator = indicator
        requestedIndicator = nil
        let wanted: (count: Int, hollow: Bool, capsule: Bool)
        switch indicator {
        case .none: wanted = (0, false, false)
        case .running: wanted = (1, false, false)
        case .windows(let count): wanted = (max(0, count), false, false)
        case .emptyApp: wanted = (1, true, true)
        }
        // 圆点总数为 1 时走原有单点路径，保持几何与拆分模式一致。
        while extraDots.count > max(0, wanted.count - 1) {
            extraDots.removeLast().removeFromSuperview()
        }
        if runningDot == nil, wanted.count > 0 {
            let dot = wanted.capsule ? AdaptiveDockMark(capsule: true) : AdaptiveDockMark(circular: true)
            dot.alignment = .center
            dot.setAccessibilityElement(false)
            addSubview(dot)
            runningDot = dot
        }
        if wanted.count == 0 {
            runningDot?.removeFromSuperview()
            runningDot = nil
        }
        if wanted.capsule, runningDot?.isHollow == false {
            // 从实心圆点切到空心胶囊：形状不同，需要换一个标记视图。
            runningDot?.removeFromSuperview()
            let dot = AdaptiveDockMark(capsule: true)
            dot.alignment = .center
            dot.setAccessibilityElement(false)
            addSubview(dot)
            runningDot = dot
        } else if !wanted.capsule, runningDot?.isHollow == true, wanted.hollow == false {
            runningDot?.removeFromSuperview()
            let dot = AdaptiveDockMark(circular: true)
            dot.alignment = .center
            dot.setAccessibilityElement(false)
            addSubview(dot)
            runningDot = dot
        }
        if case .emptyApp(let vertical) = indicator { runningDot?.capsuleIsVertical = vertical }
        runningDot?.isHollow = wanted.hollow
        // 计数圆点始终是实心圆点。
        while extraDots.count < wanted.count - 1 {
            let dot = AdaptiveDockMark(circular: true)
            dot.alignment = .center
            dot.setAccessibilityElement(false)
            addSubview(dot)
            extraDots.append(dot)
        }
        for dot in extraDots { dot.isHollow = false }
        needsLayout = true
        onIndicatorChanged?()
    }

    /// 原位更新运行标记：淡出旧形状再淡入新形状，避免圆点与空心胶囊瞬间互换。
    func transitionIndicator(to indicator: Indicator, animated: Bool) {
        guard indicator != (requestedIndicator ?? displayedIndicator) else { return }
        indicatorTransition &+= 1
        let generation = indicatorTransition
        let oldMarks = ([runningDot].compactMap { $0 }) + extraDots
        requestedIndicator = indicator
        guard animated, !SystemDisplay.reduceMotion else { setIndicator(indicator); return }
        if indicator == displayedIndicator {
            requestedIndicator = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                oldMarks.forEach { $0.animator().alphaValue = 1 }
            }
            return
        }
        guard !oldMarks.isEmpty else {
            setIndicator(indicator)
            let newMarks = ([runningDot].compactMap { $0 }) + extraDots
            newMarks.forEach { $0.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                newMarks.forEach { $0.animator().alphaValue = 1 }
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            oldMarks.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.indicatorTransition == generation else { return }
                self.setIndicator(indicator)
                let newMarks = ([self.runningDot].compactMap { $0 }) + self.extraDots
                newMarks.forEach { $0.alphaValue = 0 }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13
                    newMarks.forEach { $0.animator().alphaValue = 1 }
                }
            }
        })
    }

    /// 只重绘图标透明度，徽章和运行标记不跟着变暗；刷新节拍仅在过渡期间运行。
    func setIconOpacity(_ target: CGFloat, animated: Bool) {
        guard let cell = cell as? DockItemCell else { return }
        guard animated, !SystemDisplay.reduceMotion, abs(cell.iconOpacity - target) > 0.001 else {
            opacityLink?.invalidate()
            opacityLink = nil
            cell.iconOpacity = target
            needsDisplay = true
            return
        }
        opacityFrom = cell.iconOpacity
        opacityTo = target
        opacityStarted = CACurrentMediaTime()
        if opacityLink == nil {
            let link = displayLink(target: self, selector: #selector(tickIconOpacity(_:)))
            link.add(to: .main, forMode: .common)
            opacityLink = link
        }
    }

    @objc private func tickIconOpacity(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - opacityStarted) / 0.22)
        let eased = progress * progress * (3 - 2 * progress)
        (cell as? DockItemCell)?.iconOpacity = opacityFrom + (opacityTo - opacityFrom) * eased
        needsDisplay = true
        if progress >= 1 { link.invalidate(); opacityLink = nil }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { opacityLink?.invalidate(); opacityLink = nil }
    }

    /// 兼容原有单点调用：`true` 等价于 `.running`。
    func setRunningDot(_ running: Bool) {
        setIndicator(running ? .running : .none)
    }

    /// 指示标记的纯规则。
    ///
    /// 两种模式共用一条前置规则：**应用在运行、但当前桌面没有窗口**时显示空心胶囊
    /// （表示没有完全退出）。除此之外，拆分模式一个实心圆点表示运行；合并模式圆点数
    /// 严格等于**当前桌面**的窗口数。已退出（仅因固定而保留）不显示标记。
    ///
    /// `vertical` 决定胶囊方向：顶部/底部停靠为横向，左/右停靠为纵向。
    nonisolated static func indicator(mode: DockWindowDisplayMode, isLauncher: Bool,
                                      isRunning: Bool, windowCount: Int,
                                      vertical: Bool = false) -> Indicator {
        guard !isLauncher, isRunning else { return .none }
        if windowCount == 0 { return .emptyApp(vertical: vertical) }
        guard mode == .merged else { return .running }
        return .windows(windowCount)
    }

    /// The app this icon stands for. Carried on the button (instead of an index
    /// tag) so it survives the live reordering of the stack view.
    var app: DockApp?
    /// This icon's identity for the join/leave diff: its app's `orderKey` plus
    /// which of the app's windows it stands for. The "Windows" feature duplicates
    /// an app into one icon per window (all sharing an `orderKey`), so this is what
    /// lets a single window opening or closing animate just the icon that changed
    /// instead of silently rebuilding the whole bar.
    var slotKey: String?
    var onRightClick: (() -> Void)?
    /// A middle-click (button 3): runs the user's configured middle-click action.
    var onMiddleClick: (() -> Void)?
    /// A plain click (short press, no drag): activate the app. `forceNew` is set
    /// when shift/option is held.
    var onActivate: ((DockApp, Bool, Bool) -> Void)? // (app, forceNew, jump)
    var onBeginDrag: ((DockButton) -> Void)?
    var onDragMove: ((DockButton, NSPoint) -> Void)?
    var onEndDrag: ((DockButton) -> Void)?
    /// The button's own size constraints (set when the dock builds it), held so
    /// the join animation can collapse the icon's slot to zero along the bar's
    /// layout axis and then animate it open.
    var widthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private(set) var isLifted = false

    /// How long the button must be held before a drag starts: long enough that a
    /// quick click still launches the app, short enough to feel deliberate.
    private static let holdThreshold: TimeInterval = 0.3

    /// Distinguishes a click from a reorder: hold the icon down past
    /// `holdThreshold`, then slide left or right. A short press falls through to
    /// `onActivate`. We run our own event loop (instead of leaning on
    /// `mouseDragged:`) so a perfectly still long-press still "lifts" the icon.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let downTime = Date()
        var dragging = false

        // Periodic events keep the loop ticking even when the pointer never
        // moves, so we notice the hold threshold has elapsed.
        NSEvent.startPeriodicEvents(afterDelay: DockButton.holdThreshold, withPeriod: 0.04)
        defer { NSEvent.stopPeriodicEvents() }

        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged, .periodic]
        loop: while let next = window?.nextEvent(matching: mask) {
            switch next.type {
            case .leftMouseUp:
                if dragging { onEndDrag?(self) } else { activate(with: next) }
                break loop
            case .leftMouseDragged, .periodic:
                if !dragging, Date().timeIntervalSince(downTime) >= DockButton.holdThreshold {
                    dragging = true
                    onBeginDrag?(self)
                }
                if dragging, next.type == .leftMouseDragged {
                    onDragMove?(self, next.locationInWindow)
                }
            default:
                break
            }
        }
    }

    private func activate(with event: NSEvent) {
        guard let app else { return }
        let forceNew = Preferences.shared.forceNewModifier.isPressed(event.modifierFlags)
        // 跳转修饰键（默认 Control）：按住点击不去新建窗口，而是直接跳到应用所在桌面。
        let jump = Preferences.shared.jumpModifier.isPressed(event.modifierFlags)
        // Acknowledge a launch / new-window click with a quick Dock-style bounce, so a
        // slow cold launch gives instant feedback. A click that just focuses a window
        // already on this desktop needs none (the window comes forward on its own).
        if !app.isLauncher, forceNew || app.windowCount == 0 { playLaunchFeedback() }
        onActivate?(app, forceNew, jump)
    }

    /// A quick hop toward the screen center (like the macOS Dock's launch bounce),
    /// matching the bar's edge. Auto-reverses back to rest, so it never disturbs
    /// layout. Skipped under Reduce Motion.
    private func playLaunchFeedback() {
        guard !SystemDisplay.reduceMotion else { return }
        wantsLayer = true
        layer?.masksToBounds = false
        let keyPath: String
        let distance: CGFloat
        switch Preferences.shared.barPosition {
        case .bottom: (keyPath, distance) = ("transform.translation.y", 10)
        case .top:    (keyPath, distance) = ("transform.translation.y", -10)
        case .left:   (keyPath, distance) = ("transform.translation.x", 10)
        case .right:  (keyPath, distance) = ("transform.translation.x", -10)
        }
        let bounce = CABasicAnimation(keyPath: keyPath)
        bounce.fromValue = 0
        bounce.toValue = distance
        bounce.duration = 0.16
        bounce.autoreverses = true
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(bounce, forKey: "launchBounce")
    }

    /// Visually picks the icon up off the bar while it's being dragged.
    func setLifted(_ on: Bool) {
        guard on != isLifted else { return }
        isLifted = on
        if on { isHovered = false } // re-arm hover bookkeeping for after the drop
        wantsLayer = true
        layer?.masksToBounds = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = SystemDisplay.reduceMotion ? 0 : 0.12 // instant lift under Reduce Motion
            ctx.allowsImplicitAnimation = true
            layer?.transform = on ? centeredScale(1.22) : CATransform3DIdentity
            layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.22).cgColor
                                        : NSColor.clear.cgColor
            layer?.shadowOpacity = on ? 0.35 : 0
            layer?.shadowRadius = on ? 8 : 0
            layer?.shadowOffset = on ? CGSize(width: 0, height: -2) : .zero
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return } // inVisibleRect 已自动跟随缩放。
        // `.inVisibleRect` lets AppKit keep the tracking region pinned to the
        // view's live bounds, so it stays stable while we're laid out near the
        // panel's edge instead of relying on a snapshot taken at one moment.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
        onPointerMoved?(NSEvent.mouseLocation)
    }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?(NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { setHover(false); onPointerLeft?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    /// Button number 2 is the middle mouse button (0 = left, 1 = right); other
    /// extra buttons are ignored.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
    }

    private func setHover(_ on: Bool) {
        // A lifted (being-dragged) icon owns its own larger transform; don't let
        // a stray enter/exit fight it.
        guard !isLifted else { return }
        // Idempotent: a repeated enter (e.g. cursor jittering on the boundary)
        // must not restart the magnify animation that's already running.
        guard on != isHovered else { return }
        isHovered = on
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        let prefs = Preferences.shared
        guard prefs.hoverEnabled else {
            // Hover disabled (possibly mid-hover): make sure nothing is left
            // magnified or highlighted.
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.transform = CATransform3DIdentity
            return
        }
        // 容器框仅由运行状态的框选层绘制，悬停只改变缩放。
        // Honor Reduce Motion: keep the (static) highlight, but skip the magnify and
        // apply it instantly so there's no animated scaling.
        let reduce = SystemDisplay.reduceMotion
        let scale = (reduce || usesSharedMagnification) ? 1.0 : CGFloat(prefs.hoverScale)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : prefs.hoverAnimation
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.transform = on ? edgeAnchoredScale(scale) : CATransform3DIdentity
        }
    }

    /// A scale anchored at the bar's OUTER edge, so the icon magnifies INWARD (toward
    /// the screen interior) instead of growing symmetrically. This keeps a hovered
    /// icon from spilling outward past the screen edge onto a vertically-stacked
    /// neighbouring display, and mirrors how the macOS Dock magnifies. NSView owns
    /// its backing layer's `anchorPoint` (the bottom-left corner), so we translate to
    /// the anchor, scale, then translate back.
    private func edgeAnchoredScale(_ factor: CGFloat) -> CATransform3D {
        // The anchor is the midpoint of the icon's outer edge — the side that hugs
        // the screen. (bounds is unflipped: minY is the bottom, maxY the top.)
        let ax: CGFloat, ay: CGFloat
        switch Preferences.shared.barPosition {
        case .bottom: ax = bounds.midX; ay = bounds.minY   // grow up
        case .top:    ax = bounds.midX; ay = bounds.maxY   // grow down
        case .left:   ax = bounds.minX; ay = bounds.midY   // grow right
        case .right:  ax = bounds.maxX; ay = bounds.midY   // grow left
        }
        var t = CATransform3DMakeTranslation(ax, ay, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -ax, -ay, 0)
    }

    /// A scale anchored at the icon's center. NSView owns its backing layer's
    /// `anchorPoint` (effectively the bottom-left corner), so a plain
    /// `CATransform3DMakeScale` magnifies toward the top-right. Translating to
    /// the center, scaling, then translating back keeps it growing in place. Used
    /// by the press feedback and the shrink/poof remove animations, which grow or
    /// shrink symmetrically (unlike the hover magnify, which grows inward).
    private func centeredScale(_ factor: CGFloat) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    /// A centered scale (like `centeredScale`) that also slides the icon's center
    /// by `offset` — so a shrunk copy lands on a neighbouring icon. Used by the
    /// per-window "fold into the sibling" leave animation.
    private func mergeScale(_ factor: CGFloat, toward offset: CGVector) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(offset.dx + cx, offset.dy + cy, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    // MARK: - Join / leave animation

    /// The "not in the dock" layer state for `style`: the transform the icon
    /// animates from when appearing / to when leaving, plus an `opacity`. `slideOff`
    /// is the unit direction — in the view's unflipped coordinates — the icon flies
    /// toward the screen edge for `.slideOff`; other styles ignore it. Needs valid
    /// `bounds`, so call it once the icon is at full size.
    private func applyHiddenState(style: IconAnimationStyle, slideOff: CGVector, opacity: Float) {
        wantsLayer = true
        layer?.masksToBounds = false // poof / slide may spill past our bounds
        layer?.opacity = opacity
        switch style {
        case .fade:
            layer?.transform = CATransform3DIdentity
        case .shrink:
            layer?.transform = centeredScale(0.2)
        case .poof:
            layer?.transform = centeredScale(1.6)
        case .slideOff:
            let dist = bounds.height
            layer?.transform = CATransform3DMakeTranslation(slideOff.dx * dist, slideOff.dy * dist, 0)
        }
    }

    /// Animate this icon away as its app leaves the dock — it fades out as it
    /// transforms. Call inside an `NSAnimationContext` group with
    /// `allowsImplicitAnimation` (the caller owns the duration / timing).
    func playDisappear(style: IconAnimationStyle, slideOff: CGVector) {
        applyHiddenState(style: style, slideOff: slideOff, opacity: 0)
    }

    /// Animate this icon *folding into a sibling* as it leaves — used when one of an
    /// app's per-window icons goes away (a window closed) but the app keeps another
    /// icon. It shrinks and slides toward `offset` (the vector, in this view's
    /// coordinates, to the surviving icon's center) instead of sliding off-screen,
    /// so the closing window looks absorbed by its neighbour. Call inside an
    /// `NSAnimationContext` group with `allowsImplicitAnimation`.
    func playMerge(toward offset: CGVector) {
        wantsLayer = true
        layer?.masksToBounds = false // the icon slides toward its neighbour as it shrinks
        layer?.opacity = 0
        layer?.transform = mergeScale(0.1, toward: offset)
    }

    /// Snap this icon to its start-of-appear pose *before* the appear animation.
    /// Call instantly (outside an animation group) once the slot is open and the
    /// icon is at full size. Fade starts invisible (it fades in); the transform
    /// styles start *opaque* at their offset pose, so the motion (grow / poof /
    /// slide) is actually seen instead of being hidden behind an opacity ramp.
    func prepareToAppear(style: IconAnimationStyle, slideOff: CGVector) {
        applyHiddenState(style: style, slideOff: slideOff, opacity: style == .fade ? 0 : 1)
    }

    /// Animate this icon to its resting state as its app joins the dock. Call
    /// inside an `NSAnimationContext` group with `allowsImplicitAnimation`.
    func playAppear() {
        layer?.opacity = 1
        layer?.transform = CATransform3DIdentity
    }

    // MARK: - Running "box" indicator

    /// The "boxed" running style: a rounded `outlineColor` outline framing the
    /// icon, its inside tinted with `highlightColor`. Kept on its own sublayer so
    /// it composes with (and magnifies under) the hover transform without fighting
    /// the hover highlight, which lives on the button's own layer.
    private var boxLayer: CALayer?
    private var badgeRemovalGeneration = 0
    private var boxActive = false
    private var boxGap: CGFloat = 0
    private var boxOutlineWidth: CGFloat = 2
    private var boxOutlineColor: NSColor = .clear
    /// The inside-fill color, including its alpha: the user controls how translucent
    /// the highlight is via the color picker's opacity, so it's applied verbatim.
    private var boxHighlightColor: NSColor = .clear

    /// Show or hide the running box. `gap` is how far the outline floats out from
    /// the icon (0 = snug); the outline uses `outlineColor` at `outlineWidth`, and
    /// the inside is tinted with `highlightColor`.
    func setRunningBox(active: Bool, gap: CGFloat, outlineWidth: CGFloat,
                       outlineColor: NSColor, highlightColor: NSColor) {
        let wasActive = boxActive
        boxActive = active
        boxGap = gap
        boxOutlineWidth = outlineWidth
        boxOutlineColor = outlineColor
        boxHighlightColor = highlightColor
        wantsLayer = true
        layer?.masksToBounds = false // the box can sit slightly outside our bounds
        updateBoxLayer()
        if wasActive != active, let boxLayer {
            let from = boxLayer.presentation()?.opacity ?? (wasActive ? 1 : 0)
            let to: Float = active ? 1 : 0
            boxLayer.opacity = to
            if !SystemDisplay.reduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = to
                fade.duration = 0.2
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                boxLayer.add(fade, forKey: "runningState")
            }
        }
    }

    private var adaptiveTitle: AdaptiveDockLabel?

    /// 标题单独参与背景感知合成，保留按钮的点击、拖放、图标和布局。
    func setAdaptiveTitle(_ text: String, font: NSFont) {
        adaptiveTitle?.removeFromSuperview()
        let label = AdaptiveDockLabel(text: text, font: font)
        label.setAccessibilityElement(false) // 按钮自身已提供名称，避免重复朗读。
        addSubview(label)
        adaptiveTitle = label
        needsLayout = true
    }

    /// 指示灯标记在自身坐标系里的条带（沿停靠轴全长、横轴覆盖标记厚度）。
    ///
    /// 供程序坞面板定位「统一亮度采样区」：判定要对齐指示灯实际覆盖的背景，
    /// 而不是整块玻璃（含图标区，会把亮度带偏）。
    var indicatorBand: NSRect {
        guard runningDot != nil || !extraDots.isEmpty else { return .zero }
        let isVertical = Preferences.shared.barPosition.isVertical
        let gap = CGFloat(Preferences.shared.runningDotGap) * layoutScale
        let thickness = Preferences.shared.barPosition.isVertical
            ? Self.capsuleThickness : Self.capsuleThickness
        if isVertical {
            return NSRect(x: -gap - thickness, y: bounds.minY,
                          width: thickness, height: bounds.height)
        }
        return NSRect(x: bounds.minX, y: -gap - thickness,
                      width: bounds.width, height: thickness)
    }

    override func layout() {
        super.layout()
        updateBoxLayer() // bounds are only real once we've been laid out
        let isVertical = Preferences.shared.barPosition.isVertical
        let size: CGFloat = 4 // 圆点直径固定，不参与图标放大。
        // 空心胶囊沿停靠轴更长，横轴仍是一个圆点厚，圆角由绘制取短边一半。
        let capsule = NSRect(x: 0, y: 0,
                             width: isVertical ? Self.capsuleThickness : Self.capsuleLength,
                             height: isVertical ? Self.capsuleLength : Self.capsuleThickness)
        let markSize: (AdaptiveDockMark) -> NSSize = { mark in
            mark.isHollow ? capsule.size : NSSize(width: size, height: size)
        }
        let gap = CGFloat(Preferences.shared.runningDotGap) * layoutScale
        let imageRect = cell?.imageRect(forBounds: bounds) ?? bounds
        windowBadge?.place(relativeTo: imageRect, flipped: isFlipped)
        notificationBadge?.place(relativeTo: imageRect, flipped: isFlipped)
        // 多个圆点时沿停靠轴均匀排开（间距用一个圆点直径），整体在图标上居中。
        let allDots = ([runningDot].compactMap { $0 }) + extraDots
        let spacing = size
        let totalLength = CGFloat(allDots.count) * size + CGFloat(max(0, allDots.count - 1)) * spacing
        let startOffset = -totalLength / 2 + size / 2
        for (index, dot) in allDots.enumerated() {
            let along = startOffset + CGFloat(index) * (size + spacing)
            let side = markSize(dot)
            switch Preferences.shared.barPosition {
            case .bottom:
                dot.frame = NSRect(x: imageRect.midX + along - side.width / 2,
                    y: isFlipped ? bounds.maxY + gap : -gap - side.height,
                    width: side.width, height: side.height)
            case .top:
                dot.frame = NSRect(x: imageRect.midX + along - side.width / 2,
                    y: isFlipped ? -gap - side.height : bounds.maxY + gap,
                    width: side.width, height: side.height)
            case .left:
                dot.frame = NSRect(x: -gap - side.width + crossAxisCenteringOffset,
                    y: imageRect.midY + along - side.height / 2,
                    width: side.width, height: side.height)
            case .right:
                dot.frame = NSRect(x: bounds.maxX + gap + crossAxisCenteringOffset,
                    y: imageRect.midY + along - side.height / 2,
                    width: side.width, height: side.height)
            }
        }
        if let adaptiveTitle, let cell {
            adaptiveTitle.frame = cell.titleRect(forBounds: bounds)
        }
    }

    // MARK: - 应用通知与桌面窗口数各自独立

    private var windowBadge: DockBadgeView?
    private var notificationBadge: DockBadgeView?

    /// 窗口数保留原有语义，移到图标右下，避免与右上通知徽章冲突。
    func setWindowBadge(count: Int) {
        windowBadge?.removeFromSuperview()
        windowBadge = nil
        guard count > 1 else { return }
        let badge = DockBadgeView()
        badge.notification = false
        badge.text = String(count)
        badge.setAccessibilityElement(false)
        addSubview(badge)
        windowBadge = badge
        needsLayout = true
    }

    /// 空值移除，其他文本原样保留；只更新覆盖层，不重建按钮或中断交互。
    func setNotificationBadge(_ text: String?) {
        guard let text, !text.isEmpty else {
            guard let badge = notificationBadge else { return }
            badgeRemovalGeneration &+= 1
            let generation = badgeRemovalGeneration
            guard !SystemDisplay.reduceMotion else {
                badge.removeFromSuperview()
                notificationBadge = nil
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                badge.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak badge] in
                MainActor.assumeIsolated {
                    guard let self, let badge, self.notificationBadge === badge,
                          self.badgeRemovalGeneration == generation else { return }
                    badge.removeFromSuperview()
                    self.notificationBadge = nil
                }
            })
            return
        }
        badgeRemovalGeneration &+= 1
        if notificationBadge == nil {
            let badge = DockBadgeView()
            badge.setAccessibilityElement(false)
            badge.alphaValue = SystemDisplay.reduceMotion ? 1 : 0
            addSubview(badge)
            notificationBadge = badge
        }
        notificationBadge?.text = text
        if let badge = notificationBadge, badge.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                badge.animator().alphaValue = 1
            }
        }
        needsLayout = true
    }

    private func updateBoxLayer() {
        guard boxActive || boxLayer != nil else { return }
        let box = boxLayer ?? {
            let l = CALayer()
            layer?.insertSublayer(l, at: 0)
            boxLayer = l
            return l
        }()
        let frame = bounds.insetBy(dx: -boxGap, dy: -boxGap)
        // No implicit animation: the box should track layout/hover instantly, not
        // slide a frame behind every relayout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = frame
        box.cornerRadius = min(frame.width, frame.height) * 0.25
        box.borderWidth = boxOutlineWidth
        box.borderColor = boxOutlineColor.cgColor
        box.backgroundColor = boxHighlightColor.cgColor
        CATransaction.commit()
    }
}
