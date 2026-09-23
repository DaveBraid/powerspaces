// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SpaceKit

// MARK: - Friendly labels for the strategy enum (UI only; SpaceKit stays neutral)

extension StrategyKind {
    var label: String {
        switch self {
        case .newInstance: return L10n.string("New instance (open -n)")
        case .openArgs: return L10n.string("Run with args (--new-window)")
        case .appleScript: return L10n.string("AppleScript (new document)")
        case .warn: return L10n.string("Show a warning")
        case .quitReopen: return L10n.string("Quit there and reopen here")
        case .cmdN: return L10n.string("Synthesize ⌘N")
        case .focusOnly: return L10n.string("Focus (accept the jump)")
        case .moveHere: return L10n.string("Move it to this desktop")
        }
    }

    /// 设置界面用的标签。`.moveHere` 依赖未公开的系统接口，因此标注为实验性，
    /// 让用户在勾选前就知道它可能在其它 macOS 版本上失效。
    var pickerLabel: String {
        self == .moveHere
            ? L10n.string("Move it to this desktop (experimental)")
            : label
    }
}

/// One known single-window app macOS can't reliably give a second window.
struct SingleInstanceApp: Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

enum SingleInstance {
    /// Curated list of single-window apps for which macOS can't reliably give a
    /// second window on the current Space — so "Open a new window" is labelled
    /// experimental for them, and they ship a `warn` default.
    static let apps: [SingleInstanceApp] = [
        SingleInstanceApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        SingleInstanceApp(bundleID: "com.apple.systempreferences", name: "System Settings"),
        SingleInstanceApp(bundleID: "com.apple.Music", name: "Music"),
        SingleInstanceApp(bundleID: "com.apple.reminders", name: "Reminders"),
        SingleInstanceApp(bundleID: "com.apple.iCal", name: "Calendar"),
        SingleInstanceApp(bundleID: "com.apple.AddressBook", name: "Contacts"),
        SingleInstanceApp(bundleID: "com.apple.mail", name: "Mail"),
    ]

    /// The strategies offered as a global default for unknown apps. (`appleScript`
    /// is excluded — it needs a per-app script.)
    static let defaultChoices: [StrategyKind] = [.newInstance, .openArgs, .cmdN, .focusOnly, .moveHere, .warn]

    /// One of the curated single-instance apps, for which macOS can't reliably
    /// give a second window — so "Open a new window" is labelled experimental.
    static func isSingleInstance(bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID }
    }
}

// MARK: - On-disk overrides (config.json)

/// Reads and writes the user's strategy overrides, preserving any entries the UI
/// doesn't touch (e.g. a hand-tuned browser `--new-window`). It reads/writes the
/// same on-disk shape SpaceKit defines (`StrategyConfig.ConfigFile`) so there's a
/// single schema for `~/.config/powerspaces/config.json`.
final class StrategyStore {
    let url: URL
    private var file: StrategyConfig.ConfigFile

    init(url: URL = StrategyConfig.defaultConfigURL) {
        self.url = url
        self.file = JSONFileStore.read(StrategyConfig.ConfigFile.self, from: url)
            ?? StrategyConfig.ConfigFile()
    }

    /// Effective default = user override, else the shipped code default.
    func effectiveDefault() -> StrategyKind {
        file.defaultStrategy ?? StrategyConfig.defaults.defaultKind
    }

    /// Effective strategy for an app = user override, else shipped code default.
    func effectiveStrategy(for bundleID: String) -> StrategyKind {
        file.apps?.first { $0.bundleID == bundleID }?.strategy
            ?? StrategyConfig.defaults.strategy(for: bundleID)
    }

    /// 旧的逐应用设置不一致时返回 nil，让统一下拉明确显示“已有单独设置”。
    func effectiveSingleInstanceStrategy() -> StrategyKind? {
        let choices = SingleInstance.apps.map { effectiveStrategy(for: $0.bundleID) }
        guard let first = choices.first, choices.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 一次写入全部已知单实例应用，保留其他应用规则和每项附加参数。
    func setSingleInstanceStrategy(_ kind: StrategyKind) {
        for app in SingleInstance.apps { setStrategy(kind, for: app.bundleID, saveNow: false) }
        save()
    }

    func setDefault(_ kind: StrategyKind) {
        file.defaultStrategy = kind
        save()
    }

    /// Upserts one app's strategy, preserving its `appleScript`/`args` so we never
    /// drop a scripted/arg'd entry when only flipping the strategy.
    func setStrategy(_ kind: StrategyKind, for bundleID: String, saveNow: Bool = true) {
        let existing = file.apps?.first { $0.bundleID == bundleID }
        let appleScript = existing?.appleScript ?? StrategyConfig.defaults.appleScript(for: bundleID)
        let defaultArgs = StrategyConfig.defaults.args(for: bundleID)
        let args = existing?.args ?? (defaultArgs.isEmpty ? nil : defaultArgs)
        let entry = AppStrategy(bundleID: bundleID, strategy: kind, appleScript: appleScript, args: args)
        var apps = file.apps ?? []
        if let i = apps.firstIndex(where: { $0.bundleID == bundleID }) { apps[i] = entry }
        else { apps.append(entry) }
        file.apps = apps
        if saveNow { save() }
    }

    private func save() { JSONFileStore.writeEncodable(file, to: url) }
}

// MARK: - Controller shared by the right-click menu and the preferences window

/// Owns the `StrategyStore` and notifies the app to reload its live
/// `StrategyConfig`. Both the dock's right-click menu and the Strategies tab route
/// through this one instance, so they never disagree.
final class StrategySettingsController: ObservableObject {
    // No @Published members (state lives in StrategyStore); drive updates by hand.
    let objectWillChange = ObservableObjectPublisher()
    private let store: StrategyStore

    /// 从指定配置文件加载策略；预览传入临时路径，默认仍使用正式配置。
    init(url: URL = StrategyConfig.defaultConfigURL) {
        store = StrategyStore(url: url)
    }
    /// Set by AppDelegate: reload config.json into the running launcher + refresh.
    var onChanged: (() -> Void)?

    func effectiveDefault() -> StrategyKind { store.effectiveDefault() }
    func effectiveStrategy(for bundleID: String) -> StrategyKind { store.effectiveStrategy(for: bundleID) }
    func effectiveSingleInstanceStrategy() -> StrategyKind? { store.effectiveSingleInstanceStrategy() }

    /// 为预置单实例应用统一选择行为；退出重开只确认一次。
    @MainActor func setSingleInstanceStrategy(_ kind: StrategyKind) {
        if kind == .quitReopen, !confirmSingleInstanceQuitReopen() { return }
        store.setSingleInstanceStrategy(kind)
        publish()
    }

    func setDefault(_ kind: StrategyKind) {
        store.setDefault(kind)
        publish()
    }

    /// Applies a per-app strategy (the dock's right-click menu and the Strategies
    /// tab). `quitReopen` quits the whole app, so it confirms first — any unsaved or
    /// transient state in the app is lost. Returns whether it was applied.
    @discardableResult
    @MainActor func setStrategy(_ kind: StrategyKind, forBundleID bundleID: String, name: String) -> Bool {
        if kind == .quitReopen, !confirmQuitReopen(name: name) { return false }
        store.setStrategy(kind, for: bundleID)
        publish()
        return true
    }

    private func publish() {
        objectWillChange.send()
        onChanged?()
    }

    /// 批量选择危险策略前告知影响；这里只保存规则，不立即退出任何应用。
    @MainActor private func confirmSingleInstanceQuitReopen() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Quit and reopen single-window apps when opened elsewhere?")
        alert.informativeText = L10n.string("When you click one of these apps while its window is on another desktop, Powerspaces will quit and reopen it here. Unsaved work or playback in that app may be lost. This selection does not quit any app now.")
        alert.addButton(withTitle: L10n.string("Use this behavior"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor private func confirmQuitReopen(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("Quit %@ there and reopen it here?", String(describing: name))
        alert.informativeText = L10n.format(
            "When %@ is open on another desktop, this quits it entirely and relaunches it on the "
            + "current one, the only reliable way to bring a single-window app here. Any unsaved or "
            + "transient state in %@ is lost.", String(describing: name), String(describing: name))
        alert.addButton(withTitle: L10n.string("Quit and reopen here anyway"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
