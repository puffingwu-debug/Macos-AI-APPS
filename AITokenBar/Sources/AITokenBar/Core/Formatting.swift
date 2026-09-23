import Foundation

enum Fmt {
    /// 1234567 -> "1.23M", 12345 -> "12.3K", 999 -> "999"
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...:
            return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", v / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", v / 1_000)
        case 1_000...:
            return String(format: "%.2fK", v / 1_000)
        default:
            return "\(value)"
        }
    }

    static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func money(_ value: Double, currency: String = "CNY") -> String {
        let symbol = currency.uppercased() == "CNY" ? "¥" : (currency.uppercased() == "USD" ? "$" : "")
        return symbol + String(format: "%.2f", value)
    }

    static func signedMoney(_ value: Double, currency: String = "CNY") -> String {
        (value >= 0 ? "+" : "-") + money(abs(value), currency: currency)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func percent1(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// "3天 04:12:33" style countdown, degrading gracefully as it shrinks.
    static func countdown(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "即将重置" }
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 {
            return String(format: "%d天 %02d:%02d:%02d", days, hours, minutes, seconds)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// "09-30 12:00"
    static func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// "16:43:50"
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// "刚刚" / "3 分钟前" / "2 小时前"
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 0 { return "刚刚" }
        switch delta {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(Int(delta / 60)) 分钟前"
        case ..<86_400: return "\(Int(delta / 3_600)) 小时前"
        default: return "\(Int(delta / 86_400)) 天前"
        }
    }

    /// "1 天" / "5 小时"
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0 分钟" }
        if interval >= 86_400 { return String(format: "%.1f 天", interval / 86_400) }
        if interval >= 3_600 { return String(format: "%.0f 小时", interval / 3_600) }
        return String(format: "%.0f 分钟", interval / 60)
    }
}
