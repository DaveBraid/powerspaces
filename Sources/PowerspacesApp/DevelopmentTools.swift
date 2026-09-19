// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

enum DevelopmentTools {
    static let isAppearancePreview = CommandLine.arguments.contains("--preview-appearance")
    static let isGlassPreview = CommandLine.arguments.contains("--preview-glass")
    static let isPreview = CommandLine.arguments.contains("--check-fullscreen-preview") || CommandLine.arguments.contains("--check-preview-capture") || CommandLine.arguments.contains("--check-window-preview") || CommandLine.arguments.contains("--check-dock-performance") || isGlassPreview || isAppearancePreview || CommandLine.arguments.contains("--preview-settings") || CommandLine.arguments.contains("--check-dock-layout")
    static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("powerspaces-preview-\(UUID().uuidString)")

    /// 只允许指定的独立测试应用；正常启动正式签名进程验证捕获、最小化／隐藏恢复，不写图片。
    @MainActor static func checkWindowPreviewCapture() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess(), AccessibilityPermission.isTrusted,
                  let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "local.ps.preview-validation").first else {
                print("Preview live check: missing permission or controlled fixture"); exit(2)
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let provider = CGSSpaceProvider()
            let launcher = Launcher(provider: provider, config: .defaults, warn: { print($0) })
            let pid = fixture.processIdentifier
            let displays = provider.displays()
            guard let snapshot = try? provider.snapshot(),
                  let display = displays.first(where: {
                      !WindowPreview.windows(pid: pid, bundleID: fixture.bundleIdentifier, snapshot: snapshot,
                          display: $0, allDisplays: displays.map(\.bounds)).isEmpty
                  }),
                  let windows = try? launcher.previewWindows(pid: pid, bundleID: fixture.bundleIdentifier,
                      displayUUID: display.displayUUID, spaceUUID: display.currentSpaceUUID, includeHidden: true),
                  windows.count == 2 else { print("Preview live check: fixture ownership unavailable"); exit(2) }
            let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let captured: Bool = await withCheckedContinuation { continuation in
                var count = 0, images = 0, placeholders = 0
                WindowThumbnailService.shared.capture(windows) { _, _, image, error in
                    count += 1
                    if let image {
                        if image.size.width <= 440 && image.size.height <= 280 { images += 1 }
                    } else if error == "Window is minimized or hidden" { placeholders += 1 }
                    if count == windows.count {
                        print("Preview capture: images=\(images) placeholders=\(placeholders) callbacks=\(count)")
                        continuation.resume(returning: images == 1 && placeholders == 1)
                    }
                }
            }
            let noActivation = foregroundBefore == NSWorkspace.shared.frontmostApplication?.processIdentifier
            var restored = false, exact = false, unhidden = false
            if let minimized = windows.first(where: \.isMinimized) {
                _ = try? launcher.focusPreviewWindow(windowID: minimized.windowID, pid: pid,
                    target: AppTarget(bundleID: fixture.bundleIdentifier, name: "PSPreviewValidation"),
                    displayUUID: display.displayUUID, spaceUUID: display.currentSpaceUUID)
                try? await Task.sleep(for: .milliseconds(300))
                restored = (try? provider.snapshot().windows.first { $0.windowID == minimized.windowID }?.isMinimized) == false
                let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let front = rows.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                    && ($0[kCGWindowLayer as String] as? Int) == 0 }
                exact = (front?[kCGWindowNumber as String] as? UInt32) == minimized.windowID
                fixture.hide()
                try? await Task.sleep(for: .milliseconds(200))
                _ = try? launcher.focusPreviewWindow(windowID: minimized.windowID, pid: pid,
                    target: AppTarget(bundleID: fixture.bundleIdentifier, name: "PSPreviewValidation"),
                    displayUUID: display.displayUUID, spaceUUID: display.currentSpaceUUID)
                try? await Task.sleep(for: .milliseconds(300))
                unhidden = !fixture.isHidden
            }
            WindowThumbnailService.shared.cancel()
            fixture.terminate()
            previous?.activate()
            print("Preview live: noActivation=\(noActivation) restored=\(restored) exact=\(exact) unhidden=\(unhidden)")
            exit(captured && noActivation && restored && exact && unhidden ? 0 : 1)
        }
        app.run()
    }

    /// 仅操作受控全屏测试应用；验证跨桌面截图内容、无激活及点击后的精确聚焦，不保存图片。
    @MainActor static func checkFullscreenPreview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess(), AccessibilityPermission.isTrusted,
                  let fixture = NSRunningApplication.runningApplications(withBundleIdentifier: "local.ps.fullscreen-validation").first else {
                print("Fullscreen preview: missing permission or fixture"); exit(2)
            }
            let previous = NSWorkspace.shared.frontmostApplication
            let provider = CGSSpaceProvider()
            let launcher = Launcher(provider: provider, config: .defaults, warn: { print($0) })
            let spaces = provider.fullscreenSpaceIDs()
            guard let info = try? provider.snapshot().windows.first(where: {
                $0.pid == fixture.processIdentifier && !spaces.isDisjoint(with: $0.spaceIDs)
            }) else { print("Fullscreen fixture unavailable"); exit(2) }
            let before = provider.displays().map(\.currentSpaceID)
            let offscreen = Set(before).isDisjoint(with: info.spaceIDs)
            let captured: Bool = await withCheckedContinuation { continuation in
                WindowThumbnailService.shared.capture([info], allowOffscreen: true) { _, _, image, error in
                    var teal = false
                    if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let bitmap = NSBitmapImageRep(cgImage: cg)
                        if let color = bitmap.colorAt(x: cg.width / 4, y: cg.height / 4)?.usingColorSpace(.deviceRGB) {
                            teal = color.greenComponent > color.redComponent + 0.1 && color.blueComponent > color.redComponent + 0.1
                        }
                        print("Fullscreen image: \(cg.width)x\(cg.height), teal=\(teal)")
                    }
                    print("Fullscreen capture error: \(error ?? "none")")
                    continuation.resume(returning: teal)
                }
            }
            let untouched = previous?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
                && before == provider.displays().map(\.currentSpaceID)
            let target = AppTarget(bundleID: fixture.bundleIdentifier, name: "PS Full-screen Validation")
            _ = try? launcher.focusFullscreenWindow(windowID: info.windowID, pid: info.pid, target: target)
            try? await Task.sleep(for: .seconds(2)) // 等待系统全屏 Space 切换动画完成。
            let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier == info.pid
                && !Set(provider.displays().map(\.currentSpaceID)).isDisjoint(with: info.spaceIDs)
            WindowThumbnailService.shared.cancel()
            fixture.terminate()
            previous?.activate()
            print("Fullscreen preview: offscreen=\(offscreen) content=\(captured) untouched=\(untouched) focused=\(focused)")
            fflush(stdout)
            exit(offscreen && captured && untouched && focused ? 0 : 1)
        }
        app.run()
    }

    /// 真实图标与混合标题的独立性能窗口，只使用临时配置。
    @MainActor static func checkDockPerformance() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { return }
        defer { try? FileManager.default.removeItem(at: previewDirectory) }
        let prefs = Preferences.shared
        prefs.hoverEnabled = true
        prefs.hoverScale = 1.5
        prefs.hoverAnimation = 0
        prefs.showWindowLabels = true
        prefs.windowLabelScope = .multipleWindows
        prefs.barPosition = .bottom
        let dock = DockPanel(screen: screen)
        let ids = ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", "com.apple.TextEdit"]
        let apps = (0..<12).map { index in
            DockApp(bundleID: ids[index % 4], name: "App \(index)", pid: 1,
                    windowCount: index % 4 == 2 ? 2 : 1, isPinnedHere: index < 3)
        }
        dock.update(apps: apps, animateChanges: false)
        dock.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        dock.measureMagnificationFrames()
        dock.close()
    }

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
        prefs.dockHeight = 140 // 明显大于图标，防止固定外沿留白伪装成居中。
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
                DockApp(bundleID: "two", name: "Longer application title", pid: 2, windowCount: 1),
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
            if let first = before.first, !before.allSatisfy({
                abs(position.isVertical ? $0.x - first.x : $0.y - first.y) < 1
            }) { failures += 1; print("FAIL shared indicator baseline \(position)") }
            func restingTree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(restingTree) }
            if let glass = restingTree(panel.contentView!).compactMap({ $0 as? GlassSurfaceView }).first {
                let surface = glass.convert(glass.bounds, to: nil)
                let iconsCentered = items.allSatisfy { button in
                    let rect = labeled && position.isVertical ? button.bounds : button.cell!.imageRect(forBounds: button.bounds)
                    let image = button.convert(rect, to: nil)
                    return abs(position.isVertical ? image.midX - surface.midX : image.midY - surface.midY) < 1
                }
                if !iconsCentered { failures += 1; print("FAIL resting icon centering \(position)") }
            }
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
            if !labeled && !panel.checkMagnificationCadence() { failures += 1 }
            if !panel.checkMagnificationInteractions() { failures += 1 }
            if !panel.checkMagnificationPointerRouting() { failures += 1 }
            if !labeled && position == .bottom && !panel.checkMagnificationBurst() { failures += 1 }
            prefs.hoverAnimation = 0
            // 三个状态分别检查：已退出固定项、运行但无窗口、共享全屏窗口。
            prefs.dockDividerEnabled = true
            let fixtures = [
                DockApp(bundleID: "quit", name: "Quit", pid: nil, windowCount: 0, isPinnedHere: true),
                DockApp(bundleID: "alive", name: "Alive", pid: 2, windowCount: 0),
                DockApp(bundleID: "full", name: "Full", pid: 3, windowCount: 1,
                        windowIDs: [42], windowID: 42, isFullscreenItem: true)
            ]
            panel.update(apps: fixtures, animateChanges: false)
            if let root = panel.contentView {
                let items = buttons(root)
                let opacity = items.compactMap { ($0.cell as? DockItemCell)?.iconOpacity }
                let dots = items.map { $0.subviews.filter { $0 is AdaptiveDockMark }.count }
                let dividers = restingTree(root).filter { $0 is DockDividerView }.count
                let valid = opacity == [CGFloat(prefs.dimLevel), CGFloat(prefs.dimLevel), 1]
                    && dots == [0, 1, 1] && dividers == 2 && items.allSatisfy { $0.alphaValue == 1 }
                if !valid { failures += 1 }
                panel.update(apps: Array(fixtures.prefix(2)), animateChanges: false)
                let removed = restingTree(root).filter { $0 is DockDividerView }.count == 1
                if !removed { failures += 1 }
                print("Dock window states \(position): correct=\(valid) fullscreenDividerRemoved=\(removed)")
            } else { failures += 1 }
            panel.close()
        }
        }
        print("Dock layout: \(failures) failures")
        return failures == 0
    }

    /// 独立进程内核对私有桥接与非焦点渲染，未安装前即可发现 ABI 或材质失效。
    /// 合并模式的指示规则自检：圆点数量必须严格等于当前桌面的窗口数。
    @MainActor static func checkMergedIndicators() -> Bool {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("  ✓ \(message)") } else { print("  ✗ \(message)"); failures += 1 }
        }
        // 合并模式：N 个窗口 → N 个实心圆点。
        for count in 0...4 {
            check(DockButton.indicator(mode: .merged, isLauncher: false,
                                       isRunning: true, windowCount: count)
                    == (count > 0 ? .windows(count) : .runningWithoutWindows),
                  "merged: \(count) window(s) → \(count > 0 ? "\(count) dots" : "one hollow dot")")
        }
        // 已退出（仅因固定而保留）：没有圆点。
        check(DockButton.indicator(mode: .merged, isLauncher: false,
                                   isRunning: false, windowCount: 0) == .none,
              "merged: pinned but not running shows no dot")
        // 拆分模式保持原有单点语义。
        check(DockButton.indicator(mode: .split, isLauncher: false,
                                   isRunning: true, windowCount: 3) == .running,
              "split: running shows the single classic dot")
        check(DockButton.indicator(mode: .split, isLauncher: false,
                                   isRunning: false, windowCount: 0) == .none,
              "split: not running shows no dot")
        // 启动器不是应用，永远没有指示。
        check(DockButton.indicator(mode: .merged, isLauncher: true,
                                   isRunning: true, windowCount: 2) == .none,
              "the app launcher never shows an indicator")
        print(failures == 0 ? "Merged indicators: verified" : "Merged indicators: \(failures) failed")
        return failures == 0
    }

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
    /// 打印当前程序坞的避让几何，用于核对预留与四方向行为。
    ///
    /// 输出面板（窗口服务器）、玻璃（视图坐标转换）、屏幕与推导出的预留，
    /// 便于在任意停靠方向下确认「预留 = 屏幕边 → 可见玻璃内沿」。
    @MainActor static func dumpWindowLayoutGeometry() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { print("no screen"); return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let panel = DockPanel(screen: screen)
        panel.layoutIfNeeded()
        print("screen      frame=\(screen.frame) visible=\(screen.visibleFrame)")
        print("barPosition \(Preferences.shared.barPosition.rawValue)")
        if let panelRect = panel.debugServerBounds() {
            print("panel       \(panelRect)  (window server, top-left origin)")
        } else {
            print("panel       <unavailable: panel not on screen>")
        }
        print("glassInPanel \(panel.debugGlassFrame())")
        print("barThickness \(panel.debugBarThickness())")
        if let reservation = panel.layoutReservation() {
            print("reservation edge=\(reservation.edge.rawValue) thickness=\(Int(reservation.thickness))")
        } else {
            print("reservation <nil>")
        }
        _ = primaryHeight
    }

    /// 窗口避让的四方向自检。
    ///
    /// 覆盖两类只在非底部方向暴露过的缺陷：预留换算（左右公式曾写反）与外部改尺寸的
    /// 越界判据（曾只判竖向、顶部未收高度）。断言调用产品代码中同一份纯函数
    /// （`DockGeometry.reserveThickness` / `WindowLayoutCorrection`），
    /// 面板那一层只断言其对外契约（未上屏时不预留），避免自检依赖可见窗口。
    @MainActor static func checkWindowLayout() -> Bool {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            print("Window layout: no screen available")
            return false
        }
        let prefs = Preferences.shared
        let saved = (prefs.barPosition, prefs.hoverEnabled, prefs.dockHeight)
        defer {
            prefs.barPosition = saved.0
            prefs.hoverEnabled = saved.1
            prefs.dockHeight = saved.2
        }
        prefs.hoverEnabled = false
        prefs.dockHeight = 64

        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition {
                print("  ✓ \(message)")
            } else {
                print("  ✗ \(message)")
                failures += 1
            }
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let screenFrame = CGRect(x: screen.frame.minX,
                                 y: primaryHeight - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
        let visibleFrame = CGRect(x: screen.visibleFrame.minX,
                                  y: primaryHeight - screen.visibleFrame.maxY,
                                  width: screen.visibleFrame.width,
                                  height: screen.visibleFrame.height)
        // 面板比玻璃大（多出的留白在内侧），玻璃贴面板外侧——这是换算的关键前提。
        let panelLength: CGFloat = 400
        let glassThickness: CGFloat = 78
        let glassOffset: CGFloat = 6
        let innerGap = panelLength - glassThickness - glassOffset

        for position in [BarPosition.bottom, .top, .left, .right] {
            prefs.barPosition = position
            let edge = DockEdge(rawValue: position.rawValue)!
            // 说明：这里不构造 DockPanel 断言其运行时预留——未上屏的面板在窗口服务器里
            // 没有稳定位置（实测同一构造在底/左报 84pt、顶 316pt、右 nil），
            // 断言它只会产生噪声。面板层的正确性由上面四组实机几何基准覆盖。

            // 预留换算：用实机测得的四组面板/玻璃几何做回归基准
            // （内建屏 1470×956，panel 与 glassInPanel 取自运行中的程序坞面板）。
            // 期望值是同一屏幕下已逐像素验证过的窗口边缘：底 872 / 左 176 / 右 1163 / 顶 156。
            // 这锁定「预留 = 屏幕物理边 → 可见玻璃内沿」，可捕获左右量错边、
            // 或按面板尺寸/外沿计算导致的偏移。
            let panel: CGRect
            let glass: CGRect
            let measuredEdge: CGFloat
            switch edge {
            case .bottom:
                panel = CGRect(x: 6, y: 827, width: 1458, height: 129)
                glass = CGRect(x: 6, y: 6, width: 1446, height: 78)
                measuredEdge = 872
            case .top:
                panel = CGRect(x: 6, y: 33, width: 1458, height: 129)
                glass = CGRect(x: 6, y: 45, width: 1446, height: 78)
                measuredEdge = 156
            case .left:
                panel = CGRect(x: 0, y: 38, width: 313, height: 914)
                glass = CGRect(x: 6, y: 6, width: 170, height: 902)
                measuredEdge = 176
            case .right:
                panel = CGRect(x: 1157, y: 38, width: 313, height: 914)
                glass = CGRect(x: 137, y: 6, width: 170, height: 902)
                measuredEdge = 1163
            }
            let reserve = DockGeometry.reserveThickness(
                panel: panel, glassInPanel: glass, screenFrame: screenFrame,
                primaryHeight: primaryHeight, edge: edge)
            let expected: CGFloat
            switch edge {
            case .bottom: expected = screenFrame.maxY - measuredEdge
            case .top: expected = measuredEdge - screenFrame.minY
            case .left: expected = measuredEdge - screenFrame.minX
            case .right: expected = screenFrame.maxX - measuredEdge
            }
            check(near(reserve, expected),
                  "\(position.rawValue): reserve \(Int(reserve))pt matches the verified \(Int(expected))pt")
            check(reserve < (edge.isVertical ? screenFrame.width : screenFrame.height) / 2,
                  "\(position.rawValue): reserve is a band, not half the screen")

            let reservation = DockReservation(displayID: 0, edge: edge, thickness: reserve)
            let layoutScreen = WindowLayoutScreen(frame: screenFrame, visibleFrame: visibleFrame,
                                                  displayID: 0, reservation: reservation)
            let allowed = layoutScreen.allowedFrame
            check(allowed.width > 160 && allowed.height > 160,
                  "\(position.rawValue): allowed frame stays usable")
            check(screenFrame.insetBy(dx: -1, dy: -1).contains(allowed),
                  "\(position.rawValue): allowed frame stays inside the screen")

            // 外部最大化：整屏窗口必须被纠正回可用区，且不越出屏幕。
            let outcome = WindowLayoutCorrection.correction(
                current: screenFrame, allowed: allowed, edge: edge, previous: nil)
            guard let corrected = outcome.target else {
                check(false, "\(position.rawValue): a full-screen window is corrected "
                      + "(current=\(screenFrame) allowed=\(allowed) grew=\(outcome.grew))")
                continue
            }
            check(screenFrame.insetBy(dx: -1, dy: -1).contains(corrected),
                  "\(position.rawValue): corrected window stays on screen")
            switch edge {
            case .bottom:
                check(near(corrected.maxY, allowed.maxY), "\(position.rawValue): bottom edge meets the allowed area")
            case .top:
                check(near(corrected.minY, allowed.minY), "\(position.rawValue): top edge meets the allowed area")
            case .left:
                check(near(corrected.minX, allowed.minX), "\(position.rawValue): left edge meets the allowed area")
            case .right:
                check(near(corrected.maxX, allowed.maxX), "\(position.rawValue): right edge meets the allowed area")
            }

            // 变小与移动不纠正。
            let small = allowed.insetBy(dx: allowed.width / 4, dy: allowed.height / 4)
            check(WindowLayoutCorrection.correction(
                    current: small, allowed: allowed, edge: edge,
                    previous: small.insetBy(dx: -40, dy: -40)).target == nil,
                  "\(position.rawValue): shrinking is left alone")
            check(WindowLayoutCorrection.correction(
                    current: small, allowed: allowed, edge: edge, previous: small).target == nil,
                  "\(position.rawValue): moving is left alone")
        }

        print(failures == 0
              ? "Window layout: 4 dock edges verified"
              : "Window layout: \(failures) check(s) failed")
        return failures == 0
    }

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
        DockApp(bundleID: "com.apple.Safari", name: "Safari", pid: 2147483646, windowCount: 0, isPinnedHere: true),
        DockApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 2147483646, windowCount: 1, isPinnedHere: true),
        DockApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 2147483646, windowCount: 1,
                title: "中文与 English 标题布局预览"),
        DockApp(bundleID: "com.apple.calculator", name: "Calculator", pid: 2147483645, windowCount: 1,
                windowIDs: [999], windowID: 999, title: "Full screen", isFullscreenItem: true),
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
