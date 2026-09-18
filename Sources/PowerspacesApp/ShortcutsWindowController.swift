// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

/// A discoverable cheat-sheet of every Powerspaces shortcut and dock gesture, so the
/// app's power is visible instead of having to be memorized (UX review Principle 7,
/// recognition over recall). Opened from the menu-bar menu and from Preferences. A
/// single shared window, like the other reused panels.
final class ShortcutsWindowController: ActivatingWindowController {
    private static var shared: ShortcutsWindowController?

    static func show() {
        if let existing = shared { existing.bringToFront(); return }
        let controller = ShortcutsWindowController()
        shared = controller
        controller.bringToFront()
    }

    private init() {
        super.init(title: "Keyboard Shortcuts",
                   styleMask: [.titled, .closable, .resizable],
                   content: NSHostingController(rootView: ShortcutsView()))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didClose() { ShortcutsWindowController.shared = nil }
}

/// The cheat-sheet content. Reads `Preferences` live, so the rows reflect the user's
/// actual launcher shortcut, force-new modifier, and middle-click action.
private struct ShortcutsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(L10n.string("App Launcher"), launcherRows)
                group(L10n.string("Dock"), dockRows)
                group(L10n.string("Menu bar"), menuRows)
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 400)
    }

    private var launcherRows: [(String, String)] {
        let open = prefs.launcherHotkey == .off
            ? (L10n.string("Not set"), L10n.string("Open the App Launcher (choose a shortcut in Preferences ▸ Behavior)"))
            : (prefs.launcherHotkey.label, L10n.string("Open the App Launcher from anywhere"))
        return [
            open,
            (L10n.string("Type"), L10n.string("Search your apps")),
            ("\u{2191} \u{2193} \u{2190} \u{2192}", L10n.string("Move the selection")),
            ("Return", L10n.string("Open the selected app on this desktop")),
            ("\u{2318}Return", L10n.string("Open it in a new window")),
            ("Esc", L10n.string("Close the launcher")),
            (L10n.string("Drag a tile to the bar"), L10n.string("Pin that app to this desktop")),
        ]
    }

    private var dockRows: [(String, String)] {
        [
            (L10n.string("Click"), L10n.string("Open or focus the app on this desktop")),
            (L10n.format("%@-click", String(describing: prefs.forceNewModifier.label)), L10n.string("Open a new window on this desktop")),
            (L10n.string("Middle-click"), prefs.middleClickAction.label),
            (L10n.string("Right-click"), L10n.string("App menu: pin, new-window rule, quit")),
            (L10n.string("Hold, then drag"), L10n.string("Reorder the icons")),
            (L10n.string("Drag an app onto the bar"), L10n.string("Pin it to this desktop")),
        ]
    }

    private var menuRows: [(String, String)] {
        [
            ("\u{2318}R", L10n.string("Refresh the dock")),
            ("\u{2318},", L10n.string("Open Preferences")),
            ("\u{2318}Q", L10n.string("Quit Powerspaces")),
        ]
    }

    private func group(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows, id: \.0) { keys, desc in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(keys)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(width: 150, alignment: .leading)
                    Text(desc)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
