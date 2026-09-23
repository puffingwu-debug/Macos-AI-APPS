import Foundation
import SwiftUI

/// Immutable inputs handed to the background scanners.
struct ScanConfig: Sendable {
    var retentionDays: Int
    var scanBudget: Double
}

/// Immutable output of one background scan pass.
struct ScanOutput: Sendable {
    struct DeepSeekLocal: Sendable {
        var today = TokenUsage()
        var week = TokenUsage()
        var month = TokenUsage()
        var peakToday = TokenUsage()
        var peakWeek = TokenUsage()
        var recentDays: [DayUsage] = []
        var lastEventAt: Date?
        var available = true
        var errorText: String?
    }

    var codex = CodexSnapshot()
    var deepSeekLocal = DeepSeekLocal()
    var duration: TimeInterval = 0
}

/// Owns every log scanner. Lives off the main actor; `scan` is called from a
/// dedicated serial queue, so the scanners never need to be re-entrant.
final class ScanWorker: @unchecked Sendable {
    private let codexScanner = CodexScanner()
    private let dshScanner = DSHLogScanner()
    private let globalState = CodexGlobalStateReader()
    private let planReader = CodexPlanReader()

    func scan(config: ScanConfig) -> ScanOutput {
        let started = Date()
        var output = ScanOutput()

        // ---- ChatGPT / Codex ----------------------------------------------
        let codexResult = codexScanner.refresh(retentionDays: config.retentionDays, budget: config.scanBudget)
        var codex = CodexSnapshot()

        if let sample = codexResult.latestRateLimit {
            codex.lastRateLimitAt = Date(timeIntervalSince1970: sample.at)
            codex.planType = sample.planType
            if let primary = sample.primary {
                codex.windows.append(QuotaWindow(
                    id: "primary",
                    windowMinutes: primary.windowMinutes,
                    usedPercent: primary.usedPercent,
                    resetsAt: primary.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    label: QuotaWindow.label(forWindowMinutes: primary.windowMinutes)
                ))
            }
            if let secondary = sample.secondary {
                codex.windows.append(QuotaWindow(
                    id: "secondary",
                    windowMinutes: secondary.windowMinutes,
                    usedPercent: secondary.usedPercent,
                    resetsAt: secondary.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    label: "短周期 · " + QuotaWindow.label(forWindowMinutes: secondary.windowMinutes)
                ))
            }
            if let credits = sample.credits {
                codex.credits = CreditInfo(hasCredits: credits.hasCredits, unlimited: credits.unlimited, balance: credits.balance)
            }
        }

        let series = CodexScanner.series(from: codexResult.daily, days: 7)
        codex.todayUsage = series.last?.usage ?? TokenUsage()
        codex.weekUsage = series.reduce(TokenUsage()) { $0 + $1.usage }
        codex.recentDays = series.map { DayUsage(day: $0.day, usage: $0.usage) }
        codex.lastActivityAt = codexResult.lastEventAt
        codex.scannedFiles = codexResult.filesParsed

        let info = globalState.read()
        codex.resetCount = info.resetCount
        codex.lastResetAt = info.lastResetAt

        // Subscription tier: the rollout logs usually carry a null plan_type, so
        // fall back to the id_token claim, which is available offline.
        var plan = planReader.read()
        if let fromLogs = codex.planType, !fromLogs.isEmpty {
            plan.rawType = fromLogs
            plan.source = "用量记录"
        }
        codex.plan = plan

        if codex.windows.isEmpty {
            if codexResult.noData {
                codex.health = .failed("未找到 Codex 用量记录")
                codex.errorText = "请先在 ChatGPT 桌面端或 Codex CLI 中发起一次对话"
            } else {
                codex.health = .stale("等待首次用量数据")
            }
        } else if !codexResult.complete {
            codex.health = .stale("正在后台补全历史")
        } else {
            codex.health = .ok
        }
        output.codex = codex

        // ---- DeepSeek local token usage -----------------------------------
        let dsh = dshScanner.refresh()
        var local = ScanOutput.DeepSeekLocal()
        let totals = dsh.usage(providerPrefix: "deepseek", days: 31)
        local.today = totals.today
        local.week = totals.week
        local.month = totals.month
        local.peakToday = totals.peakToday
        local.peakWeek = totals.peakWeek
        local.recentDays = dsh.dailySeries(providerPrefix: "deepseek", days: 7)
        local.available = dsh.available
        local.errorText = dsh.errorText
        output.deepSeekLocal = local

        output.duration = Date().timeIntervalSince(started)
        return output
    }
}

/// The single source of truth for the UI.
@MainActor
final class UsageStore: ObservableObject {

    static let shared = UsageStore()

    @Published private(set) var codex = CodexSnapshot()
    @Published private(set) var deepseek = DeepSeekSnapshot()
    /// Ticks once a second so countdowns animate without re-scanning anything.
    @Published private(set) var now = Date()
    @Published private(set) var lastScanDuration: TimeInterval = 0
    @Published private(set) var isScanning = false

    let ledger = BalanceLedger()

    private let worker = ScanWorker()
    private let provider = DeepSeekProvider()
    private let codexLive = CodexLiveProvider()
    private let platform = DeepSeekPlatformProvider()
    private let scanQueue = DispatchQueue(label: "com.aitokenbar.scan", qos: .utility)

    private var localTimer: Timer?
    private var tickTimer: Timer?
    private var networkTimer: Timer?
    private var scanInFlight = false
    private var networkInFlight = false
    private var started = false

    // Live-quota backoff: the endpoint is undocumented, so a failure must never
    // turn into a retry storm.
    private var codexIsLive = false
    private var liveFailures = 0
    private var lastLiveAttempt: Date?
    private var liveErrorText: String?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        if let tickTimer { RunLoop.main.add(tickTimer, forMode: .common) }

        let settings = AppSettings.shared
        scheduleLocalTimer(interval: settings.localInterval)
        scheduleNetworkTimer(interval: settings.networkInterval)

        restart()
    }

    func restart() {
        let settings = AppSettings.shared
        scheduleLocalTimer(interval: settings.localInterval)
        scheduleNetworkTimer(interval: settings.networkInterval)
        performLocalScan()
        refreshNetwork()
    }

    func settingsChanged() {
        scheduleLocalTimer(interval: AppSettings.shared.localInterval)
        scheduleNetworkTimer(interval: AppSettings.shared.networkInterval)
    }

    private func scheduleLocalTimer(interval: Double) {
        localTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performLocalScan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        localTimer = timer
    }

    private func scheduleNetworkTimer(interval: Double) {
        networkTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: max(15, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNetwork() }
        }
        RunLoop.main.add(timer, forMode: .common)
        networkTimer = timer
    }

    func refreshNow() {
        performLocalScan()
        refreshNetwork()
    }

    // MARK: - Local log scan

    private func performLocalScan() {
        guard !scanInFlight else { return }
        scanInFlight = true
        isScanning = true

        let settings = AppSettings.shared
        let config = ScanConfig(
            retentionDays: max(2, settings.codexRetentionDays),
            scanBudget: 2.0
        )

        scanQueue.async { [weak self] in
            guard let self else { return }
            let output = self.worker.scan(config: config)
            Task { @MainActor in
                self.apply(output, pricing: AppSettings.shared.pricing)
                self.scanInFlight = false
                self.isScanning = false
            }
        }
    }

    private func apply(_ output: ScanOutput, pricing: ModelPricing) {
        lastScanDuration = output.duration

        // A live reading outranks the log-derived one, but only for the quota
        // windows — token totals always come from local logs.
        if !codexIsLive {
            codex = output.codex
        } else {
            var merged = output.codex
            merged.windows = codex.windows
            merged.credits = codex.credits
            merged.planType = codex.planType ?? merged.planType
            merged.plan = codex.plan
            merged.isLive = true
            merged.health = codex.health
            merged.errorText = nil
            codex = merged
        }

        var snapshot = deepseek
        snapshot.todayUsage = output.deepSeekLocal.today
        snapshot.weekUsage = output.deepSeekLocal.week
        snapshot.monthUsage = output.deepSeekLocal.month
        snapshot.usageScannedAt = Date()
        snapshot.estimatedCostToday = pricing.cost(
            for: output.deepSeekLocal.today,
            peakUsage: output.deepSeekLocal.peakToday
        )
        snapshot.estimatedCostWeek = pricing.cost(
            for: output.deepSeekLocal.week,
            peakUsage: output.deepSeekLocal.peakWeek
        )
        snapshot.recentDays = output.deepSeekLocal.recentDays
        snapshot.trackedSpend = ledger.trackedSpend
        snapshot.spendToday = ledger.spendToday()
        snapshot.trackedSince = ledger.trackedSince

        // Local logs are informative but not the health signal for DeepSeek;
        // the balance call is. Only surface a local problem when it is all we have.
        if case .failed = snapshot.health {
            // keep the network error
        } else if !output.deepSeekLocal.available {
            snapshot.health = .stale(output.deepSeekLocal.errorText ?? "未找到本地用量记录")
        }
        deepseek = snapshot
    }

    // MARK: - Network refresh

    /// Refreshes everything that needs the network. The two providers are
    /// independent: a missing DeepSeek key never blocks the ChatGPT lookup.
    func refreshNetwork() {
        guard !networkInFlight else { return }
        networkInFlight = true

        Task {
            defer { Task { @MainActor in self.networkInFlight = false } }
            await self.refreshDeepSeekBalance()
            await self.refreshPlatformFigures()
            await self.refreshCodexLiveIfDue()
        }
    }

    /// Dashboard figures (cumulative spend, request counts) — only when the user
    /// has supplied a platform session token, and never fatal when it fails.
    private func refreshPlatformFigures() async {
        let token = AppSettings.shared.deepSeekPlatformToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            if deepseek.platform != nil || deepseek.platformError != nil {
                var snapshot = deepseek
                snapshot.platform = nil
                snapshot.platformError = nil
                deepseek = snapshot
            }
            return
        }

        do {
            let figures = try await platform.fetch(token: token, days: 1)
            var snapshot = deepseek
            snapshot.platform = figures
            snapshot.platformError = nil
            if figures.cumulativeSpend != nil || figures.periodTokens > 0 {
                snapshot.currency = figures.currency
            }
            deepseek = snapshot
        } catch {
            var snapshot = deepseek
            snapshot.platform = nil
            snapshot.platformError = error.localizedDescription
            deepseek = snapshot
        }
    }

    private func refreshDeepSeekBalance() async {
        guard let resolved = CredentialStore.deepSeekKey(override: AppSettings.shared.deepSeekKeyOverride) else {
            var snapshot = deepseek
            snapshot.health = .failed("未配置 DeepSeek API Key")
            snapshot.errorText = "在设置中填入 API Key，或确认 ~/.dsh/.credentials.yaml 存在"
            snapshot.keySource = nil
            deepseek = snapshot
            return
        }

        do {
            let balance = try await provider.fetchBalance(key: resolved.key)
            ledger.record(balance: balance.total, currency: balance.currency)
            var snapshot = deepseek
            snapshot.isAvailable = balance.isAvailable
            snapshot.currency = balance.currency
            snapshot.totalBalance = balance.total
            snapshot.grantedBalance = balance.granted
            snapshot.toppedUpBalance = balance.toppedUp
            snapshot.balanceUpdatedAt = Date()
            snapshot.health = balance.isAvailable ? .ok : .stale("账户余额不可用")
            snapshot.errorText = nil
            snapshot.keySource = resolved.source
            snapshot.trackedSpend = ledger.trackedSpend
            snapshot.spendToday = ledger.spendToday()
            snapshot.trackedSince = ledger.trackedSince
            deepseek = snapshot
        } catch {
            var snapshot = deepseek
            snapshot.health = .failed(error.localizedDescription)
            snapshot.errorText = error.localizedDescription
            snapshot.keySource = resolved.source
            deepseek = snapshot
        }
    }

    /// Live ChatGPT/Codex quota. Attempted at most once per refresh cycle, and
    /// backed off hard after repeated failures so an unreachable host stays cheap.
    private func refreshCodexLiveIfDue() async {
        guard AppSettings.shared.liveCodexEnabled else { return }

        let backoff: TimeInterval = liveFailures >= 3 ? 900 : 120
        if let last = lastLiveAttempt, Date().timeIntervalSince(last) < backoff { return }
        lastLiveAttempt = Date()

        do {
            let live = try await codexLive.fetch()
            codexIsLive = true
            liveFailures = 0
            liveErrorText = nil

            var snapshot = codex
            snapshot.windows = live.windows
            snapshot.credits = live.credits ?? snapshot.credits
            snapshot.planType = live.planType ?? snapshot.planType
            if let livePlan = live.planType, !livePlan.isEmpty {
                snapshot.plan.rawType = livePlan
                snapshot.plan.source = "实时接口"
            }
            snapshot.lastRateLimitAt = live.fetchedAt
            snapshot.isLive = true
            snapshot.health = .ok
            snapshot.errorText = nil
            codex = snapshot
        } catch {
            liveFailures += 1
            liveErrorText = error.localizedDescription
            // Keep whatever the logs told us; only downgrade when we have nothing.
            if codex.windows.isEmpty {
                var snapshot = codex
                snapshot.health = .failed(error.localizedDescription)
                snapshot.errorText = error.localizedDescription
                codex = snapshot
            } else {
                codexIsLive = false
            }
        }
    }

    var liveStatusText: String? {
        if codexIsLive { return "实时接口" }
        if let liveErrorText { return "本地日志（实时接口不可用：\(liveErrorText)）" }
        return nil
    }

    // MARK: - Derived display values

    /// Compact string for the menu bar.
    var menuBarTitle: String {
        let settings = AppSettings.shared
        if settings.showCodex, let window = codex.headlineWindow {
            return Fmt.percent(window.remainingPercent)
        }
        if settings.showDeepSeek, deepseek.balanceUpdatedAt != nil {
            return Fmt.money(deepseek.totalBalance, currency: deepseek.currency)
        }
        return "--"
    }

    /// Tighter wording for the narrow densities.
    var shortSummary: String {
        var parts: [String] = []
        if let window = codex.headlineWindow {
            parts.append("剩余 \(Fmt.percent(window.remainingPercent))")
        }
        if deepseek.balanceUpdatedAt != nil {
            parts.append(Fmt.money(deepseek.totalBalance, currency: deepseek.currency))
        }
        return parts.isEmpty ? "暂无数据" : parts.joined(separator: " · ")
    }

    var statusSummary: String {
        var parts: [String] = []
        if let window = codex.headlineWindow {
            parts.append("ChatGPT 剩余 \(Fmt.percent(window.remainingPercent))")
        }
        if deepseek.balanceUpdatedAt != nil {
            parts.append("DeepSeek 余额 \(Fmt.money(deepseek.totalBalance, currency: deepseek.currency))")
        }
        return parts.isEmpty ? "暂无数据" : parts.joined(separator: " · ")
    }
}
