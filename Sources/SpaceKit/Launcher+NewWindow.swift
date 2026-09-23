// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// New-window strategies: the per-app dispatch (`newWindow`) and the multi-display
/// "land the fresh window on the screen the user is on" placement.
extension Launcher {
    func newWindow(_ target: AppTarget, kind: StrategyKind, snapshot: SpaceSnapshot,
                   preferredDisplay: CGRect? = nil, targetSpace: SpaceID? = nil) -> LaunchOutcome {
        // Windows of this app that already exist, so we can spot the one we're
        // about to create and make sure it opens on the screen the user is on
        // (and on the desktop the user is on — see `placeNewWindowHere`).
        let existing = Set(snapshot.windows(of: target).map(\.windowID))
        switch kind {
        case .newInstance:
            // Pick the route by whether the app owns a *real* window anywhere:
            //
            // • None — only spaceless phantoms, or nothing at all (the runningWindowless
            //   case: an Electron app like Claude after you ✕ its last window leaves an
            //   idle, window-less copy). Reuse that copy with `open -a` (no -n): it
            //   reactivates the existing instance and its reopen handler makes a window,
            //   which lands on the current Space because there's no other window to pull
            //   focus elsewhere. Spawning a `-n` instance here instead would orphan the
            //   ghost and stack up processes — the Claude pile-up bug.
            //
            // • A real window on another desktop (windowElsewhere), or `forceNew` over a
            //   here-window (both have a real window). Activating would yank us to that
            //   window's Space, so launch a fresh instance in the *background*
            //   (`open -n -g`); `focus` below raises just the new window, which is on the
            //   current Space, so focusing it never switches desktops. This is the
            //   no-yank, no-SIP fix for apps that keep windows on other desktops.
            let hasRealWindow = !snapshot.realWindows(of: target).isEmpty
            openApp(target, newInstance: hasRealWindow, background: hasRealWindow)
            // Raise the fresh window, but for a *genuine second instance* (hasRealWindow:
            // the app already owns a window on another desktop) do NOT activate its
            // process. Activating a second Claude instance makes it hand off to the
            // primary and close the new window ~8 s later — "opens briefly then closes".
            // Raising via Accessibility brings the window forward without that trigger;
            // it's on the current Space, so it stays visible. The reuse path (a single
            // windowless instance) keeps activation — there's no duplicate to hand off to.
            let appeared = placeNewWindowHere(target, existing: existing,
                                              preferredDisplay: preferredDisplay,
                                              focus: true, activateApp: !hasRealWindow,
                                              targetSpace: targetSpace)
            return appeared ? .newWindow(.newInstance) : newWindowDidNotAppear(target)
        case .openArgs:
            openWithArgs(target, args: config.args(for: target.bundleID))
            let appeared = placeNewWindowHere(target, existing: existing,
                                              preferredDisplay: preferredDisplay, targetSpace: targetSpace)
            return appeared ? .newWindow(.openArgs) : newWindowDidNotAppear(target)
        case .appleScript:
            // Finder is special. After a "quit (all desktops)" macOS auto-relaunches
            // it and restores a stray window on whatever Space it was on (so it is
            // NOT window-less), then `make new Finder window` either lags or opens
            // the window onto that restored Space — not the one you're standing on.
            // The Apple event returns success either way, so the first dock click
            // flips the menu bar to Finder but lands no window here and you click
            // again. Use a route that reliably puts a window on the *current* Space
            // and wait for it to actually arrive.
            if target.bundleID == "com.apple.finder" {
                makeNewFinderWindowHere(target)
                return .newWindow(.appleScript)
            }
            let ran = config.appleScript(for: target.bundleID).map(runAppleScript) ?? false
            if !ran {
                // No script, or the app refused the Apple event — almost always
                // -1743 (errAEEventNotPermitted): powerspaces hasn't been granted
                // Automation control of the app, so `make new window` silently did
                // nothing. Without a fallback the activate below is all that fires:
                // the app shows in the menu bar, but no window appears. Recover via
                // a route that needs no Automation consent.
                appleScriptFallback(target)
            }
            activate(target)
            let appeared = placeNewWindowHere(target, existing: existing,
                                              preferredDisplay: preferredDisplay, targetSpace: targetSpace)
            return appeared ? .newWindow(.appleScript) : newWindowDidNotAppear(target)
        case .warn:
            return warned(target, "is already open on another desktop — switch desktops to use it.")
        case .quitReopen:
            return quitReopen(target)
        case .cmdN:
            activate(target)
            postCmdN()
            let appeared = placeNewWindowHere(target, existing: existing,
                                              preferredDisplay: preferredDisplay, targetSpace: targetSpace)
            return appeared ? .newWindow(.cmdN) : newWindowDidNotAppear(target)
        case .focusOnly:
            // No new window by design — just activate and accept the jump to the
            // app's Space, so there's nothing to detect or warn about here.
            activate(target)
            return .newWindow(.focusOnly)
        case .moveHere:
            return moveProcessHere(target: target, snapshot: snapshot,
                                   targetSpace: targetSpace ?? snapshot.activeSpaceID,
                                   preferredDisplay: preferredDisplay)
        }
    }

    /// A window-making strategy ("Open a new window") fired but no window ever
    /// appeared — the case the user hits with apps like GitHub Desktop, which
    /// quietly refuse a second window so the click looks dead. macOS gives us no
    /// reliable way to force a window for such single-instance apps, so rather than
    /// pretend it worked, warn and point the user at switching desktops. (If a given
    /// app never opens a window here, right-click → "When open elsewhere" →
    /// "Show a warning" silences the dead click.)
    func newWindowDidNotAppear(_ target: AppTarget) -> LaunchOutcome {
        warned(target, "is open on another desktop and “Open a new window” didn’t work for it — "
               + "switch desktops to use it.")
    }

    // MARK: - Land the fresh window on the current desktop

    /// After a new-window strategy fires, bring the fresh window onto the desktop
    /// the user is standing on.
    ///
    /// On a multi-display setup it moves the window onto the active (or
    /// `preferredDisplay`) screen: apps like Firefox open `--new-window` on
    /// whichever screen they last used, and macOS then files it under *that*
    /// display's Space, so it looks like the window jumped desktops.
    /// `preferredDisplay` (the bounds of the dock's display) overrides the default
    /// "active display" target, so clicking a given screen's dock opens the window
    /// on *that* screen even when the menu bar lives elsewhere.
    ///
    /// When `focus` is set it raises the fresh window forward. `activateApp`
    /// (default true) additionally makes the app frontmost; pass `false` for a
    /// freshly-spawned *second* instance that must be raised but not activated (see
    /// `raise`), so it isn't pulled to where the app's other windows live and — for a
    /// single-window app like Claude — isn't induced to hand off and close. Either way
    /// the window is on the current Space, so raising it never switches desktops.
    ///
    /// 只选本次新增的真实窗口；多屏时应用若先把它建在别的屏幕，先移动物理坐标，
    /// 再确认它落在点击程序坞的 Space。占位窗口（空 `spaceIDs`）始终跳过。
    ///
    /// Returns whether the strategy produced a window at all. `false` means no fresh
    /// window appeared anywhere within the timeout — the signal that "Open a new
    /// window" silently failed for this app (e.g. a single-instance app that refuses
    /// a second window), so the caller can warn instead of pretending it worked.
    @discardableResult
    func placeNewWindowHere(_ target: AppTarget, existing: Set<CGWindowID>,
                            preferredDisplay: CGRect? = nil, focus: Bool = false,
                            activateApp: Bool = true, targetSpace: SpaceID? = nil) -> Bool {
        let trusted = WindowAX.isTrusted
        let displays = trusted ? DisplayInfo.allDisplayBounds() : []
        let active = preferredDisplay ?? DisplayInfo.activeDisplayBounds()
        let needsMove = trusted && displays.count > 1 && active != nil
        var attemptedSpaceMoves: Set<CGWindowID> = []

        // 新进程可能先在另一个显示器的 Space 创建窗口；只按目标 Space 筛选会漏掉它。
        let placedHere = pollUntil(timeout: 3.0, interval: 80_000) {
            guard let snapshot = try? provider.snapshot() else { return false }
            let destination = targetSpace ?? snapshot.activeSpaceID
            let freshWindows = snapshot.realWindows(of: target).filter { !existing.contains($0.windowID) }
            guard let fresh = freshWindows.first(where: { $0.isOn(destination) }) ?? freshWindows.first else {
                return false
            }
            // Multi-display: move it onto the screen the user is on. A freshly-launched
            // window's Accessibility element lags the window-server list, so if we can't
            // read its frame yet, keep polling rather than abandoning the move (which
            // left a cold-launched app on the OS default screen, not the dock's screen).
            if needsMove, let active {
                guard let axWindow = WindowAX.axWindow(windowID: fresh.windowID, pid: fresh.pid),
                      let frame = WindowAX.frame(of: axWindow) else { return false }
                if let moved = DisplayPlacement.reposition(window: frame, displays: displays, active: active) {
                    WindowAX.setFrame(moved, of: axWindow)
                    guard let actual = WindowAX.frame(of: axWindow),
                          active.contains(CGPoint(x: actual.midX, y: actual.midY)) else { return false }
                }
            }
            if !fresh.isOn(destination) {
                // 新实例独占一个进程时才可使用进程级分配；不能搬走旧窗口。
                guard attemptedSpaceMoves.insert(fresh.windowID).inserted,
                      snapshot.realWindows(of: target).filter({ $0.pid == fresh.pid }).count == 1,
                      (try? WindowSpaceMover.assign(pid: fresh.pid, to: destination,
                                                    confirmedSpaces: { _ in
                          let current = try? provider.snapshot()
                          return Set(current?.windows(of: target)
                              .first(where: { $0.windowID == fresh.windowID })?.spaceIDs ?? [])
                      })) != nil else {
                    return false
                }
            }
            // Bring the new window forward (it's on the current Space → no yank).
            if focus { raise(windowID: fresh.windowID, pid: fresh.pid, activateApp: activateApp) }
            return true
        }
        if placedHere { return true }

        // Nothing reached the current Space within the timeout. On a multi-display
        // setup the app may still have opened the window on another screen's Space —
        // that counts as "worked", just placed elsewhere. Only when NO fresh window
        // exists anywhere did the strategy truly fail. If we can't read the window
        // world, assume success so we never warn spuriously.
        guard let snapshot = try? provider.snapshot() else { return true }
        let appeared = snapshot.realWindows(of: target).contains { !existing.contains($0.windowID) }
        if appeared, targetSpace != nil {
            _ = warned(target, "opened a window, but it could not be moved to this desktop.")
        }
        return appeared
    }

    // MARK: - Quit the app entirely, then relaunch on the current Space

    /// `quitReopen`: quit the whole app and relaunch it. A cold launch puts the new
    /// window on the current Space — the engine's normal "launch lands here"
    /// behaviour — so this is the one strategy that reliably brings a stubborn
    /// single-window app (System Settings and the like) to the desktop you're on.
    /// No Accessibility, no SIP. We only get here when the app has NO window on the
    /// current Space (decide() would have focused one otherwise), so quitting can't
    /// destroy a window the user is looking at — but it does drop the app's transient
    /// state, which is why it's opt-in and the UI confirms first.
    private func quitReopen(_ target: AppTarget) -> LaunchOutcome {
        guard let bundleID = target.bundleID else {
            openApp(target, newInstance: false)
            return .launched
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            openApp(target, newInstance: false)
            return .launched
        }
        for app in running { app.terminate() }
        // terminate() is async; wait for the process to actually exit (≤2 s) so the
        // relaunch is a true cold start whose window lands here — otherwise
        // `open -a` would just reactivate the dying instance and jump to its Space.
        pollUntil(timeout: 2.0, interval: 50_000) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .allSatisfy { $0.isTerminated }
        }
        openApp(target, newInstance: false)
        return .reopenedOnCurrentSpace
    }
}


extension Launcher {
    /// 把单实例应用**搬到现在这个桌面**再聚焦。
    ///
    /// 为什么这样做：单实例应用既不能新建实例，激活又必然把用户带到它的桌面。
    /// 搬移让「在这台桌面用它」成立，且不关闭应用、不丢状态（区别于 quitReopen）。
    ///
    /// 用进程级分配接口（Dock「分配给」同款）：已有窗口立即跟过来，后续新窗口也落在这里。
    /// 失败（接口缺失或系统未接受）时降级为警告，不静默把用户带走。
    func moveProcessHere(target: AppTarget, snapshot: SpaceSnapshot,
                         targetSpace: SpaceID, preferredDisplay: CGRect? = nil) -> LaunchOutcome {
        // 点击哪块屏幕的程序坞，就以该屏幕的可见桌面为目标；快照的 activeSpaceID 可能属于另一屏。
        let currentSpace = targetSpace
        let windows = snapshot.windows(of: target)
        if let here = windows.first(where: { $0.spaceIDs.contains(currentSpace) }) {
            // 同一应用可能同时在多个桌面有窗口；已有当前桌面窗口时只需聚焦它。
            return raise(windowID: here.windowID, pid: here.pid)
                ? .newWindow(.moveHere) : warned(target, "could not focus its window here.")
        }
        let elsewhere = windows.contains { window in
            !window.spaceIDs.isEmpty && !window.spaceIDs.contains(currentSpace)
        }
        guard elsewhere else {
            // 进程仍在、窗口已全部关闭：先覆盖旧桌面分配，再请求应用重新开窗。
            guard let concrete = provider as? CGSSpaceProvider,
                  let bundle = target.bundleID else {
                return warned(target, "could not be assigned to this desktop before reopening.")
            }
            do {
                try DesktopAssignment.remember(bundleID: bundle, spaceID: currentSpace, provider: concrete)
            } catch {
                return warned(target, "could not be assigned to this desktop before reopening.")
            }
            openApp(target, newInstance: false, background: true)
            let appeared = placeNewWindowHere(target, existing: Set(windows.map(\.windowID)),
                preferredDisplay: preferredDisplay, focus: true, targetSpace: currentSpace)
            return appeared ? .newWindow(.moveHere) : newWindowDidNotAppear(target)
        }
        guard let window = windows.first(where: { !$0.isMinimized && !$0.spaceIDs.isEmpty }) ?? windows.first,
              let provider = provider as? CGSSpaceProvider else {
            return warned(target, "could not be moved to this desktop.")
        }
        let assignmentSaved: Bool
        do {
            try WindowSpaceMover.assignAndRemember(pid: window.pid, to: currentSpace,
                                       confirmedSpaces: provider.spaces(forPID:))
            assignmentSaved = true
        } catch WindowSpaceMover.MoveError.assignmentNotSaved {
            assignmentSaved = false
        } catch WindowSpaceMover.MoveError.notMoved {
            // 少数应用把窗口锁在原屏幕的 Space；先移到目标屏幕，再重试进程归属。
            guard let preferredDisplay, WindowAX.isTrusted,
                  windows.filter({ $0.pid == window.pid && !$0.spaceIDs.isEmpty }).count == 1,
                  !provider.spaces(forPID: window.pid).contains(currentSpace),
                  let element = WindowAX.axWindow(windowID: window.windowID, pid: window.pid),
                  let original = WindowAX.frame(of: element),
                  let placed = DisplayPlacement.reposition(window: original,
                      displays: DisplayInfo.allDisplayBounds(), active: preferredDisplay) else {
                return warned(target, "could not be moved to this desktop.")
            }
            WindowAX.setFrame(placed, of: element)
            guard let actual = WindowAX.frame(of: element),
                  preferredDisplay.contains(CGPoint(x: actual.midX, y: actual.midY)) else {
                WindowAX.setFrame(original, of: element)
                return warned(target, "could not be moved to this desktop.")
            }
            do {
                try WindowSpaceMover.assignAndRemember(pid: window.pid, to: currentSpace,
                                           confirmedSpaces: provider.spaces(forPID:))
                assignmentSaved = true
            } catch WindowSpaceMover.MoveError.assignmentNotSaved {
                assignmentSaved = false
            } catch {
                WindowAX.setFrame(original, of: element)
                return warned(target, "could not be moved to this desktop.")
            }
        } catch {
            return warned(target, "could not be moved to this desktop.")
        }
        activate(target)
        // Space 更新快于 AX 窗口可操作状态；等窗口可访问后再调位置并置顶。
        let focused = WindowAX.isTrusted && pollUntil(timeout: 1.6, interval: 80_000) {
            guard let element = WindowAX.axWindow(windowID: window.windowID, pid: window.pid) else { return false }
            if let preferredDisplay, let frame = WindowAX.frame(of: element),
               let placed = DisplayPlacement.reposition(window: frame,
                   displays: DisplayInfo.allDisplayBounds(), active: preferredDisplay) {
                WindowAX.setFrame(placed, of: element)
            }
            return focusMovedWindow(windowID: window.windowID, pid: window.pid)
        }
        guard focused else { return warned(target, "was moved, but its window could not be focused.") }
        if !assignmentSaved {
            return warned(target, "was moved, but its desktop assignment could not be saved.")
        }
        return .newWindow(.moveHere)
    }
}
