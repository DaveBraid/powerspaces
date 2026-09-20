// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// 预览只复用 DockModel 的桌面／显示器归属，不从截图服务推断窗口所属桌面。
public enum WindowPreview {
    /// 用相同快照与显示器范围筛选目标进程，返回稳定排序的当前桌面窗口。
    ///
    /// 除当前桌面的窗口外，还包含该进程**全屏**的窗口：全屏在 macOS 里独占一个 Space，
    /// 若只按当前桌面筛选，pin 住的应用（其全屏窗口不会出现在全屏分区）悬停时会得到空列表，
    /// 于是显示成"不在此桌面"——实际上窗口就在那里。`fullscreenSpaceIDs` 由调用方注入，
    /// 假数据测试因此不必伪造系统接口。
    public static func windows(pid: pid_t, bundleID: String?, snapshot: SpaceSnapshot,
                               display: DisplaySpaceInfo, allDisplays: [CGRect],
                               fullscreenSpaceIDs: Set<SpaceID> = []) -> [WindowInfo] {
        let currentIDs = Set(DockModel.apps(onDisplay: display.bounds, snapshot: snapshot,
            visibleSpace: display.currentSpaceID, allDisplays: allDisplays)
            .filter { $0.pid == pid && (bundleID == nil || $0.bundleID == bundleID) }
            .flatMap(\.windowIDs))
        return snapshot.windows.filter { window in
            guard window.pid == pid else { return false }
            if let bundleID, let windowBundle = window.bundleID, windowBundle != bundleID { return false }
            if currentIDs.contains(window.windowID) { return true }
            // 全屏窗口：属于全屏 Space 即纳入预览。
            return !fullscreenSpaceIDs.isDisjoint(with: window.spaceIDs)
        }
        .sorted { $0.windowID < $1.windowID }
    }

    /// 该窗口是否处于全屏 Space；用于预览卡片上的全屏标记与点击行为。
    public static func isFullscreen(_ window: WindowInfo,
                                    fullscreenSpaceIDs: Set<SpaceID>) -> Bool {
        !fullscreenSpaceIDs.isDisjoint(with: window.spaceIDs)
    }
}

extension Launcher {
    /// 在启动工作队列读取新快照；桌面已切换则拒绝返回过时窗口。
    public func previewWindows(pid: pid_t, bundleID: String?, displayUUID: String,
                               spaceUUID: String, includeHidden: Bool) throws -> [WindowInfo] {
        let displays = provider.displays()
        guard let display = displays.first(where: { $0.displayUUID == displayUUID }),
              display.currentSpaceUUID == spaceUUID else { return [] }
        let raw = try provider.snapshot()
        let snapshot = includeHidden ? raw : raw.droppingHiddenWindows()
        return WindowPreview.windows(pid: pid, bundleID: bundleID, snapshot: snapshot,
                                     display: display, allDisplays: displays.map(\.bounds),
                                     fullscreenSpaceIDs: provider.fullscreenSpaceIDs())
    }

    /// 点击预览只聚焦，绝不走“已前台则最小化”的 Dock 点击切换规则。
    @discardableResult
    public func focusPreviewWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget,
                                   displayUUID: String, spaceUUID: String) throws -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility permission to focus this window.")
        }
        // 全屏窗口不在当前桌面：走允许切换 Space 的路径（与共享全屏分区一致）。
        if try fullscreenWindow(windowID: windowID, pid: pid, target: target) != nil {
            return try focusFullscreenWindow(windowID: windowID, pid: pid, target: target)
        }
        let current = try previewWindows(pid: pid, bundleID: target.bundleID, displayUUID: displayUUID,
                                         spaceUUID: spaceUUID, includeHidden: true)
        guard current.contains(where: { $0.windowID == windowID }),
              WindowAX.axWindow(windowID: windowID, pid: pid) != nil else {
            return warned(target, "this window is no longer available on this desktop.")
        }
        NSRunningApplication(processIdentifier: pid)?.unhide()
        guard raise(windowID: windowID, pid: pid, requireExactWindow: true) else {
            return warned(target, "could not focus this window.")
        }
        return .focused
    }
}

extension Launcher {
    /// 共享全屏条目只读取指定窗口，重新核对 PID、应用标识及全屏 Space，拒绝过时条目。
    public func fullscreenWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget) throws -> WindowInfo? {
        let snapshot = try provider.snapshot()
        let spaces = provider.fullscreenSpaceIDs()
        return snapshot.windows.first {
            $0.windowID == windowID && $0.pid == pid && target.matches($0)
                && !spaces.isDisjoint(with: $0.spaceIDs)
        }
    }

    /// 用户明确点击共享全屏窗口时允许切换到它所在的 Space，复用精确置顶，不最小化或重开应用。
    public func focusFullscreenWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget) throws -> LaunchOutcome {
        guard WindowAX.isTrusted else { return warned(target, "needs Accessibility permission to focus this window.") }
        guard try fullscreenWindow(windowID: windowID, pid: pid, target: target) != nil else {
            return warned(target, "This full-screen window is no longer available.")
        }
        NSRunningApplication(processIdentifier: pid)?.unhide()
        guard let window = WindowAX.fullscreenWindow(windowID: windowID, pid: pid),
              raise(windowID: windowID, pid: pid, requireExactWindow: true, knownWindow: window) else {
            return warned(target, "could not focus this window.")
        }
        return .focused
    }
}
