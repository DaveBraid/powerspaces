// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SpaceKit

// Right-click context menu for dock icons — extracted from DockPanel.swift to
// keep that file manageable (review finding H15). Uses only DockPanel's internal
// callbacks (onPinHere, onSetStrategy, …); no other DockPanel internals are touched.
extension DockPanel: NSMenuDelegate {
    /// 菜单跟踪期间冻结会移动或重建锚点的更新，关闭后由正常刷新恢复。
    func menuWillOpen(_ menu: NSMenu) { WindowHoverPreview.shared.close(for: self); isContextMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isContextMenuOpen = false; resetMagnification() }


    /// Pairs an app with a strategy for a context-menu item's representedObject.
    private final class StrategyChoice {
        let app: DockApp
        let kind: StrategyKind
        init(app: DockApp, kind: StrategyKind) { self.app = app; self.kind = kind }
    }

    // MARK: - Context menu (shown above the icon)

    func showMenu(for app: DockApp, from button: NSButton) {
        let menu = NSMenu()
        menu.delegate = self
        // The way back in when the menu-bar item is set to Hidden: a right-click on
        // any icon reaches Preferences. Shown at the very top, and only while the
        // icon is hidden — with it visible, that's the entry point, so we omit this.
        if let prefs = preferencesItemIfMenuBarHidden() {
            menu.addItem(prefs)
            menu.addItem(.separator())
        }
        // The launcher tile isn't an app: no pin/strategy/quit items, just open it
        // or turn the feature off.
        if app.isLauncher {
            menu.addItem(item(L10n.string("Open App Launcher"), #selector(openLauncherMenu(_:)), app, symbol: "square.grid.2x2"))
            menu.addItem(.separator())
            menu.addItem(item(L10n.string("Hide App Launcher"), #selector(disableLauncherMenu(_:)), app, symbol: "eye.slash"))
            addDockColorItems(to: menu)
            popUpMenu(menu, from: button)
            return
        }
        menu.addItem(item(L10n.string("Open new window"), #selector(openNewWindow(_:)), app, symbol: "macwindow.badge.plus"))
        if app.bundleID != nil {
            menu.addItem(.separator())
            // For an all-desktops pin, "this desktop" toggles a per-desktop
            // exception (hide here / show here) instead of a local pin, so the app
            // stays pinned on every other desktop.
            if app.isPinnedEverywhere {
                menu.addItem(item(app.isExcludedHere ? L10n.string("Pin (this desktop)") : L10n.string("Unpin (this desktop)"),
                                  #selector(toggleHereForEverywhere(_:)), app, symbol: "pin"))
            } else {
                menu.addItem(item(app.isPinnedHere ? L10n.string("Unpin (this desktop)") : L10n.string("Pin (this desktop)"),
                                  #selector(togglePinHere(_:)), app, symbol: "pin"))
            }
            menu.addItem(item(app.isPinnedEverywhere ? L10n.string("Unpin (all desktops)") : L10n.string("Pin (all desktops)"),
                              #selector(togglePinEverywhere(_:)), app, symbol: "pin.fill"))
        }
        if let bundleID = app.bundleID, let current = currentStrategy?(app) {
            menu.addItem(.separator())
            // How to make a new window *for this app* — written here as a per-app
            // override. Unlike the global default in Preferences, this is scoped to
            // one app, so we also offer `appleScript`: the global list omits it
            // because a blank script is useless, but here `setStrategy` keeps the
            // app's shipped/edited snippet (Finder, Safari, Terminal …) when you
            // switch to it — so the option must always be selectable, not only when
            // it happens to be the current strategy. Append the current strategy
            // last in case it's some other omitted kind, so it still shows ticked.
            var choices = SingleInstance.defaultChoices
            if let i = choices.firstIndex(of: .openArgs) {
                choices.insert(.appleScript, at: i + 1) // sit beside the other "make a real window" kinds
            } else {
                choices.append(.appleScript)
            }
            if !choices.contains(current) { choices.append(current) }
            let newWindowMenu = NSMenu()
            for kind in choices {
                newWindowMenu.addItem(strategyItem(kind.label, kind, app, current))
            }
            let newWindowParent = NSMenuItem(title: L10n.string("New-window strategy"), action: nil, keyEquivalent: "")
            newWindowParent.submenu = newWindowMenu
            menu.addItem(newWindowParent)

            let submenu = NSMenu()
            // The default: try to give you a window on this Space. It stands for
            // the whole new-window-strategy family, so it ticks whenever the app
            // isn't set to warn. Picking it keeps the user's current new-window
            // strategy if they have one, else falls back to the app's shipped
            // default — or a plain new instance for the curated single-instance
            // apps, where it's experimental and they can refine it via
            // "New-window strategy" above.
            let isSingle = SingleInstance.isSingleInstance(bundleID: bundleID)
            let newWindowLabel = isSingle ? L10n.string("Open a new window (experimental)") : L10n.string("Open a new window")
            let newWindowKind: StrategyKind
            if current.makesNewWindow {
                newWindowKind = current
            } else {
                let shipped = StrategyConfig.defaults.strategy(for: bundleID)
                newWindowKind = shipped.makesNewWindow ? shipped : .newInstance
            }
            submenu.addItem(strategyItem(newWindowLabel, newWindowKind, app, current))
            submenu.addItem(.separator())
            submenu.addItem(strategyItem(L10n.string("Show a warning"), .warn, app, current))
            // 仓库里「搬到本桌面」依赖未公开接口，菜单里同样标注实验性。
            submenu.addItem(strategyItem(StrategyKind.moveHere.pickerLabel,
                                         .moveHere, app, current))
            submenu.addItem(strategyItem(L10n.string("Quit there and reopen here"), .quitReopen, app, current))
            let parent = NSMenuItem(title: L10n.string("When open elsewhere"), action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        // When this icon stands for one specific window (the "Windows" feature),
        // offer to close just that window — distinct from quitting the app.
        if app.windowID != nil {
            menu.addItem(item(L10n.string("Close this window"), #selector(closeWindow(_:)), app, symbol: "xmark"))
        }
        if !app.isFullscreenItem {
            menu.addItem(item(L10n.string("Quit (this desktop)"), #selector(closeThisDesktop(_:)), app, symbol: "xmark.circle"))
        }
        menu.addItem(item(L10n.string("Quit (all desktops)"), #selector(closeAllDesktops(_:)), app, symbol: "xmark.octagon"))
        addDockColorItems(to: menu)
        popUpMenu(menu, from: button)
    }

    // MARK: - Dock menu (Open Preferences / Quit)

    /// The dock's own right-click menu, shown on empty bar background by
    /// `DockDropView`. Its key job is to reach Preferences (and Quit Powerspaces)
    /// when the menu-bar item is set to Hidden — that's then the only way in.
    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Preferences only when the menu-bar icon is Hidden — see comment below.
        if let prefs = preferencesItemIfMenuBarHidden() {
            menu.addItem(prefs)
        }
        addDockColorItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(ApplicationActions.shared.quitMenuItem(keyEquivalent: ""))
        return menu
    }

    // MARK: - Dock color (this desktop)

    /// Insert the "Change Dock Color (this desktop)" item at the *start* of `menu` —
    /// it opens the per-desktop color editor (which also carries the "Reset to
    /// Default" action). Offered on the empty-bar menu and on every icon's menu, so
    /// the dock's color is reachable wherever you right-click the bar. A trailing
    /// separator is added only when the menu already has items below, so the dock's
    /// color sits at the very top without ever leaving a stray divider.
    private func addDockColorItems(to menu: NSMenu) {
        var items: [NSMenuItem] = []
        let change = NSMenuItem(title: L10n.string("Change dock color (this desktop)…"),
                                action: #selector(editDockColor(_:)), keyEquivalent: "")
        change.target = self
        change.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        items.append(change)
        if !menu.items.isEmpty { items.append(.separator()) }
        for (offset, menuItem) in items.enumerated() {
            menu.insertItem(menuItem, at: offset)
        }
    }

    @objc private func editDockColor(_ sender: NSMenuItem) { onEditDockColor?() }

    /// The "Open Preferences…" item, but only while the menu-bar icon is set to
    /// Hidden — then a right-click in the dock is the only way back into Preferences.
    /// With the icon visible, that's the entry point, so we omit this to keep the
    /// dock's menus uncluttered. Returns `nil` when the menu-bar icon is showing.
    private func preferencesItemIfMenuBarHidden() -> NSMenuItem? {
        guard Preferences.shared.menuGlyph.hidesStatusItem else { return nil }
        let menuItem = NSMenuItem(title: L10n.string("Open Preferences…"),
                                  action: #selector(openPreferencesMenu(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        return menuItem
    }

    @objc private func openPreferencesMenu(_ sender: NSMenuItem) { onOpenPreferences?() }

    /// 在**屏幕坐标**上弹出 `menu`，不锚定到任何视图。
    ///
    /// 原先用 `menu.popUp(positioning:at:in: button)`：锚在按钮所在的程序坞面板里，
    /// AppKit 会把菜单约束在面板窗口范围内，菜单比面板高时就被截断并出现滚动箭头
    /// （实测只能看到「更改程序坞颜色 / 新建窗口 / 固定」三项）。
    /// 改成以屏幕坐标调用后菜单是独立的，可以超出面板高度、完整显示。
    private func popUpMenu(_ menu: NSMenu, from button: NSButton) {
        // 先让菜单算出真实尺寸；贴边计算必须用它，否则会用到 0。
        menu.update()
        let size = menu.size
        // 锚点取**按钮自身的屏幕矩形**，不读 `NSEvent.mouseLocation`：合成事件下后者会返回
        // 错误位置（实测 y=45，而图标在屏幕底部），真实鼠标下虽然正确但没必要冒这个险。
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = button.window?.convertToScreen(buttonInWindow) ?? buttonInWindow
        // `popUp(positioning:at:in:)` 把这个点当作**菜单左上角**向下展开，
        // 所以要让菜单底边贴住图标上沿（并夹进屏幕可见区）。
        let screen = button.window?.screen ?? NSScreen.main
        let gap: CGFloat = 8
        var anchor = NSPoint(x: buttonOnScreen.midX - size.width / 2, y: buttonOnScreen.maxY + gap)
        if let visible = screen?.visibleFrame {
            anchor.x = min(max(anchor.x, visible.minX + gap), visible.maxX - size.width - gap)
            if anchor.y + size.height > visible.maxY {
                // 上方放不下就翻到图标下方（顶边贴住图标下沿）。
                anchor.y = max(visible.minY + gap, buttonOnScreen.minY - size.height - gap)
            }
            anchor.y = min(max(anchor.y, visible.minY + gap), visible.maxY)
        }
        // 容器必须传**宿主视图**：`in: nil` 时 AppKit 会把菜单压到约 3 项并加滚动箭头
        // （实测 12 项 246pt 只画出 3 项，而落点本身是对的）。传入按钮后菜单完整展开。
        guard let window = button.window else {
            menu.popUp(positioning: nil, at: anchor, in: nil)
            return
        }
        // 屏幕坐标 → 窗口坐标后再交给 AppKit。
        let anchorInWindow = window.convertFromScreen(NSRect(origin: anchor, size: .zero)).origin
        menu.popUp(positioning: nil, at: anchorInWindow, in: button)
    }

    private func strategyItem(_ title: String, _ kind: StrategyKind,
                              _ app: DockApp, _ current: StrategyKind) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(setStrategy(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = StrategyChoice(app: app, kind: kind)
        menuItem.state = (kind == current) ? .on : .off
        return menuItem
    }

    @objc private func setStrategy(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? StrategyChoice else { return }
        onSetStrategy?(choice.app, choice.kind)
    }

    private func item(_ title: String, _ action: Selector, _ app: DockApp, symbol: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = app
        if let symbol { menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return menuItem
    }

    @objc private func togglePinHere(_ s: NSMenuItem) { route(s, onPinHere) }
    @objc private func togglePinEverywhere(_ s: NSMenuItem) { route(s, onPinEverywhere) }
    @objc private func toggleHereForEverywhere(_ s: NSMenuItem) { route(s, onToggleHereForEverywhere) }
    @objc private func closeThisDesktop(_ s: NSMenuItem) { route(s, onCloseThisDesktop) }
    @objc private func closeAllDesktops(_ s: NSMenuItem) { route(s, onCloseAllDesktops) }
    @objc private func closeWindow(_ s: NSMenuItem) { route(s, onCloseWindow) }
    @objc private func openNewWindow(_ s: NSMenuItem) {
        guard let app = s.representedObject as? DockApp else { return }
        onSelect?(app, true, false)
    }
    @objc private func openLauncherMenu(_ s: NSMenuItem) { onOpenLauncher?() }
    @objc private func disableLauncherMenu(_ s: NSMenuItem) { onDisableLauncher?() }

    private func route(_ sender: NSMenuItem, _ handler: ((DockApp) -> Void)?) {
        guard let app = sender.representedObject as? DockApp else { return }
        handler?(app)
    }

    // MARK: - Middle-click

    /// Runs the user's configured middle-click action for `app`, reusing the same
    /// callbacks the right-click menu drives. The launcher tile stands for no app,
    /// so middle-click does nothing on it.
    func handleMiddleClick(_ app: DockApp) {
        guard !app.isLauncher else { return }
        switch Preferences.shared.middleClickAction {
        case .newWindow:
            onSelect?(app, true, false) // force a brand-new window, like the menu's "Open new window"
        case .quitThisDesktop:
            onCloseThisDesktop?(app)
        case .quitAllDesktops:
            onCloseAllDesktops?(app)
        case .closeWindow:
            // A per-window icon closes exactly its window; a plain app icon has no
            // single "this" window, so fall back to closing its windows here.
            if app.windowID != nil { onCloseWindow?(app) } else { onCloseThisDesktop?(app) }
        case .doNothing:
            break
        }
    }
}
