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

/// 程序坞几何的纯计算：把「面板 / 玻璃 / 屏幕」三组矩形换算成避让预留与纠正结果。
///
/// 抽成纯函数是为了能对四个停靠方向做确定性自检——这些公式在只测底部时
/// 曾漏掉三个方向相关的缺陷（左右公式写反、越界判据只判竖向、顶部未收高度）。
public enum DockGeometry {

    /// 由窗口服务器报告的面板边界与玻璃在面板内的位置，推算自屏幕物理边量起的预留厚度。
    ///
    /// 玻璃贴面板外侧，多出的留白在内侧；因此内沿 = 面板外沿 + 内侧留白，
    /// 而不是面板外沿本身（直接用外沿会多留一段看不到东西的空隙）。
    public static func reserveThickness(panel: CGRect, glassInPanel: CGRect,
                                        screenFrame: CGRect, primaryHeight: CGFloat,
                                        edge: DockEdge) -> CGFloat {
        // 预留 = 屏幕物理边 → **可见玻璃内沿**。
        //
        // 面板比玻璃大，多出的留白在内侧，因此必须从面板外沿往内量：
        //   内沿 = 面板外沿 + (面板长度 − 玻璃长度 − 玻璃在该轴上的偏移)
        // 这个关系由四个方向的实机像素测量反推得到（底部 872 / 左侧 176 /
        // 右侧 1163 / 顶部 156，均与可见玻璃边缘逐像素对齐），
        // 不做「偏移取最小值」之类的推广——实测表明玻璃视图 frame 在方向之间
        // 参考边不一致，推广会算错（曾把底部算成 911、右侧算成 137、顶部算成 39）。
        let inset = { (panelLength: CGFloat, glassLength: CGFloat, offset: CGFloat) -> CGFloat in
            max(0, panelLength - glassLength - offset)
        }
        let screenTop = primaryHeight - screenFrame.maxY
        let screenBottom = primaryHeight - screenFrame.minY
        let glassTop = panel.minY + inset(panel.height, glassInPanel.height, glassInPanel.minY)
        let glassBottom = panel.maxY - inset(panel.height, glassInPanel.height, glassInPanel.minY)
        let glassLeft = panel.minX + inset(panel.width, glassInPanel.width, glassInPanel.minX)
        let glassRight = panel.maxX - inset(panel.width, glassInPanel.width, glassInPanel.minX)
        switch edge {
        case .bottom: return max(0, screenBottom - glassTop)
        case .top: return max(0, glassBottom - screenTop)
        case .left: return max(0, glassRight - screenFrame.minX)
        case .right: return max(0, screenFrame.maxX - glassLeft)
        }
    }
}

/// 外部改尺寸后的纠正结果。
public struct LayoutCorrection: Sendable, Equatable {
    /// 纠正后的窗口矩形；nil 表示无需纠正（未越界、变小或纠正后会超出可用区）。
    public let target: CGRect?
    /// 是否因「变大」触发的纠正（变小与移动不纠正）。
    public let grew: Bool

    public init(target: CGRect?, grew: Bool) {
        self.target = target
        self.grew = grew
    }
}

public enum WindowLayoutCorrection {

    /// 外部改尺寸（第三方最大化、Option＋拖动）后的纠正：只有**变大导致的越界**才动窗口。
    ///
    /// 越界方向取决于停靠边，且左右两侧看的边界不同——左侧坞的预留带在屏幕左边，
    /// 右边界本就等于可用区右边界，因此要看 `minX`；右侧坞相反。顶部坞下移时必须
    /// 同时收高度，否则底边会超出屏幕。
    public static func correction(current: CGRect, allowed: CGRect, edge: DockEdge,
                                  previous: CGRect?, tolerance: CGFloat = 4,
                                  minimumSize: CGFloat = 160) -> LayoutCorrection {
        let grew: Bool
        if let previous {
            grew = current.height > previous.height + 1 || current.width > previous.width + 1
        } else {
            grew = true
        }
        guard grew else { return LayoutCorrection(target: nil, grew: false) }

        var target = current
        switch edge {
        case .bottom:
            guard current.maxY > allowed.maxY + tolerance else {
                return LayoutCorrection(target: nil, grew: true)
            }
            // 高度必须收进可用区，否则整屏高的窗口纠正后会顶出屏幕。
            target.size.height = min(current.height, allowed.height)
            target.origin.y = allowed.maxY - target.height
        case .top:
            guard current.minY < allowed.minY - tolerance else {
                return LayoutCorrection(target: nil, grew: true)
            }
            target.origin.y = allowed.minY
            target.size.height = min(current.height, allowed.height)
        case .left:
            guard current.minX < allowed.minX - tolerance else {
                return LayoutCorrection(target: nil, grew: true)
            }
            // 宽度同理：整屏宽的窗口在左右停靠时必须一起收窄，否则只平移仍会越界。
            // 同时要把纵向也收进可用区（整屏高的窗口上边界在允许区之上）。
            target.size.width = min(current.width, allowed.width)
            target.size.height = min(current.height, allowed.height)
            target.origin.x = allowed.minX
            target.origin.y = max(current.minY, allowed.minY)
        case .right:
            guard current.maxX > allowed.maxX + tolerance else {
                return LayoutCorrection(target: nil, grew: true)
            }
            target.size.width = min(current.width, allowed.width)
            target.size.height = min(current.height, allowed.height)
            target.origin.x = allowed.maxX - target.width
            target.origin.y = max(current.minY, allowed.minY)
        }
        guard target.width > minimumSize, target.height > minimumSize,
              target.minX >= allowed.minX - 1, target.minY >= allowed.minY - 1 else {
            return LayoutCorrection(target: nil, grew: true)
        }
        return LayoutCorrection(target: target, grew: true)
    }
}
