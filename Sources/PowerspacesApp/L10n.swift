// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var label: String { self == .english ? "English" : "简体中文" }

    /// 未保存选择时，匹配系统首选语言；不支持的语言回退到英文。
    static var systemDefault: AppLanguage {
        let matched = Bundle.preferredLocalizations(from: allCases.map(\.rawValue)).first ?? "en"
        return AppLanguage(rawValue: matched) ?? .english
    }
}

enum L10n {
    // 已打包应用从 Resources 读取；开发运行才使用 SwiftPM 的生成路径。
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "powerspaces_PowerspacesApp", withExtension: "bundle"),
           let bundled = Bundle(url: url) { return bundled }
        return Bundle.module
    }()
    // 启动队列也会生成警告文案；锁保护语言选择，避免与设置界面并发读写。
    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage.systemDefault
    }
    private static let selection = Selection()
    static var language: AppLanguage {
        get {
            selection.lock.lock()
            defer { selection.lock.unlock() }
            return selection.language
        }
        set {
            selection.lock.lock()
            defer { selection.lock.unlock() }
            selection.language = newValue
        }
    }

    /// SwiftPM 的 native 后端会小写语言目录；兼容两种产物布局。
    static func localizationPath(for language: AppLanguage) -> String? {
        resourceBundle.path(forResource: language.rawValue, ofType: "lproj")
            ?? resourceBundle.path(forResource: language.rawValue.lowercased(), ofType: "lproj")
    }

    /// 按应用内选择查找完整文案；输入英文键，缺少翻译时返回原文。
    static func string(_ key: String) -> String {
        string(key, language: language)
    }

    /// 指定语言查找文案，供界面和资源校验复用；不改变进程当前语言。
    static func string(_ key: String, language: AppLanguage) -> String {
        guard let path = localizationPath(for: language),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 用完整译文模板插入动态内容；输入格式键和参数，输出本地化后的字符串。
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
