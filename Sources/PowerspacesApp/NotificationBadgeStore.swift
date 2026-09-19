// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import SpaceKit

extension Notification.Name {
    static let dockNotificationBadgesChanged = Notification.Name("PSDockNotificationBadgesChanged")
}

/// 串行后台读取和主线程发布；通知不可靠时低频补读，鼠标与绘制路径只访问缓存。
final class NotificationBadgeStore: @unchecked Sendable {
    static let shared = NotificationBadgeStore()
    private let queue = DispatchQueue(label: "powerspaces.notification-badges", qos: .utility)
    private let lock = NSLock()
    private var published: [String: String] = [:] // 仅此字典跨线程，读写都持锁。
    private var cache = NotificationBadgeCache() // 以下状态只在 queue 上访问。
    private var pending: DispatchWorkItem?
    private var paused = false
    private var unchanged = 0
    private var failures = 0
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedElements: [AXUIElement] = []
    private var lastRead = Date.distantPast
    private var workspaceTokens: [NSObjectProtocol] = [] // 应用生命周期单例，主线程注册。

    /// 按 bundle ID 取原始字符串，不访问 AX、不派生桌面数量。
    func label(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return published[bundleID]
    }

    /// 启动通知监听；睡眠期间停读，Dock 重启和应用启退合并为一次刷新。
    @MainActor func start() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let sleeping = note.name == NSWorkspace.willSleepNotification
                self.queue.async {
                    self.paused = sleeping
                    self.pending?.cancel()
                    if !sleeping { self.unchanged = 0; self.schedule(after: 1) }
                }
            })
        }
        queue.async { self.schedule(after: 0) }
    }

    /// 合并连续 AX 事件，最多每两秒读一次；不重启鼠标动画或重建 Dock。
    private func notified() {
        queue.async {
            guard !self.paused else { return }
            self.unchanged = 0
            self.schedule(after: max(0.3, 2 - Date().timeIntervalSince(self.lastRead)))
        }
    }

    /// 单次定时任务；正常 5→15→30 秒退避，失败 10→60 秒退避。
    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        guard !paused else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 读取失败保留缓存；完整成功快照才移除已经退出且不在原生 Dock 的项目。
    private func refresh() {
        lastRead = Date()
        guard let snapshot = DockBadgeReader.snapshot() else {
            failures += 1
            schedule(after: min(60, 10 * Double(failures)))
            return
        }
        failures = 0
        installObserver(snapshot)
        var readings: [String: NotificationBadgeCache.Reading] = [:]
        for item in snapshot.items {
            let value = item.label.map(NotificationBadgeCache.Reading.value) ?? .unavailable
            // 相同 bundle 的多份应用若徽章不同，不能任意选其中一份覆盖。
            if let previous = readings[item.bundleID], previous != value { readings[item.bundleID] = .unavailable }
            else { readings[item.bundleID] = value }
        }
        let changed = cache.merge(readings, complete: snapshot.complete)
        if changed {
            lock.lock(); published = cache.labels; lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dockNotificationBadgesChanged, object: nil)
            }
        }
        unchanged = changed ? 0 : unchanged + 1
        schedule(after: unchanged < 3 ? 5 : (unchanged < 8 ? 15 : 30))
    }

    /// 只注册已暴露的 AX 项目；不支持通知时仍由退避读保底，Dock PID 变化后重建。
    private func installObserver(_ snapshot: DockBadgeReader.Snapshot) {
        let elements = [snapshot.list] + snapshot.items.map(\.element)
        if observedPID == snapshot.pid, observedElements == elements { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = snapshot.pid
        observedElements = elements
        var fresh: AXObserver?
        guard AXObserverCreate(snapshot.pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<NotificationBadgeStore>.fromOpaque(context).takeUnretainedValue().notified()
        }, &fresh) == .success, let fresh else { return }
        let context = Unmanaged.passUnretained(self).toOpaque() // 单例与应用同寿命。
        for element in elements {
            for name in ["AXValueChanged", "AXTitleChanged", "AXStatusLabelChanged", "AXChildrenChanged"] {
                _ = AXObserverAddNotification(fresh, element, name as CFString, context)
            }
        }
        observer = fresh
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(fresh), .commonModes)
    }
}
