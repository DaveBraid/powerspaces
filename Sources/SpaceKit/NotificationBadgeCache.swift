// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// 应用级徽章缓存：保留原文，读取失败保持旧值，明确空值才清除。
public struct NotificationBadgeCache: Sendable {
    public enum Reading: Equatable, Sendable {
        case value(String)
        case unavailable
    }
    public private(set) var labels: [String: String] = [:]
    public init() {}

    /// 合并一次快照；只有身份列表完整时，才清除已从系统 Dock 消失的应用。
    @discardableResult public mutating func merge(_ readings: [String: Reading]?, complete: Bool) -> Bool {
        guard let readings else { return false }
        let previous = labels
        if complete { labels = labels.filter { readings[$0.key] != nil } }
        for (identity, reading) in readings {
            if case let .value(label) = reading {
                if label.isEmpty { labels.removeValue(forKey: identity) }
                else { labels[identity] = label }
            }
        }
        return previous != labels
    }
}
