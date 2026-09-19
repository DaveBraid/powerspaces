// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices

/// 管理 AX 授权与历史失效条目的修复。临时签名的身份包含构建哈希，更新可能使旧授权失效。
/// 本机打包现使用固定证书和 bundle ID；首次迁移仍需用户授权，之后保持相同签名身份。
/// 重置仅由用户确认触发，不能作为更新后的自动操作。
enum AccessibilityPermission {
    /// The app's bundle identifier, used to scope the TCC reset. Falls back to the
    /// known id when running unbundled (`swift run`), where `Bundle.main` has none.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "nl.sebastianpdw.powerspaces"
    }

    /// Whether macOS currently trusts this process for Accessibility. Read live each
    /// time, since a reset (or a grant in System Settings) changes it underneath us.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show its Accessibility prompt (the dialog with an "Open System
    /// Settings" button) when we're not already trusted. A no-op when already
    /// granted. Used by the first-run welcome window and the cold-launch path.
    static func prompt() {
        // `kAXTrustedCheckOptionPrompt` imports as a mutable global (`CFString`),
        // which trips strict-concurrency checking. Its value is the stable,
        // documented key string, so use the literal directly to stay clean.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 用户主动打开授权引导；复用系统提示与设置入口，不自动修改权限。
    @MainActor static func showAuthorizationGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("Enable Accessibility for Powerspaces")
        alert.informativeText = L10n.string(
            "Allow Powerspaces in System Settings → Privacy & Security → Accessibility to read Dock notification badges and manage windows. If Powerspaces is missing, add /Applications/Powerspaces.app with the + button. If it is already enabled but shows Not granted here, switch it off and on again; use Reset Permission if that does not help.")
        alert.addButton(withTitle: L10n.string("Open System Settings"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        prompt()
        openSettings()
    }

    /// Clear the app's Accessibility approval from macOS's TCC database, dropping any
    /// stale entry left by an earlier build. Returns true on success. Doesn't need
    /// sudo: it only touches the current user's permissions.
    @discardableResult
    static func reset() -> Bool {
        run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID]) // 系统服务标识不能翻译。
    }

    /// Open System Settings straight to Privacy & Security ▸ Accessibility, where the
    /// user re-approves Powerspaces after a reset.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and relaunch the app so the fresh process re-requests Accessibility and
    /// re-evaluates trust. A detached shell waits for our PID to exit before
    /// reopening — otherwise macOS sees the still-live instance and just foregrounds
    /// it instead of launching a new one. Only the bundled `.app` can be reopened
    /// this way; unbundled (`swift run`) we just terminate.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let pid = ProcessInfo.processInfo.processIdentifier
        // The script is a fixed literal; the pid and bundle path are passed as
        // positional parameters ($1, $2), NOT interpolated into the script text —
        // so a bundle path containing shell metacharacters can't break out of it.
        // (`sh -c <script> <argv0> <arg1> <arg2>` binds $0=argv0, $1=arg1, $2=arg2.)
        let script = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open "$2""#
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "powerspaces-relaunch", String(pid), path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Confirm with the user, clear the stale grant, and relaunch — or explain the
    /// manual `tccutil` line if the reset fails, so they're never left stuck. Shared
    /// by the status-menu item and the Preferences ▸ System reset row, so the copy
    /// and the flow live in exactly one place.
    @MainActor static func confirmResetAndRelaunch() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Reset Accessibility permission?")
        alert.informativeText = L10n.string(
            "This clears Powerspaces' Accessibility approval from macOS, then relaunches the app so "
            + "you can grant it fresh. Use it when you've enabled Accessibility but window actions "
            + "still say it's missing, usually after rebuilding or reinstalling.\n\nAfter the relaunch, "
            + "switch Powerspaces back on in System Settings ▸ Privacy & Security ▸ Accessibility.")
        alert.addButton(withTitle: L10n.string("Reset & Relaunch"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performResetAndRelaunch()
    }

    /// Clear the stale grant and relaunch, surfacing a manual-`tccutil` fallback alert
    /// if the reset fails so the user is never left stuck. The shared core behind both
    /// the Preferences/menu "reset" row (which confirms first, via
    /// `confirmResetAndRelaunch`) and the launch-time accessibility-repair popup (which
    /// is itself the confirmation, so it calls this directly).
    @MainActor static func performResetAndRelaunch() {
        guard reset() else {
            let fail = NSAlert()
            fail.alertStyle = .critical
            fail.messageText = L10n.string("Couldn't reset the permission")
            fail.informativeText = L10n.format("Running tccutil failed. Reset it manually in Terminal:\n\ntccutil reset Accessibility %@", String(describing: bundleID))
            fail.runModal()
            return
        }
        relaunch()
    }

    /// Run a command-line tool, swallowing its output, and report whether it exited
    /// cleanly. Synchronous: `tccutil` finishes in milliseconds.
    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
