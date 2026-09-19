// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

/// 预览只复用 DockModel 的桌面／显示器归属，不从截图服务推断窗口所属桌面。
public enum WindowPreview {
    /// 用相同快照与显示器范围筛选目标进程，返回稳定排序的当前桌面窗口。
    public static func windows(pid: pid_t, bundleID: String?, snapshot: SpaceSnapshot,
                               display: DisplaySpaceInfo, allDisplays: [CGRect]) -> [WindowInfo] {
        let ids = Set(DockModel.apps(onDisplay: display.bounds, snapshot: snapshot,
            visibleSpace: display.currentSpaceID, allDisplays: allDisplays)
            .filter { $0.pid == pid && (bundleID == nil || $0.bundleID == bundleID) }
            .flatMap(\.windowIDs))
        return snapshot.windows.filter { ids.contains($0.windowID) && $0.pid == pid }
            .sorted { $0.windowID < $1.windowID }
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
                                     display: display, allDisplays: displays.map(\.bounds))
    }

    /// 点击预览只聚焦，绝不走“已前台则最小化”的 Dock 点击切换规则。
    @discardableResult
    public func focusPreviewWindow(windowID: CGWindowID, pid: pid_t, target: AppTarget,
                                   displayUUID: String, spaceUUID: String) throws -> LaunchOutcome {
        guard WindowAX.isTrusted else {
            return warned(target, "needs Accessibility permission to focus this window.")
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
