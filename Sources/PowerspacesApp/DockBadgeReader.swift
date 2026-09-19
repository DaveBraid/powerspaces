// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices

/// 只读系统 Dock；失败不等于空徽章，身份仅由 AXURL 对应的应用包确定。
enum DockBadgeReader {
    nonisolated(unsafe) private static let bundleIDs: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 512 // 应用 URL 身份缓存有界，Dock 轮询不反复读取包元数据。
        return cache
    }()

    /// URL 为主键，bundle ID 从应用包取得；永不使用显示名称兜底。
    private static func identity(_ url: URL) -> String? {
        if let value = bundleIDs.object(forKey: url as NSURL) { return value as String }
        guard let value = Bundle(url: url)?.bundleIdentifier else { return nil }
        bundleIDs.setObject(value as NSString, forKey: url as NSURL)
        return value
    }

    struct Item {
        let element: AXUIElement
        let bundleID: String
        let url: URL
        let label: String? // nil 表示本次读取失败；空字符串才表示明确无徽章。
        let status: AXError
    }
    struct Snapshot {
        let pid: pid_t
        let root: AXUIElement
        let list: AXUIElement
        let items: [Item]
        let complete: Bool
    }

    /// 单个属性读取保留错误码，供缓存和诊断区别空值、权限与失效元素。
    static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    }

    /// 有界读取 Dock 的列表及应用项，不遍历其他应用、不按显示名称猜测身份。
    static func snapshot() -> Snapshot? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2) // 工作线程单次 IPC 上限，避免主线程阻塞。
        guard let children = attribute(root, kAXChildrenAttribute).1 as? [AXUIElement],
              let list = children.first(where: { attribute($0, kAXRoleAttribute).1 as? String == "AXList" }),
              let elements = attribute(list, kAXChildrenAttribute).1 as? [AXUIElement], elements.count <= 512
        else { return nil }
        var items: [Item] = []
        var complete = true
        let deadline = Date().addingTimeInterval(2) // 每轮总读取预算，异常 Dock 不能无限拖延。
        for element in elements {
            if Date() > deadline { complete = false; break }
            AXUIElementSetMessagingTimeout(element, 0.2)
            let subrole = attribute(element, kAXSubroleAttribute).1 as? String
            guard let subrole else { complete = false; continue }
            guard subrole == "AXApplicationDockItem" else { continue }
            guard let raw = attribute(element, kAXURLAttribute).1 else { complete = false; continue }
            let url: URL?
            if let value = raw as? URL { url = value }
            else if let value = raw as? String { url = URL(string: value) }
            else { url = nil }
            guard let url, url.isFileURL, let bundleID = identity(url) else { complete = false; continue }
            let (status, value) = attribute(element, "AXStatusLabel")
            let label: String?
            if status == .success { label = value as? String }
            else if status == .noValue { label = "" }
            else { label = nil }
            items.append(Item(element: element, bundleID: bundleID, url: url, label: label, status: status))
        }
        return Snapshot(pid: dock.processIdentifier, root: root, list: list, items: items, complete: complete)
    }

    @MainActor private static var diagnosticObserver: AXObserver?
    @MainActor private static var diagnosticTimer: Timer?

    /// 限时诊断日志，事件回调只记通知类型；不把观察能力当作通知可靠性的证明。
    @MainActor private static func appendDiagnostic(_ line: String) {
        let path = "/tmp/ps-dock-badge-study/diagnostic.log"
        let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (previous + "\n" + line).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 在应用自身权限上下文记录只读快照及通知注册结果，不触发权限提示。
    @MainActor static func diagnose() {
        try? FileManager.default.createDirectory(atPath: "/tmp/ps-dock-badge-study", withIntermediateDirectories: true)
        let path = "/tmp/ps-dock-badge-study/diagnostic.log"
        var lines = ["trusted=\(AXIsProcessTrusted())"]
        if let snapshot = snapshot() {
            lines.append("dockPID=\(snapshot.pid) items=\(snapshot.items.count)")
            var observer: AXObserver?
            let result = AXObserverCreate(snapshot.pid, { _, _, notification, _ in
                MainActor.assumeIsolated { DockBadgeReader.appendDiagnostic("EVENT \(notification)") }
            }, &observer)
            lines.append("observer=\(result.rawValue)")
            diagnosticObserver = observer
            if let observer { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            for item in snapshot.items {
                lines.append("\(item.bundleID) url=\(item.url.absoluteString) status=\(item.status.rawValue) label=\(String(reflecting: item.label))")
                if let observer {
                    for notification in ["AXValueChanged", "AXTitleChanged", "AXStatusLabelChanged"] {
                        lines.append("register \(notification)=\(AXObserverAddNotification(observer, item.element, notification as CFString, nil).rawValue)")
                    }
                }
            }
        } else { lines.append("snapshot unavailable") }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        guard AXIsProcessTrusted(), CommandLine.arguments.contains("--observe-system-badges") else {
            NSApp.terminate(nil); return
        }
        var remaining = 30 // 独立诊断最多 30 秒；生产读取由低频 Store 管理。
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if let snapshot = snapshot() {
                    let values = snapshot.items.map { "\($0.bundleID)=\(String(reflecting: $0.label))" }.joined(separator: ",")
                    appendDiagnostic("SAMPLE pid=\(snapshot.pid) \(values)")
                } else { appendDiagnostic("SAMPLE unavailable") }
                remaining -= 1
                if remaining == 0 { timer.invalidate(); NSApp.terminate(nil) }
            }
        }
    }
}
