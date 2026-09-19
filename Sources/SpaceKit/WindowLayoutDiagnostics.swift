// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 布局接管的落盘诊断日志。
///
/// 事件回调与动画队列都在非主线程，`os.Logger` 的 debug 级在排查时不易读取；
/// 这里额外写一份固定路径的文本日志，用于在无法附加调试器时定位
/// 「识别到了但没有接管」这类问题。不参与功能判断，写失败静默忽略。
public enum WindowLayoutDiagnostics {
    /// 诊断日志路径；仅用于本地排查。
    public static let path = "/tmp/ps-window-layout.log"

    /// 追加一行带时间戳的记录。
    public static func record(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
