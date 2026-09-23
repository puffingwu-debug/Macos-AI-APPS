import SwiftUI

/// Visual language for the widget: a macOS app-icon surface.
enum Theme {
    static let codex = Color(red: 0.06, green: 0.64, blue: 0.50)          // ChatGPT green
    static let deepseek = Color(red: 0.30, green: 0.42, blue: 1.00)       // DeepSeek blue
    static let warning = Color(red: 0.95, green: 0.65, blue: 0.15)
    static let danger = Color(red: 0.92, green: 0.30, blue: 0.28)
}

extension ProviderHealth {
    var tint: Color {
        switch self {
        case .ok: return Theme.codex
        case .loading: return .secondary
        case .stale: return Theme.warning
        case .failed: return Theme.danger
        }
    }

    var label: String {
        switch self {
        case .ok: return "实时"
        case .loading: return "加载中"
        case .stale(let text): return text
        case .failed(let text): return text
        }
    }
}

// MARK: - Icon surface

/// The surface used by macOS desktop widgets.
///
/// Measured from the system's own widgets on this machine (dark mode): a widget
/// body reads as roughly `mix(backdrop, rgb(28,28,30), 0.5)` — near-black glass
/// that still lets the wallpaper's hue through — finished with a crisp light
/// hairline. Three calibration points from a screenshot:
///
///     backdrop 0.217 → body 0.174   (battery)
///     backdrop 0.250 → body 0.192   (calendar)
///     backdrop 0.364 → body 0.298   (this widget, before calibration)
///
/// The tint is applied as an explicit overlay rather than relying on the
/// material's own light/dark variant. A material picks its variant from the
/// AppKit appearance, which in a borderless, transparent panel resolved to the
/// *light* one while the text resolved to dark — producing a milky grey card
/// instead of dark glass. An explicit overlay cannot drift like that.
struct WidgetSurface: View {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Dark mode darkens toward near-black; light mode lifts toward white.
    private var tint: Color {
        scheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.50)
    }

    /// The hairline is a real feature of the system widgets, not a subtlety.
    private var border: LinearGradient {
        scheme == .dark
            ? LinearGradient(
                colors: [.white.opacity(0.38), .white.opacity(0.22)],
                startPoint: .top, endPoint: .bottom)
            : LinearGradient(
                colors: [.black.opacity(0.10), .black.opacity(0.05)],
                startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        shape
            .fill(.regularMaterial)
            .overlay { shape.fill(tint) }
            .overlay {
                shape.strokeBorder(border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
    }
}

/// Thin separator, matching the hairlines inside the weather widget.
@MainActor
struct WidgetDivider: View {
    var vertical = true
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Subscription tier badge. Kept deliberately quiet — a tinted translucent
/// capsule reads as a label, where a glossy filled chip fought the widget surface.
@MainActor
struct PlanBadge: View {
    var plan: CodexPlan
    var font: CGFloat

    var body: some View {
        HStack(spacing: 2.5) {
            Image(systemName: plan.symbol)
                .font(.system(size: font - 0.5, weight: .bold))
                .foregroundStyle(Theme.codex)
            Text(plan.badgeText)
                .font(.system(size: font, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background {
            Capsule().fill(Theme.codex.opacity(0.22))
        }
        .overlay {
            Capsule().strokeBorder(Theme.codex.opacity(0.45), lineWidth: 0.6)
        }
        .help(tooltip)
        .fixedSize()
    }

    private var tooltip: String {
        var parts = ["会员等级：\(plan.displayName)"]
        if let name = plan.accountName { parts.append(name) }
        // The claim is a snapshot from when the token was issued; showing an
        // already-expired date would just be confusing.
        if let until = plan.activeUntil, until > Date() {
            parts.append("有效期至 \(Fmt.shortDateTime(until))")
        }
        if let source = plan.source { parts.append("来源：\(source)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Small parts

/// Coloured dot + caption used in card headers.
@MainActor
struct StatusPill: View {
    var health: ProviderHealth
    var font: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(health.tint)
                .frame(width: 5.5, height: 5.5)
            Text(health.label)
                .font(.system(size: font, weight: .medium))
                .foregroundStyle(health.tint)
                .lineLimit(1)
        }
    }
}

/// Label/value row used inside cards.
@MainActor
struct StatRow: View {
    var label: String
    var value: String
    var font: CGFloat
    var accent: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: font))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: font, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Horizontal bar used for secondary windows / token split.
@MainActor
struct MiniBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Seven-day token trend: one bar per day, tallest day normalised to full height.
@MainActor
struct TrendStrip: View {
    var days: [DayUsage]
    var tint: Color
    var height: CGFloat = 28

    private var peak: Int { max(1, days.map(\.usage.total).max() ?? 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, entry in
                let isToday = index == days.count - 1
                let ratio = Double(entry.usage.total) / Double(peak)
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isToday ? tint : tint.opacity(0.32))
                        .frame(height: max(2, (height - 10) * ratio))
                    Text(dayLabel(entry.day))
                        .font(.system(size: 7))
                        .foregroundStyle(isToday ? .secondary : .tertiary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Fmt.grouped(entry.usage.total)) tokens")
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "d"
        return f.string(from: date)
    }
}

/// Tiny borderless icon button.
@MainActor
struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 20
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.22 : 0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.30 : 0.12), lineWidth: 0.6)
                }
                .foregroundStyle(.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
