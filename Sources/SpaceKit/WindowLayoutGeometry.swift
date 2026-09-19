// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// 程序坞停靠的屏幕边。数值用于偏好与诊断输出，保持稳定。
public enum DockEdge: String, Sendable, CaseIterable {
    case bottom, top, left, right

    /// 该停靠方向下，预留带沿屏幕的哪条物理边。用于把预留量从物理边量起，
    /// 而不是叠加在系统 `visibleFrame` 已扣除的空间之上。
    public var isVertical: Bool { self == .left || self == .right }
}

/// 某块显示器上程序坞的静止（未放大）几何，用于推导窗口避让预留。
///
/// 预留量必须是「屏幕物理边 → 程序坞静止玻璃外沿」的距离；不能用程序坞面板的
/// `frame`（含悬停朝向屏幕内侧的余量），否则会多扣一段空间。
public struct DockReservation: Sendable, Equatable {
    public let displayID: UInt32
    public let edge: DockEdge
    /// 自屏幕物理边量起的预留厚度（点）。
    public let thickness: CGFloat
    /// 程序坞当前是否完全不占常驻空间（隐藏或模拟自动隐藏）；为真时不预留。
    public let isHiddenOrAutoHiding: Bool

    public init(displayID: UInt32, edge: DockEdge, thickness: CGFloat,
                isHiddenOrAutoHiding: Bool = false) {
        self.displayID = displayID
        self.edge = edge
        self.thickness = max(0, thickness)
        self.isHiddenOrAutoHiding = isHiddenOrAutoHiding
    }

    /// 实际生效的预留量；自动隐藏时不占常驻区域。
    public var effectiveThickness: CGFloat { isHiddenOrAutoHiding ? 0 : thickness }
}

/// 按显示器查询程序坞预留。由应用层注入，SpaceKit 不直接依赖面板实现。
public protocol DockReservationProviding: AnyObject {
    /// 查询指定显示器的预留；无程序坞时返回 nil。
    func reservation(forDisplayID displayID: UInt32) -> DockReservation?
}

/// 可接管的单窗口布局命令。
public enum WindowLayoutCommand: String, Sendable, CaseIterable {
    case fill
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    /// 还原到接管前的尺寸与位置。
    case restore
}

/// 一块屏幕的 AX 坐标几何。AX 坐标原点在主屏左上角、y 向下。
public struct WindowLayoutScreen: Sendable, Equatable {
    /// 屏幕物理边界（AX 坐标）。
    public let frame: CGRect
    /// 系统可用区域（AX 坐标），已扣除系统 Dock 与菜单栏。
    public let visibleFrame: CGRect
    public let displayID: UInt32
    public let reservation: DockReservation?

    public init(frame: CGRect, visibleFrame: CGRect, displayID: UInt32,
                reservation: DockReservation?) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displayID = displayID
        self.reservation = reservation
    }

    /// 允许窗口使用的区域：系统可用区域再去掉程序坞预留带。
    ///
    /// 关键点：预留带从**屏幕物理边**量起，且只扣除系统尚未扣除的部分，
    /// 避免与 `visibleFrame` 重复扣减（实测主屏曾因此多扣 61pt）。
    public var allowedFrame: CGRect {
        var allowed = visibleFrame
        guard let reservation, reservation.effectiveThickness > 0 else { return allowed }
        // 系统可用区已为 macOS 自己的 Dock / 菜单栏留出空间；PowerSpaces 的程序坞
        // 往往就停在系统 Dock 所占的同一块区域上。这里只扣除**系统尚未扣除**的部分，
        // 否则会把同一段空间扣两次（实测主屏曾因此多扣 61pt，窗口离程序坞过远）。
        let reservedTop = visibleFrame.minY - frame.minY
        let reservedBottom = frame.maxY - visibleFrame.maxY
        let reservedLeft = visibleFrame.minX - frame.minX
        let reservedRight = frame.maxX - visibleFrame.maxX
        switch reservation.edge {
        case .bottom:
            let extra = reservation.effectiveThickness - reservedBottom
            if extra > 0 { allowed.size.height = max(0, allowed.height - extra) }
        case .top:
            let extra = reservation.effectiveThickness - reservedTop
            if extra > 0 {
                allowed.origin.y += extra
                allowed.size.height = max(0, allowed.height - extra)
            }
        case .left:
            let extra = reservation.effectiveThickness - reservedLeft
            if extra > 0 {
                allowed.origin.x += extra
                allowed.size.width = max(0, allowed.width - extra)
            }
        case .right:
            let extra = reservation.effectiveThickness - reservedRight
            if extra > 0 { allowed.size.width = max(0, allowed.width - extra) }
        }
        return allowed
    }

    /// 按命令切分允许区域，得到窗口目标矩形。
    public func target(for command: WindowLayoutCommand) -> CGRect? {
        var target = allowedFrame
        guard target.width > 0, target.height > 0 else { return nil }
        switch command {
        case .fill:
            break
        case .left:
            target.size.width /= 2
        case .right:
            target.origin.x += target.width / 2
            target.size.width /= 2
        case .top:
            target.size.height /= 2
        case .bottom:
            target.origin.y += target.height / 2
            target.size.height /= 2
        case .topLeft:
            target.size.width /= 2
            target.size.height /= 2
        case .topRight:
            target.origin.x += target.width / 2
            target.size.width /= 2
            target.size.height /= 2
        case .bottomLeft:
            target.origin.y += target.height / 2
            target.size.width /= 2
            target.size.height /= 2
        case .bottomRight:
            target.origin.x += target.width / 2
            target.origin.y += target.height / 2
            target.size.width /= 2
            target.size.height /= 2
        case .restore:
            return nil  // 还原目标来自快照，不由几何推导。
        }
        // 过小的目标没有意义，交给原操作处理。
        guard target.width > 160, target.height > 160 else { return nil }
        return target
    }
}

/// 窗口身份：`pid:windowID`。不使用 `launchDate` —— 实测它对部分进程恒为 nil
/// （Finder 全生命周期为 nil），把它作为前置条件会让这些应用完全无法接管。
public struct WindowIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let windowID: CGWindowID

    public init(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid
        self.windowID = windowID
    }

    /// 供日志与诊断使用的稳定字符串。
    public var logDescription: String { "\(pid):\(windowID)" }
}
