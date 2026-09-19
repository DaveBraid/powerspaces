// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// 系统设置里「切换到应用程序时，切换到有打开窗口的空间」的状态。
///
/// 该开关打开时，激活一个在他桌面的应用会先把用户带过去，PS 的自动搬移就没有意义了。
/// 这里**只读**：提示用户去系统设置关闭，绝不代改。
enum SpacesSwitchOnActivate {

    /// 系统设置里的键名。
    static let defaultsKey = "AppleSpacesSwitchOnActivate"

    /// 是否处于开启状态。**缺失时按开启处理**——系统默认是开，按开提示更保守。
    ///
    /// `defaults` 可注入：检查用独立 suite，避免受本机全局域里已有的值影响。
    /// 读法与属性分开命名（`readsOn` / `isOn`），避免同名重载在调用处解析冲突。
    static func readsOn(in defaults: UserDefaults) -> Bool {
        decide(stored: defaults.object(forKey: defaultsKey) as? NSNumber)
    }

    /// 纯判定：**缺失（nil）按开启处理**——系统默认是开，按开提示更保守。
    /// 抽成纯函数是因为 `UserDefaults(suiteName:)` 仍会回退到全局域，
    /// 无法在真实系统上构造"缺失"这一输入。
    static func decide(stored: NSNumber?) -> Bool {
        guard let stored else { return true }
        return stored.boolValue
    }

    /// 应用界面使用的读法（系统默认域）。
    static var isOn: Bool { readsOn(in: .standard) }

    /// 打开「桌面与程序坞」设置面板；失败时静默忽略，不弹错误。
    @MainActor
    static func openDesktopSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}