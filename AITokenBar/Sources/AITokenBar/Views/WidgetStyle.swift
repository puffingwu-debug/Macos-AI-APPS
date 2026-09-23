import SwiftUI
import AppKit

/// How much of the widget to show. Drives every dimension in the UI so the
/// three sizes look deliberate rather than merely scaled.
enum WidgetDensity: String, CaseIterable, Identifiable, Sendable {
    case mini
    case compact
    case full

    var id: String { rawValue }

    /// Global size trim applied to every metric below, so the whole widget scales
    /// as one unit. 0.95 = 5% smaller.
    static let trim: CGFloat = 0.95
    private func t(_ value: CGFloat) -> CGFloat { value * Self.trim }

    var title: String {
        switch self {
        case .mini: return "迷你（一行）"
        case .compact: return "精简"
        case .full: return "完整"
        }
    }

    var blurb: String {
        switch self {
        case .mini: return "只显示剩余百分比、重置倒计时与余额"
        case .compact: return "额度环 + 倒计时 + 余额与今日用量"
        case .full: return "额外显示 7 天趋势与 token 明细"
        }
    }

    // MARK: - Geometry

    var width: CGFloat {
        switch self {
        case .mini: return t(208)
        case .compact: return t(360)
        case .full: return t(360)
        }
    }

    /// Icon-style squircle radius. macOS app icons use ~22% of the icon width;
    /// the widget lands between that and the tighter Notification Center widget
    /// ratio so tall cards do not turn into pills.
    var cornerRadius: CGFloat {
        switch self {
        // System desktop widgets sit around a 22–26 pt radius at these widths.
        case .mini: return t(15)
        case .compact: return t(26)
        case .full: return t(26)
        }
    }

    var outerPadding: CGFloat {
        switch self {
        case .mini: return t(9)
        case .compact: return t(14)
        case .full: return t(16)
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .mini: return t(5)
        case .compact: return t(9)
        case .full: return t(10)
        }
    }

    /// Space between the two provider columns and around their divider.
    var columnGap: CGFloat {
        switch self {
        case .mini: return t(6)
        case .compact: return t(12)
        case .full: return t(14)
        }
    }

    // MARK: - Type

    var headerFont: CGFloat {
        switch self {
        case .mini: return t(11)
        case .compact: return t(17.5)
        case .full: return t(19)
        }
    }

    var bodyFont: CGFloat {
        switch self {
        case .mini: return t(10)
        case .compact: return t(12)
        case .full: return t(13)
        }
    }

    var detailFont: CGFloat {
        switch self {
        case .mini: return t(8.5)
        case .compact: return t(11)
        case .full: return t(11.5)
        }
    }

    var heroFont: CGFloat {
        switch self {
        case .mini: return t(14)
        case .compact: return t(29)
        case .full: return t(32)
        }
    }

    /// Provider glyph size (SF Symbol), matching the small symbols system widgets use.
    var symbolSize: CGFloat {
        switch self {
        case .mini: return t(13)
        case .compact: return t(16)
        case .full: return t(17)
        }
    }

    // MARK: - Content

    var showsCards: Bool { self != .mini }
    var showsDetails: Bool { self == .full }
    var showsSubtitle: Bool { self != .mini }

    var tileSize: CGFloat {
        switch self {
        case .mini: return t(16)
        case .compact: return t(18)
        case .full: return t(19)
        }
    }

    /// Distance kept from the screen edge when snapping.
    var snapInset: CGFloat { 8 }
}

/// Where the widget sits relative to other windows.
enum WidgetLevel: String, CaseIterable, Identifiable, Sendable {
    /// Behind normal windows, resting on the desktop like a desktop widget.
    case desktop
    /// Floating above everything (default).
    case floating
    /// Ordinary window level.
    case normal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "贴在桌面（会被窗口遮挡）"
        case .floating: return "浮动置顶"
        case .normal: return "普通窗口层级"
        }
    }

    var shortTitle: String {
        switch self {
        case .desktop: return "桌面"
        case .floating: return "置顶"
        case .normal: return "普通"
        }
    }

    var nsLevel: NSWindow.Level {
        switch self {
        case .desktop:
            // Just above the desktop icons, below every ordinary window.
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .floating:
            return .floating
        case .normal:
            return .normal
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .floating: return "pin.fill"
        case .normal: return "macwindow"
        }
    }
}
