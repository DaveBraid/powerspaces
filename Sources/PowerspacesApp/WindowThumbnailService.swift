// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ScreenCaptureKit
import SpaceKit

/// 申请只由设置按钮触发；悬停仅检查权限，不弹系统授权框。
@MainActor enum PreviewPermission {
    /// 用户确认用途后才调用系统授权接口，不替用户切换权限。
    static func request() {
        guard Preferences.shared.windowPreviewEnabled else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Enable Screen Recording for window previews")
        alert.informativeText = L10n.string("Allow Powerspaces in System Settings → Privacy & Security → Screen Recording. This permission is only used for static window previews. You may need to restart Powerspaces after granting it.")
        alert.addButton(withTitle: L10n.string("Open System Settings"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 全局串行捕获：旧请求真正返回后才能启动新一轮，取消不增加并发。
@MainActor final class WindowThumbnailService {
    static let shared = WindowThumbnailService()
    typealias Completion = (CGWindowID, String?, NSImage?, String?) -> Void
    private struct Job {
        let windows: [WindowInfo]
        let allowOffscreen: Bool
        let completion: Completion
    }
    private var worker: Task<Void, Never>?
    private var pending: Job?

    /// 每次展开取一帧；共享全屏条目允许离屏捕获，普通条目保留可见性限制。
    func capture(_ windows: [WindowInfo], allowOffscreen: Bool = false, completion: @escaping Completion) {
        pending = Job(windows: windows, allowOffscreen: allowOffscreen, completion: completion)
        worker?.cancel()
        startNext()
    }

    /// 不保存图片；取消后丢弃尚未返回的系统捕获结果。
    func cancel() {
        pending = nil
        worker?.cancel()
    }

    /// 旧捕获完成后串行取最新会话，空闲时不保留计时器。
    private func startNext() {
        guard worker == nil, let job = pending else { return }
        pending = nil
        worker = Task { [weak self] in
            await self?.run(job)
            self?.worker = nil
            self?.startNext()
        }
    }

    /// 使用窗口 ID 与 PID 双重关联；总像素预算约 800 万，单张不超过 440×280。
    private func run(_ job: Job) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !Task.isCancelled else { return }
            let budget = min(440.0 * 280, 8_000_000.0 / Double(max(1, job.windows.count)))
            for info in job.windows {
                guard !Task.isCancelled else { return }
                guard let window = content.windows.first(where: {
                    $0.windowID == info.windowID && $0.owningApplication?.processID == info.pid
                }) else {
                    job.completion(info.windowID, nil, nil, "Window preview unavailable")
                    continue
                }
                guard !info.isMinimized, !info.isHidden else {
                    job.completion(info.windowID, window.title, nil, "Window is minimized or hidden")
                    continue
                }
                guard window.isOnScreen || job.allowOffscreen else {
                    job.completion(info.windowID, window.title, nil, "Window is on another desktop; click to focus")
                    continue
                }
                let width = max(1, window.frame.width), height = max(1, window.frame.height)
                let scale = min(1, 440 / width, 280 / height, sqrt(budget / (width * height)))
                let config = SCStreamConfiguration()
                config.width = max(1, Int(width * scale))
                config.height = max(1, Int(height * scale))
                config.showsCursor = false
                config.ignoreGlobalClipSingleWindow = job.allowOffscreen // 全屏所在 Space 不可见时仍保留完整窗口内容。
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    guard !Task.isCancelled else { return }
                    job.completion(info.windowID, window.title,
                                   NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    if job.allowOffscreen && !window.isOnScreen {
                        let outputWidth = config.width, outputHeight = config.height
                        let fallback = await Task.detached(priority: .utility) {
                            OffscreenWindowCapture.capture(windowID: info.windowID, pid: info.pid,
                                                           width: outputWidth, height: outputHeight)
                        }.value
                        guard !Task.isCancelled else { return }
                        if let fallback {
                            job.completion(info.windowID, window.title,
                                NSImage(cgImage: fallback, size: NSSize(width: fallback.width, height: fallback.height)), nil)
                            continue
                        }
                    }
                    job.completion(info.windowID, window.title, nil, "Window preview unavailable")
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            for window in job.windows {
                job.completion(window.windowID, nil, nil, "Window preview unavailable")
            }
        }
    }
}
