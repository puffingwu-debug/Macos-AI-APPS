import Foundation
import SwiftUI

/// 展示层的时间/文本格式化。
enum TimeText {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    /// 「今天 18:00」/「明天 09:00」/「3月5日 14:00」
    static func deadline(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                          to: calendar.startOfDay(for: date)).day ?? 0
        if days > 1 && days < 7 { return "\(days) 天后 \(time)" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return "\(dayFormatter.string(from: date)) \(time)"
        }
        return fullFormatter.string(from: date)
    }

    /// 「3 分钟前」/「2 小时前」/「3 天前」
    static func relative(_ millis: Int64) -> String {
        let seconds = max(0, Date.currentMillis - millis) / 1000
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        if seconds < 86_400 * 30 { return "\(seconds / 86_400) 天前" }
        return dayFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    /// 剩余时间提示：「还有 3 小时」/「已逾期」
    static func remaining(_ millis: Int64) -> String {
        let delta = millis - Date.currentMillis
        if delta < 0 { return "已逾期" }
        let minutes = delta / 60_000
        if minutes < 60 { return "还有 \(max(1, minutes)) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "还有 \(hours) 小时" }
        return "还有 \(hours / 24) 天"
    }
}

/// 配色（与小程序端保持一致：主色微信绿，优先级 红/蓝/灰）。
enum Palette {
    static let accent = Color(red: 0.04, green: 0.76, blue: 0.38)
    static let high = Color(red: 0.98, green: 0.31, blue: 0.29)
    static let normal = Color(red: 0.22, green: 0.56, blue: 0.98)
    static let low = Color(red: 0.62, green: 0.64, blue: 0.68)
    static let warning = Color(red: 0.98, green: 0.66, blue: 0.16)

    static func color(for priority: TodoPriority) -> Color {
        switch priority {
        case .high: return high
        case .normal: return normal
        case .low: return low
        }
    }

    static func color(for kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return accent
        case .warning: return warning
        case .error: return high
        }
    }
}
