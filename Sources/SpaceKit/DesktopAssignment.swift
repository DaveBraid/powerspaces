// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// PS 移窗后的持久分配：同步原生 Dock 的 UUID 记录与 WindowServer 的会话绑定。
public enum DesktopAssignment {
    public enum AssignmentError: Error { case unavailable, invalidDesktop, invalidPreferences, saveFailed }
    private static let lock = NSLock() // 手动启动队列与自动移窗不能同时覆盖字典。
    private static var domain: CFString { "com.apple.spaces" as CFString }
    private static var key: CFString { "app-bindings" as CFString }
    private typealias SetBindings = @convention(c) (Int32, CFDictionary) -> Int32
    private static let setBindings: SetBindings? = {
        // 参数布局与冷启动行为仅在 macOS 27 验证；其他版本保留原有移窗能力。
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSSessionSetCurrentSessionWorkspaceApplicationBindings") else { return nil }
        return unsafeBitCast(symbol, to: SetBindings.self)
    }()

    /// 仅替换目标应用，统一大小写；保留其他应用和未知桌面的原始记录。
    public static func replacing(_ bindings: [String: String], bundleID: String, uuid: String) -> [String: String] {
        var result = bindings.filter { $0.key.caseInsensitiveCompare(bundleID) != .orderedSame }
        result[bundleID.lowercased()] = uuid
        return result
    }

    /// 按 Dock 的规则把稳定 UUID 转成当前 Space ID；AllSpaces 对应 Sticky，失效 UUID 不注入会话。
    public static func sessionBindings(_ bindings: [String: String], spaces: [SpaceID: String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (bundle, uuid) in bindings {
            if uuid == "AllSpaces" { result[bundle] = "Sticky" }
            else if let id = spaces.first(where: { $0.value == uuid })?.key { result[bundle] = NSNumber(value: id) }
        }
        return result
    }

    /// 输入应用和目标桌面；保存并同步会话，失败抛错，不重启 Dock、不另建竞争的分配文件。
    public static func remember(bundleID: String, spaceID: SpaceID, provider: CGSSpaceProvider) throws {
        guard let setBindings else { throw AssignmentError.unavailable }
        let spaces = provider.spaceUUIDs()
        guard !bundleID.isEmpty, let uuid = spaces[spaceID], UUID(uuidString: uuid) != nil,
              !provider.fullscreenSpaceIDs().contains(spaceID) else { throw AssignmentError.invalidDesktop }
        lock.lock()
        defer { lock.unlock() }
        guard CFPreferencesAppSynchronize(domain) else { throw AssignmentError.saveFailed }
        let raw = CFPreferencesCopyAppValue(key, domain)
        guard raw == nil || raw is [String: String] else { throw AssignmentError.invalidPreferences }
        let old = raw as? [String: String] ?? [:]
        let updated = replacing(old, bundleID: bundleID, uuid: uuid)
        CFPreferencesSetAppValue(key, updated as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain),
              (CFPreferencesCopyAppValue(key, domain) as? [String: String]) == updated,
              setBindings(CGSMainConnectionID(), sessionBindings(updated, spaces: spaces) as CFDictionary) == 0 else {
            // 仅恢复本应用，避免回滚期间覆盖其他应用刚更新的绑定。
            if let latest = CFPreferencesCopyAppValue(key, domain) as? [String: String] {
                var restored = latest.filter { $0.key.caseInsensitiveCompare(bundleID) != .orderedSame }
                for (name, value) in old where name.caseInsensitiveCompare(bundleID) == .orderedSame {
                    restored[name] = value
                }
                CFPreferencesSetAppValue(key, restored as CFDictionary, domain)
                CFPreferencesAppSynchronize(domain)
            }
            throw AssignmentError.saveFailed
        }
    }
}
