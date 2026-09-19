// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

enum DevelopmentTools {
    static let isAppearancePreview = CommandLine.arguments.contains("--preview-appearance")
    static let isGlassPreview = CommandLine.arguments.contains("--preview-glass")
    static let isPreview = isGlassPreview || isAppearancePreview || CommandLine.arguments.contains("--preview-settings")
    static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("powerspaces-preview-\(UUID().uuidString)")

    /// 验证菜单退出事件异步执行、重复事件合并；不退出实际运行的应用。
    @MainActor static func checkQuitAction() -> Bool {
        _ = NSApplication.shared
        var calls = 0
        let actions = ApplicationActions(terminate: { calls += 1 })
        let dock = actions.quitMenuItem()
        let status = actions.quitMenuItem(keyEquivalent: "q")
        guard let dockAction = dock.action, let statusAction = status.action else { return false }
        let dispatched = NSApp.sendAction(dockAction, to: dock.target, from: dock)
        let second = NSApp.sendAction(statusAction, to: status.target, from: status)
        guard dispatched, second, calls == 0 else { print("FAIL: quit must be deferred"); return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard calls == 1 else { print("FAIL: duplicate quit actions"); return false }
        _ = NSApp.sendAction(statusAction, to: status.target, from: status)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard calls == 2 else { print("FAIL: status quit action"); return false }
        print("Quit action: 0 failures")
        return true
    }

    /// 验证外观配置的边界、持久化与旧材质迁移；只使用临时文件。
    @MainActor static func checkAppearance() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerspaces-appearance-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures += 1; print("FAIL: \(label)") }
        }
        let prefs = Preferences(url: url)
        check(prefs.dockOpacity == 1, "default opacity")
        check(prefs.glassHighlightStrength == 1 && prefs.glassHighlightWidth == 1, "default highlights")
        prefs.glassHighlightStrength = 1.5
        prefs.glassHighlightWidth = 2.25
        prefs.glassTransparency = 0.42
        prefs.dockOpacity = 0.37
        let reloaded = Preferences(url: url)
        check(reloaded.dockOpacity == 0.37, "persisted opacity")
        check(reloaded.glassTransparency == 0.42, "persisted glass transparency")
        check(reloaded.glassHighlightStrength == 1.5 && reloaded.glassHighlightWidth == 2.25, "persisted highlights")
        prefs.glassHighlightStrength = -1
        prefs.glassHighlightWidth = 9
        check(prefs.glassHighlightStrength == 0 && prefs.glassHighlightWidth == 3, "clamped highlights")
        prefs.glassTransparency = 2
        check(prefs.glassTransparency == 1, "clamped glass transparency")
        prefs.dockOpacity = -1
        check(prefs.dockOpacity == 0, "clamped low opacity")
        prefs.dockOpacity = 2
        check(prefs.dockOpacity == 1, "clamped high opacity")
        do {
            try Data("{\"barMaterial\":\"solid\"}".utf8).write(to: url)
            let legacy = Preferences(url: url)
            check(legacy.dockBackground == .solid, "legacy solid")
            legacy.glassTone = .darker
            check(legacy.dockBackground == .solid && legacy.glassTone == .darker, "independent tone")
            legacy.dockBackground = .glass
            check(legacy.glassTone == .darker, "independent material")
            legacy.dockTintEnabled = true
            legacy.dockTintColor = .red
            check(legacy.glassTone == .darker, "tint preserves tone")
            let saved = Preferences(url: url)
            check(saved.dockBackground == .glass && saved.glassTone == .darker, "persisted appearance")
        } catch { check(false, "legacy fixture: \(error)") }
        let button = DockButton(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        button.image?.size = NSSize(width: 40, height: 40)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        let titleFont = NSFont.systemFont(ofSize: 16)
        button.attributedTitle = NSAttributedString(string: "Title", attributes: [.font: titleFont, .foregroundColor: NSColor.clear])
        button.setAdaptiveTitle("Title", font: titleFont)
        button.layoutSubtreeIfNeeded()
        if let label = button.subviews.compactMap({ $0 as? AdaptiveDockLabel }).first {
            check(label.frame.width > 0 && label.frame.height > 0, "adaptive title has layout")
            check(label.hitTest(.zero) == nil, "adaptive title preserves button events")
        } else { check(false, "adaptive title installed") }
        // 回归：玻璃／纯色反复切换后，前景仍可见且不随浓度淡出。
        _ = NSApplication.shared
        let surface = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 64))
        surface.dockMode = true
        let foreground = NSView(frame: NSRect(x: 10, y: 10, width: 30, height: 30))
        surface.glassContent.addSubview(foreground)
        surface.opacity = 0.2
        for solid in [true, false, true, false] {
            surface.solid = solid
            surface.layoutSubtreeIfNeeded()
            check(!foreground.isHiddenOrHasHiddenAncestor, "visible foreground after material switch")
            check(surface.alphaValue == 1, "foreground retains full opacity")
            let point = surface.convert(NSPoint(x: 15, y: 15), from: foreground)
            check(surface.hitTest(point) === foreground, "foreground hit testing")
            let outside = surface.convert(NSPoint(x: 40, y: 15), from: foreground)
            check(surface.hitTest(outside) == nil, "empty space does not intercept menus")
        }
        surface.dockMode = false
        surface.settingsMode = true
        for solid in [true, false] {
            surface.solid = solid // 与降低透明度共用不透明回退路径。
            surface.layoutSubtreeIfNeeded()
            check(!foreground.isHiddenOrHasHiddenAncestor, "settings foreground survives opaque fallback")
            check(surface.alphaValue == 1, "settings foreground retains full opacity")
            let point = surface.convert(NSPoint(x: 15, y: 15), from: foreground)
            check(surface.hitTest(point) === foreground, "settings content receives clicks")
        }
        if #available(macOS 27.0, *), ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
           !SystemDisplay.reduceTransparency {
            let glass = TunableGlassEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 64))
            glass.style = .clear
            let window = NSWindow(contentRect: glass.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = glass
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            func backdrop(_ layer: CALayer?) -> (CALayer, NSObject)? {
                guard let layer else { return nil }
                if let filter = layer.filters?.compactMap({ $0 as? NSObject })
                    .first(where: { String(describing: $0) == "glassBackground" }) { return (layer, filter) }
                return layer.sublayers?.compactMap { backdrop($0) }.first
            }
            if let (layer, baseline) = backdrop(glass.layer) {
                let keys = ["inputBlurRadius", "inputFaceOpacity", "inputInnerRefractionAmount",
                            "inputKeyFillHighlightAmount", "inputRefractionOpacity"]
                let original = keys.map { baseline.value(forKey: $0) as? NSNumber }
                for amount in [0.85, 0.25, 1, 0] {
                    glass.backgroundTransparency = amount
                    glass.applyBackgroundTuning()
                    let current = backdrop(glass.layer)!.1
                    let values = keys.map { current.value(forKey: $0) as? NSNumber }
                    check(glass.tuningAvailable, "native glass tuning available")
                    for index in 0..<2 {
                        let expected = original[index]!.doubleValue * (1 - amount)
                        check(abs(values[index]!.doubleValue - expected) < 0.000001, "glass density follows slider")
                    }
                    check(Array(values[2...]) == Array(original[2...]), "refraction and highlights unchanged")
                    check(glass.alphaValue == 1, "glass layer retains full alpha")
                }
                glass.enhancesEdges = true
                glass.applyBackgroundTuning()
                let edgeFilter = backdrop(glass.layer)!.1
                check((edgeFilter.value(forKey: "inputKeyFillHighlightAmount") as? NSNumber)?.doubleValue == 1,
                      "enhanced native edge highlight")
                glass.highlightStrength = 0
                glass.highlightWidth = 2.25
                glass.applyBackgroundTuning()
                let adjusted = backdrop(glass.layer)!.1
                check((adjusted.value(forKey: "inputKeyFillHighlightAmount") as? NSNumber)?.doubleValue == 0,
                      "highlight off")
                check((adjusted.value(forKey: "inputKeyFillHighlightHeight") as? NSNumber)?.doubleValue == 2.25,
                      "adjustable highlight width")
                glass.enhancesEdges = false
                glass.backgroundTransparency = 0.65
                glass.applyBackgroundTuning()
                layer.filters = [baseline] // 模拟系统因外观变化重建滤镜。
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let refreshed = backdrop(glass.layer)!.1.value(forKey: "inputBlurRadius") as! NSNumber
                check(abs(refreshed.doubleValue - original[0]!.doubleValue * 0.35) < 0.000001,
                      "glass tuning survives native filter replacement")
            } else { check(false, "native glass filter not found") }
        }
        print("Appearance: \(failures) failures")
        return failures == 0
    }

    /// 无界面验证双语资源、动态参数和语言持久化；返回是否全部通过，配置只写临时目录。
    @MainActor static func checkLocalization() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerspaces-l10n-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        var tables: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            guard let path = L10n.localizationPath(for: language),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
                  let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
            else { print("FAIL: missing resources for \(language.rawValue)"); return false }
            tables[language] = table
        }
        let english = tables[.english] ?? [:]
        let chinese = tables[.simplifiedChinese] ?? [:]
        check(Set(english.keys) == Set(chinese.keys), "matching language keys")
        check(!english.isEmpty, "nonempty catalog")
        for (key, translation) in chinese {
            check(!translation.isEmpty, "empty translation: \(key)")
            check(key.components(separatedBy: "%@").count == translation.components(separatedBy: "%@").count,
                  "format arguments: \(key)")
            check(L10n.string(key, language: .simplifiedChinese) == translation, "bundle lookup: \(key)")
        }
        let url = directory.appendingPathComponent("preferences.json")
        let preferences = Preferences(url: url)
        let previousIconSize = preferences.iconSize
        preferences.language = .english
        check(L10n.string("App language") == "App language", "English selection")
        preferences.language = .simplifiedChinese
        check(L10n.string("App language") == "界面语言", "Chinese selection")
        check(L10n.format("Desktop %@", "2") == "桌面 2", "dynamic desktop number")
        check(L10n.string("unknown.translation.key") == "unknown.translation.key", "missing-key fallback")
        check(Preferences(url: url).language == .simplifiedChinese, "persisted selection")
        check(preferences.iconSize == previousIconSize, "language preserves appearance")
        preferences.language = .english
        check(Preferences(url: url).language == .english, "switch back to English")
        let invalid = Data("{\"language\":\"unsupported\",\"iconSizeNumber\":64}".utf8)
        do { try invalid.write(to: url) } catch { check(false, "write invalid-language fixture") }
        let recovered = Preferences(url: url)
        check(recovered.language == AppLanguage.systemDefault, "unknown-language fallback")
        check(recovered.iconSize == 64, "preserve legacy configuration")
        print("Localization: \(english.count) keys, \(failures) failures")
        return failures == 0
    }
}

@MainActor
final class SettingsPreviewDelegate: NSObject, NSApplicationDelegate {
    private var dock: DockPanel?
    private let sampleApps = [
        DockApp(bundleID: "com.apple.finder", name: "Finder", pid: nil, windowCount: 0, isPinnedHere: true),
        DockApp(bundleID: "com.apple.Safari", name: "Safari", pid: nil, windowCount: 0, isPinnedHere: true),
        DockApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: nil, windowCount: 0, isPinnedHere: true),
    ]

    /// 外观预览使用静态图标，不连接真实窗口策略或桌面管理。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DevelopmentTools.isAppearancePreview, let screen = NSScreen.main else { return }
        let panel = DockPanel(screen: screen)
        dock = panel
        panel.update(apps: sampleApps, animateChanges: false)
        panel.show()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDock),
                                               name: .preferencesDidChange, object: nil)
    }

    /// 临时设置变化后重绘示例程序坞，供停靠方向和配色检查。
    @objc private func refreshDock() {
        dock?.applyAppearance()
        dock?.update(apps: sampleApps, animateChanges: false)
        dock?.reposition()
    }

    /// 预览窗口关闭后退出进程，避免留下没有窗口的开发实例。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 清理本次预览产生的临时设置，正式用户配置从未被使用。
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: DevelopmentTools.previewDirectory)
    }
}
