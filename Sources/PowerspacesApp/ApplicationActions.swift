// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// 状态栏和程序坞共用应用级操作；退出始终经过 NSApplication 的正常生命周期。
@MainActor
final class ApplicationActions: NSObject {
    static let shared = ApplicationActions()
    private let terminate: () -> Void
    private var quitPending = false

    /// 注入终止动作供回归测试使用；正式应用复用现有系统退出与清理逻辑。
    init(terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.terminate = terminate
        super.init()
    }

    /// 创建相同 target/action 的退出项；仅快捷键按入口需要设置。
    func quitMenuItem(keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("Quit Powerspaces"),
                              action: #selector(quit(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        return item
    }

    /// 先结束弹出菜单跟踪，再在主队列退出；避免非激活面板的嵌套菜单循环干扰退出。
    @objc private func quit(_ sender: NSMenuItem) {
        sender.menu?.cancelTracking()
        guard !quitPending else { return }
        quitPending = true // 合并菜单关闭前重复投递的退出动作。
        DispatchQueue.main.async { [self] in
            quitPending = false
            terminate()
        }
    }
}
