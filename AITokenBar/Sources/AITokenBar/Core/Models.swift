import Foundation

// MARK: - Token accounting

/// Normalised token accounting shared by every provider.
///
/// Ingest rule: `input` is always *non-cached* input. Cached (cache-read) tokens are
/// reported separately in `cachedInput`, so `total` is comparable across providers
/// whose raw APIs disagree about whether cache hits are folded into the input count.
struct TokenUsage: Codable, Hashable, Sendable {
    var input: Int = 0
    var cachedInput: Int = 0
    var output: Int = 0
    /// Subset of `output`, tracked for display only.
    var reasoning: Int = 0
    /// Number of model requests observed, when the provider reports them.
    var requests: Int = 0

    var total: Int { input + cachedInput + output }
    var isEmpty: Bool { total == 0 && requests == 0 }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning,
            requests: lhs.requests + rhs.requests
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }

    /// Percentage of input tokens that were served from cache (0...100).
    var cacheHitRate: Double? {
        let denom = input + cachedInput
        guard denom > 0 else { return nil }
        return Double(cachedInput) / Double(denom) * 100
    }
}

// MARK: - Quota windows

/// One rate-limit window reported by a provider, e.g. Codex's weekly or 5-hour window.
struct QuotaWindow: Identifiable, Hashable, Sendable {
    /// Stable key, e.g. `primary` / `secondary` / `weekly`.
    let id: String
    /// Raw window length in minutes as reported by the provider.
    let windowMinutes: Int?
    let usedPercent: Double
    let resetsAt: Date?
    /// Human label resolved from `windowMinutes` (or supplied by the caller).
    let label: String

    var clampedUsedPercent: Double { min(max(usedPercent, 0), 100) }
    var remainingPercent: Double { max(0, 100 - clampedUsedPercent) }
    var isExhausted: Bool { clampedUsedPercent >= 99.999 }

    /// Time left until the window rolls over, or nil when the provider gave no reset time.
    func timeRemaining(from now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }

    static func label(forWindowMinutes minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        switch minutes {
        case 300: return "5 小时额度"
        case 1440: return "每日额度"
        case 10080: return "每周额度"
        case 43200: return "每月额度"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
            if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
            return "\(minutes) 分钟额度"
        }
    }
}

/// One day's token usage, used for the 7-day trend strip.
struct DayUsage: Hashable, Sendable, Identifiable {
    var day: Date
    var usage: TokenUsage
    var id: Date { day }
}

/// Extra-usage credits / pay-as-you-go balance attached to a subscription.
struct CreditInfo: Hashable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: Double?
}

// MARK: - Provider snapshots

enum ProviderHealth: Hashable, Sendable {
    case loading
    case ok
    case stale(String)
    case failed(String)
}

/// Everything the widget knows about ChatGPT / Codex usage.
struct CodexSnapshot: Hashable, Sendable {
    var windows: [QuotaWindow] = []
    var credits: CreditInfo?
    var planType: String?
    /// Resolved subscription tier (live endpoint → id_token → rollout logs).
    var plan = CodexPlan()
    var todayUsage = TokenUsage()
    var weekUsage = TokenUsage()
    /// Newest token_count event seen on disk — the freshness of the whole snapshot.
    var lastActivityAt: Date?
    var lastRateLimitAt: Date?
    /// Last 7 days, oldest first, for the trend strip.
    var recentDays: [DayUsage] = []
    var resetCount: Int = 0
    var lastResetAt: Date?
    var scannedFiles: Int = 0
    /// True when the quota windows came from the live endpoint rather than logs.
    var isLive: Bool = false
    var health: ProviderHealth = .loading
    var errorText: String?

    /// The window that determines "剩余 N%" — the tightest one, preferring the
    /// longest window when several are reported (matches the ChatGPT desktop app).
    var headlineWindow: QuotaWindow? {
        guard !windows.isEmpty else { return nil }
        return windows.max { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
    }
}

/// Figures read from DeepSeek's own usage dashboard (via the private platform
/// endpoints). These are authoritative where the official API has nothing:
/// cumulative spend, request counts and per-period token totals.
struct PlatformFigures: Hashable, Sendable {
    var currency: String = "CNY"
    /// 累计消费金额 — `total_costs` from the account summary.
    var cumulativeSpend: Double?

    var periodTokens = 0
    var periodRequests = 0
    var periodCost: Double = 0
    var promptTokens = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var responseTokens = 0

    var fetchedAt: Date = Date()
    var periodDays = 1
}

/// Everything the widget knows about DeepSeek platform usage.
struct DeepSeekSnapshot: Hashable, Sendable {
    var isAvailable: Bool = false
    var currency: String = "CNY"
    var totalBalance: Double = 0
    var grantedBalance: Double = 0
    var toppedUpBalance: Double = 0

    var todayUsage = TokenUsage()
    var weekUsage = TokenUsage()
    var monthUsage = TokenUsage()
    /// Last 7 days, oldest first, for the trend strip.
    var recentDays: [DayUsage] = []

    /// Spend observed by this app's balance ledger (balance deltas since tracking began).
    var trackedSpend: Double = 0
    var spendToday: Double = 0
    var trackedSince: Date?

    /// Token-count × price estimate for the same period.
    var estimatedCostToday: Double = 0
    var estimatedCostWeek: Double = 0

    var balanceUpdatedAt: Date?
    var usageScannedAt: Date?
    var health: ProviderHealth = .loading
    var errorText: String?
    var keySource: String?
    /// Present once a platform session token is configured and works.
    var platform: PlatformFigures?
    var platformError: String?

    /// True when the dashboard numbers are driving the token/request read-out.
    var usesPlatformNumbers: Bool { platform != nil }

    var daysUntilEmpty: Double? {
        guard spendToday > 0.0001 else { return nil }
        return totalBalance / spendToday
    }
}

// MARK: - Pricing

/// Per-million-token prices (CNY) used for local cost estimation.
///
/// DeepSeek bills off-peak rates at exactly half of peak rates, so the table
/// stores off-peak prices plus a peak multiplier. Peak hours are
/// Mon–Fri 09:00–12:00 and 14:00–18:00 Beijing time.
struct ModelPricing: Codable, Hashable, Sendable {
    var cacheHitInput: Double
    var cacheMissInput: Double
    var output: Double
    var peakMultiplier: Double = 2.0

    /// `deepseek-flash` / DeepSeek-V4.1-Flash (also serves the retired
    /// `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` model names).
    static let flash = ModelPricing(cacheHitInput: 0.02, cacheMissInput: 1.0, output: 4.0)

    /// `deepseek-v4-pro` / DeepSeek-V4-Pro-0813.
    static let v4pro = ModelPricing(cacheHitInput: 0.15, cacheMissInput: 4.5, output: 13.5)

    static let deepSeekDefault = ModelPricing.flash

    /// Beijing (UTC+8) weekday peak windows.
    static func isPeak(_ date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return false }
        guard (2...6).contains(weekday) else { return false }  // Mon–Fri (1 = Sunday)
        return (9..<12).contains(hour) || (14..<18).contains(hour)
    }

    func multiplier(at date: Date = Date()) -> Double {
        Self.isPeak(date) ? peakMultiplier : 1.0
    }

    /// Cost of `usage`, optionally split into peak and off-peak portions.
    func cost(for usage: TokenUsage, peakUsage: TokenUsage? = nil, at date: Date = Date()) -> Double {
        guard let peakUsage else {
            let rate = multiplier(at: date)
            return raw(usage, rate: rate)
        }
        let offPeak = TokenUsage(
            input: max(0, usage.input - peakUsage.input),
            cachedInput: max(0, usage.cachedInput - peakUsage.cachedInput),
            output: max(0, usage.output - peakUsage.output),
            reasoning: max(0, usage.reasoning - peakUsage.reasoning),
            requests: max(0, usage.requests - peakUsage.requests)
        )
        return raw(peakUsage, rate: peakMultiplier) + raw(offPeak, rate: 1.0)
    }

    private func raw(_ usage: TokenUsage, rate: Double) -> Double {
        let million = 1_000_000.0
        return (Double(usage.cachedInput) / million * cacheHitInput
            + Double(usage.input) / million * cacheMissInput
            + Double(usage.output) / million * output) * rate
    }
}

enum PricingPreset: String, CaseIterable, Identifiable {
    case flash
    case v4pro
    case custom

    var id: String { rawValue }

    var pricing: ModelPricing? {
        switch self {
        case .flash: return .flash
        case .v4pro: return .v4pro
        case .custom: return nil
        }
    }

    var title: String {
        switch self {
        case .flash: return "DeepSeek Flash"
        case .v4pro: return "DeepSeek V4 Pro"
        case .custom: return "自定义"
        }
    }
}

// MARK: - Day keys

enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        formatter.string(from: date)
    }

    static func startOfDay(_ date: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}
