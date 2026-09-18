// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

enum DevelopmentTools {
    static let isPreview = CommandLine.arguments.contains("--preview-settings")
    static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("powerspaces-preview-\(UUID().uuidString)")

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
            guard let path = L10n.resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
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
    /// 预览窗口关闭后退出进程，避免留下没有窗口的开发实例。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 清理本次预览产生的临时设置，正式用户配置从未被使用。
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: DevelopmentTools.previewDirectory)
    }
}
