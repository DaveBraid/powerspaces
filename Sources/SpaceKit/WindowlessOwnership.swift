// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 按窗口记录桌面归属：移动替换、关闭保留，进程退出或被替换时清理。
public struct WindowlessOwnership {
    private struct Entry: Codable, Equatable {
        let identity: String
        var scopes: Set<String>
        var windowScopes: [UInt32: Set<String>]?
        var retainedScopes: Set<String>?
        var inferredOnly: Bool?
    }
    private var entries: [pid_t: Entry] = [:]
    private let url: URL?

    /// 可选文件用于恢复仍存活进程的归属；测试不传路径时只使用内存。
    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([pid_t: Entry].self, from: data) {
            entries = saved
        }
    }

    /// 有窗口 ID 时按窗口迁移归属；无历史且全局无窗口时才归入当前桌面，身份含启动时间。
    public mutating func update(livePIDs: Set<pid_t>, pidsWithWindows: Set<pid_t>,
                                visibleScopes: [pid_t: Set<String>], fallbackScope: String,
                                processIdentities: [pid_t: String] = [:],
                                observedWindows: [pid_t: [UInt32: Set<String>]]? = nil,
                                liveWindowIDs: Set<UInt32> = []) {
        let previous = entries
        entries = entries.filter { livePIDs.contains($0.key) }
        for pid in livePIDs {
            let identity = processIdentities[pid] ?? "pid:\(pid)" // 无持久化的纯模型调用可只使用 PID。
            if entries[pid]?.identity != identity { entries[pid] = nil }
            if let observedWindows {
                let observed = (observedWindows[pid] ?? [:]).mapValues { $0.filter { !$0.isEmpty } }
                    .filter { !$0.value.isEmpty }
                var entry = entries[pid] ?? Entry(identity: identity, scopes: [])
                if entry.windowScopes == nil {
                    // 旧版只有累计集合，无法区分移走与关闭；有窗口证据时重新建立准确基线。
                    entry.windowScopes = [:]
                    entry.retainedScopes = observed.isEmpty ? entry.scopes : []
                    entry.inferredOnly = observed.isEmpty
                }
                if !observed.isEmpty, entry.inferredOnly == true {
                    entry.retainedScopes = [] // 首个真实窗口替换启动时猜测的归属。
                    entry.inferredOnly = false
                }
                for (window, scopes) in observed {
                    entry.windowScopes?[window] = scopes // 同一窗口移动时替换归属，不能并集累加。
                }
                // 短暂缺失的窗口仍保留 ID，之后重新出现或移动可纠正；关闭历史限制为 256 项。
                let closed = (entry.windowScopes ?? [:]).keys.filter { !liveWindowIDs.contains($0) }.sorted()
                for window in closed.prefix(max(0, closed.count - 256)) {
                    entry.retainedScopes = (entry.retainedScopes ?? []).union(entry.windowScopes?[window] ?? [])
                    entry.windowScopes?.removeValue(forKey: window)
                }
                entry.scopes = (entry.retainedScopes ?? []).union((entry.windowScopes ?? [:]).values.flatMap { $0 })
                if entry.scopes.isEmpty, !pidsWithWindows.contains(pid), !fallbackScope.isEmpty {
                    entry.inferredOnly = true
                    entry.retainedScopes = [fallbackScope]
                    entry.scopes = [fallbackScope]
                }
                entries[pid] = entry
                continue
            }
            let visible = (visibleScopes[pid] ?? []).filter { !$0.isEmpty }
            if !visible.isEmpty {
                var entry = entries[pid] ?? Entry(identity: identity, scopes: [])
                entry.scopes.formUnion(visible) // 切换桌面不能覆盖此前已经属于的桌面。
                entries[pid] = entry
            } else if entries[pid] == nil, !pidsWithWindows.contains(pid), !fallbackScope.isEmpty {
                entries[pid] = Entry(identity: identity, scopes: [fallbackScope])
            }
        }
        guard entries != previous, let url else { return } // 空闲刷新不写磁盘。
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("PowerSpaces: cannot save app desktop ownership: %@", error.localizedDescription)
        }
    }

    /// 查询正在运行的应用是否已属于指定显示器桌面，与其他桌面是否仍有窗口无关。
    public func contains(_ pid: pid_t, scope: String) -> Bool {
        entries[pid]?.scopes.contains(scope) == true
    }
}
