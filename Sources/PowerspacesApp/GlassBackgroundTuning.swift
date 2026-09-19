// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 隔离 macOS 27 私有玻璃参数；分别调整背景与边缘高光，保持前景及折射。
@available(macOS 26.0, *)
@MainActor
final class TunableGlassEffectView: NSGlassEffectView {
    var highlightStrength: Double = 1 { didSet { scheduleTuning() } }
    var highlightWidth: Double = 1 { didSet { scheduleTuning() } }
    var enhancesEdges = false { didSet { scheduleTuning() } }
    var backgroundTransparency: Double = 0 { didSet { scheduleTuning() } }
    private var pending = false
    private var entries: [ObjectIdentifier: Entry] = [:]
    private(set) var tuningAvailable = false

    private final class Entry {
        var original: NSObject
        var applied: NSObject?
        var observation: NSKeyValueObservation?
        init(original: NSObject) { self.original = original }
    }

    /// 布局之后检查实际滤镜；不在 SwiftUI 内部更新过程中直接修改图层。
    override func layout() {
        super.layout()
        scheduleTuning()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleTuning()
    }

    /// 合并系统重建与滑块更新，避免计时轮询及重入。
    private func scheduleTuning() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.applyBackgroundTuning()
        }
    }

    /// 仅接受探测成功的滤镜；透光率 0 恢复背景原值，高光独立设置，未知系统保持原样。
    func applyBackgroundTuning() {
        guard #available(macOS 27.0, *), ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let layer else { return }
        let amount = SystemDisplay.reduceTransparency ? 0 : min(1, max(0, backgroundTransparency))
        var found = Set<ObjectIdentifier>()
        tuningAvailable = false
        func visit(_ layer: CALayer) {
            defer { for child in layer.sublayers ?? [] { visit(child) } }
            guard let filters = layer.filters else { return }
            for (index, value) in filters.enumerated() {
                guard let filter = value as? NSObject, String(describing: filter) == "glassBackground",
                      filter.responds(to: NSSelectorFromString("inputKeys")),
                      let keys = filter.value(forKey: "inputKeys") as? [String],
                      keys.contains("inputBlurRadius"), keys.contains("inputFaceOpacity"),
                      filter is NSCopying else { continue }
                let id = ObjectIdentifier(layer)
                found.insert(id)
                let entry: Entry
                if let existing = entries[id] {
                    entry = existing
                    if filter !== entry.applied && filter !== entry.original { entry.original = filter }
                } else {
                    entry = Entry(original: filter)
                    entries[id] = entry
                    entry.observation = layer.observe(\.filters) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.scheduleTuning() }
                    }
                }
                guard let blur = entry.original.value(forKey: "inputBlurRadius") as? NSNumber,
                      let face = entry.original.value(forKey: "inputFaceOpacity") as? NSNumber else { continue }
                tuningAvailable = true
                let radius = blur.doubleValue * (1 - amount) // 只减弱散射，不淡出光学层。
                let opacity = face.doubleValue * (1 - amount) // 保留系统颜色矩阵及其动态适配。
                var edgeValues: [String: Double] = [:]
                for (key, requested) in [("inputKeyFillHighlightAmount", min(2, max(0, highlightStrength))),
                                         ("inputKeyFillHighlightHeight", min(3, max(0.25, highlightWidth)))] {
                    if keys.contains(key), let original = entry.original.value(forKey: key) as? NSNumber {
                        edgeValues[key] = enhancesEdges ? requested : original.doubleValue
                    }
                }
                let edgesMatch = edgeValues.allSatisfy { key, value in
                    (filter.value(forKey: key) as? NSNumber)?.doubleValue == value
                }
                if edgesMatch, (filter.value(forKey: "inputBlurRadius") as? NSNumber)?.doubleValue == radius,
                   (filter.value(forKey: "inputFaceOpacity") as? NSNumber)?.doubleValue == opacity { continue }
                guard let copy = (entry.original as? NSCopying)?.copy(with: nil) as? NSObject else { continue }
                copy.setValue(radius, forKey: "inputBlurRadius")
                copy.setValue(opacity, forKey: "inputFaceOpacity")
                for (key, value) in edgeValues { copy.setValue(value, forKey: key) }
                entry.applied = copy
                var updated = filters
                updated[index] = copy
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.filters = updated
                CATransaction.commit()
            }
        }
        visit(layer)
        entries = entries.filter { found.contains($0.key) } // 原生图层替换后释放旧观察者。
    }
}
