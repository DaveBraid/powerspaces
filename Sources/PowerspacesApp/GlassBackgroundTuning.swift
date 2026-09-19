// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 隔离 macOS 27 私有玻璃参数；只调整背景，保持原生高光、前景及折射。
@MainActor
final class GlassLayerTuning {
    weak var layer: CALayer?
    private var treeObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// 更换渲染树时释放旧观察者；同一棵树保留原值，避免把已调节的值当成新基准。
    func attach(to layer: CALayer?) {
        guard self.layer !== layer else { return }
        entries.removeAll()
        treeObservations.removeAll()
        self.layer = layer
    }
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

    /// 仅接受探测成功的滤镜；透光率 0 恢复背景原值，高光保持原值，未知系统保持原样。
    func applyBackgroundTuning() {
        guard #available(macOS 27.0, *), ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let layer else { return }
        let amount = SystemDisplay.reduceTransparency ? 0 : min(1, max(0, backgroundTransparency))
        var found = Set<ObjectIdentifier>()
        var nodes = Set<ObjectIdentifier>()
        tuningAvailable = false
        func visit(_ layer: CALayer) {
            defer { for child in layer.sublayers ?? [] { visit(child) } }
            let node = ObjectIdentifier(layer)
            nodes.insert(node)
            if treeObservations[node] == nil {
                treeObservations[node] = layer.observe(\.sublayers) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.scheduleTuning() }
                }
            }
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
                if (filter.value(forKey: "inputBlurRadius") as? NSNumber)?.doubleValue == radius,
                   (filter.value(forKey: "inputFaceOpacity") as? NSNumber)?.doubleValue == opacity { continue }
                guard let copy = (entry.original as? NSCopying)?.copy(with: nil) as? NSObject else { continue }
                copy.setValue(radius, forKey: "inputBlurRadius")
                copy.setValue(opacity, forKey: "inputFaceOpacity")
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
        treeObservations = treeObservations.filter { nodes.contains($0.key) }
    }

}

/// 公开 NSGlassEffectView 回退复用同一背景调节器，保留 macOS 26 及旧配置行为。
@available(macOS 26.0, *)
@MainActor
final class TunableGlassEffectView: NSGlassEffectView {
    private let tuning = GlassLayerTuning()
    var backgroundTransparency: Double { get { tuning.backgroundTransparency } set { tuning.backgroundTransparency = newValue } }
    var tuningAvailable: Bool { tuning.tuningAvailable }
    override func layout() { super.layout(); tuning.attach(to: layer); tuning.backgroundTransparency = backgroundTransparency }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tuning.attach(to: layer); tuning.backgroundTransparency = backgroundTransparency }
    func applyBackgroundTuning() { tuning.attach(to: layer); tuning.applyBackgroundTuning() }
}
