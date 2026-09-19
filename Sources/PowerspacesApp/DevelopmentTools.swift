// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

enum DevelopmentTools {
    static let isAppearancePreview = CommandLine.arguments.contains("--preview-appearance")
    static let isGlassPreview = CommandLine.arguments.contains("--preview-glass")
    static let isPreview = isGlassPreview || isAppearancePreview || CommandLine.arguments.contains("--preview-settings") || CommandLine.arguments.contains("--check-dock-layout")
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

    /// 用临时配置测量四边停靠的真实窗口坐标，验证缩放不会移动圆点外侧基线。
    @MainActor static func checkDockLayout() -> Bool {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return false }
        defer { try? FileManager.default.removeItem(at: previewDirectory) }
        let prefs = Preferences.shared
        prefs.hoverEnabled = true
        prefs.hoverScale = 1.5
        prefs.hoverAnimation = 0
        prefs.runningDotGap = 7
        prefs.showWindowLabels = false
        var failures = 0
        func buttons(_ view: NSView) -> [DockButton] {
            if let button = view as? DockButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        for labeled in [false, true] {
        prefs.showWindowLabels = labeled
        prefs.windowLabelScope = .all
        for position in [BarPosition.bottom, .top, .left, .right] {
            prefs.barPosition = position
            let panel = DockPanel(screen: screen)
            panel.update(apps: [
                DockApp(bundleID: "one", name: "One", pid: 1, windowCount: 1, isPinnedHere: true),
                DockApp(bundleID: "two", name: "Two", pid: 2, windowCount: 1),
            ], animateChanges: false)
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let items = buttons(panel.contentView!)
            func centers() -> [NSPoint] {
                items.compactMap { button in
                    guard let dot = button.subviews.first(where: { $0 is AdaptiveDockMark }) else { return nil }
                    let frame = panel.convertToScreen(button.convert(dot.frame, to: nil))
                    return NSPoint(x: frame.midX, y: frame.midY)
                }
            }
            for button in items {
                button.setWindowBadge(count: 3)
                button.setNotificationBadge("99+")
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            let before = centers()
            let widths = items.map { $0.widthConstraint?.constant ?? 0 }
            let restingFrames = items.map { panel.convertToScreen($0.convert($0.bounds, to: nil)) }
            panel.previewMagnification()
            panel.contentView?.layoutSubtreeIfNeeded()
            let after = centers()
            let badgesOK = items.allSatisfy { button in
                let badges = button.subviews.compactMap { $0 as? DockBadgeView }
                guard badges.count == 2, let red = badges.first(where: { $0.notification }),
                      let count = badges.first(where: { !$0.notification }) else { return false }
                let inWindow = red.convert(red.bounds, to: nil)
                return !red.frame.intersects(count.frame) && red.hitTest(.zero) == nil
                    && red.text == "99+" && panel.contentView!.bounds.contains(inWindow)
            }
            if !badgesOK { failures += 1; print("FAIL badge geometry \(position)") }
            let fixed = zip(before, after).allSatisfy {
                abs(position.isVertical ? $0.x - $1.x : $0.y - $1.y) < 1
            }
            let grew = zip(items, widths).contains { ($0.widthConstraint?.constant ?? 0) > $1 + 1 }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let tree = descendants(panel.contentView!)
            let divider = tree.compactMap { $0 as? DockDividerView }.first
            let glass = tree.compactMap { $0 as? GlassSurfaceView }.first
            let centered: Bool
            if let divider, let glass {
                let mark = divider.mark.convert(divider.mark.bounds, to: nil)
                let surface = glass.convert(glass.bounds, to: nil)
                let actualThickness = position.isVertical ? mark.height : mark.width
                centered = abs(actualThickness - prefs.dockDividerThickness) < 0.01 && abs(position.isVertical ? mark.midX - surface.midX : mark.midY - surface.midY) < 0.5
            } else { centered = false }
            let focusFrame = restingFrames[items.count / 2]
            let warp = DockMagnification(base: CGFloat(prefs.iconSize),
                maximum: CGFloat(prefs.iconSize * prefs.hoverScale), progress: 1,
                focus: position.isVertical ? focusFrame.midY : focusFrame.midX)
            let geometryOK = zip(items, restingFrames).allSatisfy { button, resting in
                let current = panel.convertToScreen(button.convert(button.bounds, to: nil))
                let actualLow = position.isVertical ? current.minY : current.minX
                let actualHigh = position.isVertical ? current.maxY : current.maxX
                let expectedLow = warp.map(position.isVertical ? resting.minY : resting.minX)
                let expectedHigh = warp.map(position.isVertical ? resting.maxY : resting.maxX)
                return abs(actualLow - expectedLow) < 1 && abs(actualHigh - expectedHigh) < 1
            }
            panel.resetMagnification()
            let restored = zip(items, widths).allSatisfy { abs(($0.widthConstraint?.constant ?? 0) - $1) <= 1 } // AppKit 对标题宽度做点对齐。
            let unclipped = glass?.clipsToBounds == false && glass?.layer?.masksToBounds == false
            let pass = before.count == 2 && after.count == 2 && fixed && grew && centered && geometryOK && restored && unclipped
            if !pass { failures += 1 }
            print("Dock anchors \(position): \(pass ? "PASS" : "FAIL") \(before) -> \(after)")
            prefs.hoverAnimation = 0.12
            if !panel.checkMagnificationInteractions() { failures += 1 }
            prefs.hoverAnimation = 0
            panel.close()
        }
        }
        print("Dock layout: \(failures) failures")
        return failures == 0
    }

    /// 独立进程内核对私有桥接与非焦点渲染，未安装前即可发现 ABI 或材质失效。
    @MainActor static func checkNativeDockMaterial() -> Bool {
        _ = NSApplication.shared
        guard let recipe = NativeDockRecipe.shared else {
            print("Native Dock unavailable: \(NativeDockRecipe.unavailableReason)")
            return false
        }
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 200, width: 480, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        let host = NativeDockMaterialView(recipe: recipe)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        var failed = false
        host.onFailure = { failed = true }
        for (width, appearance) in [(480.0, NSAppearance.Name.aqua), (580.0, .darkAqua)] {
            panel.setContentSize(NSSize(width: width, height: 76))
            host.update(radius: 25, tint: nil, appearance: NSAppearance(named: appearance),
                        transparency: 0.65)
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            let active = NativeDockMaterialView.hasActiveHighlight(host.layer)
            print("Native Dock: appActive=\(NSApp.isActive) key=\(panel.isKeyWindow) width=\(width) highlight=\(active) tuning=\(host.tuning.tuningAvailable)")
            if !active || !host.tuning.tuningAvailable || panel.isKeyWindow { failed = true }
        }
        // 在实际包装层中验证前景命中、公开回退、浓度与原生高光参数不变。
        let surface = GlassSurfaceView(frame: NSRect(x: 0, y: 0, width: 480, height: 76))
        surface.dockMode = true
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 40, height: 30))
        surface.glassContent.addSubview(button)
        panel.contentView = surface
        func effects(_ layer: CALayer?) -> [NSObject] {
            guard let layer else { return [] }
            let own = layer.responds(to: NSSelectorFromString("effect"))
                ? (layer.value(forKey: "effect") as? NSObject).map { [$0] } ?? [] : []
            return own + (layer.sublayers ?? []).flatMap(effects)
        }
        func backdrop(_ layer: CALayer?) -> NSObject? {
            guard let layer else { return nil }
            if let filter = layer.filters?.compactMap({ $0 as? NSObject }).first(where: {
                String(describing: $0) == "glassBackground"
            }) { return filter }
            return (layer.sublayers ?? []).compactMap(backdrop).first
        }
        var initialBlur: Double?
        for amount in [0.0, 0.4, 0.8, 1.0, 0.0] {
            surface.backgroundTransparency = amount
            surface.material = amount == 0.8 ? .menu : .hudWindow
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let native = surface.subviews.compactMap { $0 as? NativeDockMaterialView }.first
            let blur = backdrop(native?.layer)?.value(forKey: "inputBlurRadius") as? NSNumber
            if initialBlur == nil { initialBlur = blur?.doubleValue }
            let densityOK = initialBlur.map { baseline in
                blur.map { abs($0.doubleValue - baseline * (1 - amount)) < 0.0001 } ?? false
            } ?? false
            let highlight = effects(native?.layer).first { String(describing: type(of: $0)) == "CASDFKeyFillHighlightEffect" }
            let amountOK = (highlight?.value(forKey: "keyAmount") as? NSNumber)?.doubleValue == 0.5
            let widthOK = (highlight?.value(forKey: "keyHeight") as? NSNumber)?.doubleValue == 1
            let hit = surface.hitTest(surface.convert(NSPoint(x: 5, y: 5), from: button)) === button
            let success = surface.glassContent.frame == surface.bounds && surface.usesNativeDockMaterial && densityOK && amountOK && widthOK && hit
                && NativeDockMaterialView.hasActiveHighlight(native?.layer) && !panel.isKeyWindow
            print("Integrated Dock: transparency=\(amount) pass=\(success)")
            if !success { failed = true }
        }
        surface.allowsNativeDockMaterial = false
        surface.layoutSubtreeIfNeeded()
        let fallbackOK = !surface.usesNativeDockMaterial && !button.isHiddenOrHasHiddenAncestor
            && surface.hitTest(surface.convert(NSPoint(x: 5, y: 5), from: button)) === button
        print("Public fallback: \(fallbackOK)")
        if !fallbackOK { failed = true }
        surface.allowsNativeDockMaterial = true
        surface.solid = true
        if surface.usesNativeDockMaterial || button.isHiddenOrHasHiddenAncestor { failed = true }
        surface.solid = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if !surface.usesNativeDockMaterial || panel.isKeyWindow { failed = true }
        print("Native Dock check: \(failed ? "FAIL" : "PASS")")
        return !failed
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
        prefs.runningDotGap = 9
        prefs.dockDividerEnabled = false
        prefs.dockDividerGap = 13
        check(prefs.dockDividerLength == 0.65, "default divider length")
        prefs.dockDividerLength = 0.85
        check(prefs.dockDividerThickness == 1, "default divider thickness")
        prefs.dockDividerThickness = 2.5
        let marks = Preferences(url: url)
        check(marks.runningDotGap == 9 && !marks.dockDividerEnabled && marks.dockDividerGap == 13 && marks.dockDividerLength == 0.85 && marks.dockDividerThickness == 2.5,
              "persisted dock marks")
        prefs.runningDotGap = -1
        prefs.dockDividerGap = 99
        prefs.dockDividerThickness = 99
        check(prefs.dockDividerThickness == 4, "maximum divider thickness")
        prefs.dockDividerThickness = -1
        check(prefs.dockDividerThickness == 0.5, "minimum divider thickness")
        prefs.dockDividerLength = 3
        check(prefs.dockDividerLength == 1, "bounded divider length")
        check(prefs.runningDotGap == 0 && prefs.dockDividerGap == 24, "bounded dock gaps")
        prefs.glassTransparency = 0.42
        prefs.dockOpacity = 0.37
        let reloaded = Preferences(url: url)
        check(reloaded.dockOpacity == 0.37, "persisted opacity")
        check(reloaded.glassTransparency == 0.42, "persisted glass transparency")
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
        // 实际合成器回调测试：整段文字在黑白背景间统一切换，混合背景也不出现像素级颜色。
        let contrastWindow = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let background = NSView(frame: contrastWindow.contentLayoutRect)
        background.wantsLayer = true
        let adaptive = AdaptiveDockLabel(text: "Whole title 整体", font: .systemFont(ofSize: 18))
        adaptive.frame = NSRect(x: 20, y: 25, width: 240, height: 30)
        background.addSubview(adaptive)
        let line = AdaptiveDockMark(circular: false)
        line.frame = NSRect(x: 285, y: 15, width: 1.5, height: 60)
        background.addSubview(line)
        contrastWindow.contentView = background
        contrastWindow.orderFrontRegardless()
        for (color, expected) in [(NSColor.black, NSColor.white), (.white, .black), (.black, .white)] {
            background.layer?.backgroundColor = color.cgColor
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            check(adaptive.textColor == expected && line.textColor == expected, "whole title and divider contrast on \(color)")
        }
        contrastWindow.close()
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
        DockApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 1, windowCount: 1, isPinnedHere: true),
        DockApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 1, windowCount: 1,
                title: "中文与 English 标题布局预览"),
    ]

    /// 外观预览使用静态图标，不连接真实窗口策略或桌面管理。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DevelopmentTools.isAppearancePreview, let screen = NSScreen.main else { return }
        if CommandLine.arguments.contains("--dock-only") {
            Preferences.shared.showWindowLabels = !CommandLine.arguments.contains("--icons-only")
            Preferences.shared.windowLabelScope = .all
            Preferences.shared.hoverScale = 1.5
        }
        let panel = DockPanel(screen: screen)
        dock = panel
        panel.update(apps: sampleApps, animateChanges: false)
        if CommandLine.arguments.contains("--badges") {
            func decorate(_ view: NSView) {
                if let button = view as? DockButton {
                    button.setNotificationBadge(button.app?.name == "Finder" ? "99+" : "工作")
                    button.setWindowBadge(count: 3)
                }
                view.subviews.forEach(decorate)
            }
            if let content = panel.contentView { decorate(content) }
        }
        panel.show()
        if CommandLine.arguments.contains("--magnified") {
            DispatchQueue.main.async { panel.previewMagnification() }
        }
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
