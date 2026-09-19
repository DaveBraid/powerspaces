// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// macOS 27 的离屏全屏窗口兼容路径；仅在 ScreenCaptureKit 失败且已有屏幕录制权限时调用。
enum OffscreenWindowCapture {
    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// 按窗口 ID／PID 核对目标，动态探测旧公开截图接口；在工作线程缩小后只返回内存图像。
    static func capture(windowID: CGWindowID, pid: pid_t, width: Int, height: Int) -> CGImage? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              CGPreflightScreenCaptureAccess(), width > 0, height > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        func matchesOwner() -> Bool {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
            guard let row = rows?.first,
                  (row[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let rect = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return false }
            return bounds.width > 0 && bounds.height > 0 && bounds.width * bounds.height <= 16_000_000
        }
        guard matchesOwner() else { return nil } // 限制原始图像规模，拒绝已关闭或复用的窗口 ID。
        let capture = unsafeBitCast(symbol, to: Capture.self)
        guard let raw = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowID,
                                CGWindowImageOption.boundsIgnoreFraming.union(.nominalResolution).rawValue)?.takeRetainedValue(),
              matchesOwner(), let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() // 原始图像随函数退出释放，不保留截图缓存。
    }
}
