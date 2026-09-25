import SwiftUI

/// The desktop mini-window: an always-visible read-out of AI quota, styled to sit
/// alongside the system's own desktop widgets.
///
/// The layout is a single row with one column per provider: side by side keeps the
/// widget short, so it occupies less desktop while showing the same numbers.
struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    /// The menu bar popover always has room, so it pins the density.
    var densityOverride: WidgetDensity?

    init(
        store: UsageStore,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        densityOverride: WidgetDensity? = nil
    ) {
        self.store = store
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.densityOverride = densityOverride
    }

    private var density: WidgetDensity { densityOverride ?? settings.density }

    var body: some View {
        Group {
            if density == .mini {
                MiniLineView(store: store, settings: settings, density: density)
            } else {
                VStack(alignment: .leading, spacing: density.sectionSpacing) {
                    columns
                    if density.showsDetails {
                        detailSection
                    }
                    footer
                }
                .padding(density.outerPadding)
            }
        }
        .frame(width: density.width)
        .background {
            WidgetSurface(cornerRadius: density.cornerRadius)
                .opacity(settings.opacity)
        }
        // One silhouette for the material, the edge light and the shadow.
        .clipShape(RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous))
    }

    // MARK: - Provider columns

    private var columns: some View {
        HStack(alignment: .top, spacing: density.columnGap) {
            if settings.showDeepSeek {
                DeepSeekColumn(store: store, density: density)
                    .frame(width: density.columnWidth, alignment: .leading)
            }
            if settings.showDeepSeek && settings.showCodex {
                WidgetDivider()
                    .frame(maxHeight: .infinity)
            }
            if settings.showCodex {
                CodexColumn(store: store, density: density)
                    .frame(width: density.columnWidth, alignment: .leading)
            }
            if !settings.showDeepSeek && !settings.showCodex {
                Text("在设置中开启至少一个数据源")
                    .font(.system(size: density.bodyFont))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Details (full density only)

    @ViewBuilder
    private var detailSection: some View {
        WidgetDivider(vertical: false)

        HStack(alignment: .top, spacing: density.columnGap) {
            if settings.showDeepSeek, !store.deepseek.recentDays.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("近 7 天 tokens")
                        .font(.system(size: density.detailFont - 1))
                        .foregroundStyle(.secondary)
                    TrendStrip(days: store.deepseek.recentDays, tint: Theme.deepseek, height: 20)
                }
                .frame(width: density.columnWidth, alignment: .leading)
            }
            if settings.showDeepSeek && settings.showCodex {
                WidgetDivider().frame(maxHeight: .infinity)
            }
            if settings.showCodex, !store.codex.recentDays.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("近 7 天 tokens")
                        .font(.system(size: density.detailFont - 1))
                        .foregroundStyle(.secondary)
                    TrendStrip(days: store.codex.recentDays, tint: Theme.codex, height: 20)
                }
                .frame(width: density.columnWidth, alignment: .leading)
            }
        }

        HStack(alignment: .top, spacing: density.columnGap) {
            if settings.showDeepSeek {
                VStack(alignment: .leading, spacing: 2) {
                    DeepSeekDetailRows(store: store, density: density)
                }
                .frame(width: density.columnWidth, alignment: .leading)
            }
            if settings.showDeepSeek && settings.showCodex {
                WidgetDivider().frame(maxHeight: .infinity)
            }
            if settings.showCodex {
                VStack(alignment: .leading, spacing: 2) {
                    CodexDetailRows(store: store, density: density)
                }
                .frame(width: density.columnWidth, alignment: .leading)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.codex.headlineWindow == nil ? Theme.warning : Theme.codex)
                .frame(width: 5, height: 5)
            Text(store.shortSummary)
                .font(.system(size: density.detailFont))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            IconButton(
                symbol: store.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                help: "立即刷新",
                size: density.tileSize + 1
            ) { store.refreshNow() }
            IconButton(
                symbol: settings.level.symbol,
                help: "窗口层级：\(settings.level.shortTitle)",
                size: density.tileSize + 1
            ) {
                settings.cycleLevel()
                WidgetPanelController.shared.applyWindowTraits()
            }
            if density == .full {
                IconButton(symbol: "gearshape", help: "设置", size: density.tileSize + 1, action: onOpenSettings)
                IconButton(symbol: "power", help: "退出", size: density.tileSize + 1, action: onQuit)
            }
            Button {
                settings.cycleDensity()
            } label: {
                Text(density == .full ? "收起" : "详情")
                    .font(.system(size: density.detailFont, weight: .medium))
                    .foregroundStyle(Theme.deepseek)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Mini density

/// One-line form: remaining %, reset countdown and balance — small enough to park
/// in a screen corner without covering anything.
@MainActor
private struct MiniLineView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var density: WidgetDensity

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if settings.showCodex, let window = store.codex.headlineWindow {
                Image(systemName: "sparkles")
                    .font(.system(size: density.symbolSize, weight: .semibold))
                    .foregroundStyle(Theme.codex)
                Text(Fmt.percent(window.remainingPercent))
                    .font(.system(size: density.heroFont, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint(for: window))
                    .lineLimit(1)
                    .fixedSize()
                if let reset = window.resetsAt {
                    Text(shortCountdown(window.timeRemaining(from: store.now) ?? 0))
                        .font(.system(size: density.detailFont, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("\(Fmt.shortDateTime(reset)) 重置")
                }
                if store.codex.plan.hasPlan {
                    Image(systemName: store.codex.plan.symbol)
                        .font(.system(size: density.symbolSize - 2, weight: .bold))
                        .foregroundStyle(Theme.codex)
                        .help("会员等级：\(store.codex.plan.displayName)")
                }
            }

            if settings.showCodex && settings.showDeepSeek {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: density.symbolSize + 1)
            }

            if settings.showDeepSeek, store.deepseek.balanceUpdatedAt != nil {
                Image(systemName: "drop.fill")
                    .font(.system(size: density.symbolSize, weight: .semibold))
                    .foregroundStyle(Theme.deepseek)
                Text(Fmt.money(store.deepseek.totalBalance, currency: store.deepseek.currency))
                    .font(.system(size: density.heroFont, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 0)

            if hovering {
                IconButton(symbol: "arrow.clockwise", help: "立即刷新", size: density.tileSize) {
                    store.refreshNow()
                }
                IconButton(symbol: "chevron.down", help: "展开", size: density.tileSize) {
                    settings.cycleDensity()
                }
            }
        }
        .padding(.horizontal, density.outerPadding)
        .padding(.vertical, 6)
        .frame(width: density.width)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { settings.cycleDensity() }
    }

    private func tint(for window: QuotaWindow) -> Color {
        if window.remainingPercent <= 10 { return Theme.danger }
        if window.remainingPercent <= 30 { return Theme.warning }
        return Theme.codex
    }

    /// "3天2h" — the countdown, squeezed.
    private func shortCountdown(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "即将重置" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        if days > 0 { return "\(days)天\(hours)h" }
        let minutes = (total % 3_600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
}

// MARK: - ChatGPT column

@MainActor
private struct CodexColumn: View {
    @ObservedObject var store: UsageStore
    var density: WidgetDensity

    private var snapshot: CodexSnapshot { store.codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: density.symbolSize, weight: .semibold))
                    .foregroundStyle(Theme.codex)
                Text("ChatGPT")
                    .font(.system(size: density.headerFont, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }

            if let window = snapshot.headlineWindow {
                // Deliberately mirrors the DeepSeek column: a large number, a
                // caption, a bar. A quota ring at this width was cramped and left
                // the two columns visibly different heights.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(Fmt.percent(window.remainingPercent))
                            .font(.system(size: density.heroFont, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(tint(for: window))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        if snapshot.plan.hasPlan {
                            PlanBadge(plan: snapshot.plan, font: density.detailFont - 1.5)
                        }
                    }
                    Text("剩余 · 已用 \(Fmt.percent1(window.usedPercent))")
                        .font(.system(size: density.detailFont))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                MiniBar(fraction: window.clampedUsedPercent / 100, tint: tint(for: window), height: 3.5)

                if let reset = window.resetsAt {
                    let remaining = window.timeRemaining(from: store.now) ?? 0
                    Text("\(Fmt.countdown(remaining)) 后重置")
                        .font(.system(size: density.detailFont, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(remaining < 3_600 ? Theme.warning : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .help("\(Fmt.shortDateTime(reset)) 重置")
                }
            } else {
                Text(snapshot.errorText ?? "正在读取用量记录…")
                    .font(.system(size: density.detailFont))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tint(for window: QuotaWindow) -> Color {
        if window.remainingPercent <= 10 { return Theme.danger }
        if window.remainingPercent <= 30 { return Theme.warning }
        return Theme.codex
    }
}

// MARK: - DeepSeek column

@MainActor
private struct DeepSeekColumn: View {
    @ObservedObject var store: UsageStore
    var density: WidgetDensity

    private var snapshot: DeepSeekSnapshot { store.deepseek }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "drop.fill")
                    .font(.system(size: density.symbolSize, weight: .semibold))
                    .foregroundStyle(Theme.deepseek)
                Text("DeepSeek")
                    .font(.system(size: density.headerFont, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.money(snapshot.totalBalance, currency: snapshot.currency))
                    .font(.system(size: density.heroFont, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("余额 \(snapshot.currency)")
                    .font(.system(size: density.detailFont - 1))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("今日 \(Fmt.compact(snapshot.todayUsage.total)) tokens")
                    .font(.system(size: density.detailFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let platform = snapshot.platform {
                    Text("累计消费 \(Fmt.money(platform.cumulativeSpend ?? 0, currency: platform.currency))")
                        .font(.system(size: density.detailFont))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text("预估 \(Fmt.money(snapshot.estimatedCostToday, currency: snapshot.currency))")
                        .font(.system(size: density.detailFont))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }
}

// MARK: - Detail rows (full density)

@MainActor
private struct CodexDetailRows: View {
    @ObservedObject var store: UsageStore
    var density: WidgetDensity

    var body: some View {
        let snapshot = store.codex
        StatRow(label: "重置次数", value: "\(snapshot.resetCount) 次", font: density.detailFont)
        if snapshot.plan.hasPlan {
            StatRow(label: "会员等级", value: snapshot.plan.displayName,
                    font: density.detailFont, accent: Theme.codex)
        }
        StatRow(label: "本机今日", value: Fmt.compact(snapshot.todayUsage.total),
                font: density.detailFont, accent: Theme.codex)
        StatRow(label: "近 7 天", value: Fmt.compact(snapshot.weekUsage.total), font: density.detailFont)
        if let last = snapshot.lastActivityAt {
            StatRow(label: "最近活动", value: Fmt.relative(last, now: store.now), font: density.detailFont)
        }
        if let credits = snapshot.credits, credits.hasCredits || credits.unlimited {
            StatRow(label: "额外额度",
                    value: credits.unlimited ? "不限量" : Fmt.money(credits.balance ?? 0, currency: "USD"),
                    font: density.detailFont)
        }
    }
}

@MainActor
private struct DeepSeekDetailRows: View {
    @ObservedObject var store: UsageStore
    var density: WidgetDensity

    var body: some View {
        let snapshot = store.deepseek
        StatRow(label: "充值余额", value: Fmt.money(snapshot.toppedUpBalance, currency: snapshot.currency),
                font: density.detailFont)
        if snapshot.grantedBalance > 0.001 {
            StatRow(label: "赠金余额", value: Fmt.money(snapshot.grantedBalance, currency: snapshot.currency),
                    font: density.detailFont)
        }
        if let platform = snapshot.platform {
            StatRow(label: "今日 tokens", value: Fmt.compact(platform.periodTokens),
                    font: density.detailFont, accent: Theme.deepseek)
            StatRow(label: "今日请求", value: Fmt.grouped(platform.periodRequests), font: density.detailFont)
        } else {
            StatRow(label: "本机今日", value: Fmt.compact(snapshot.todayUsage.total),
                    font: density.detailFont, accent: Theme.deepseek)
            StatRow(label: "预估成本",
                    value: Fmt.money(snapshot.estimatedCostToday, currency: snapshot.currency),
                    font: density.detailFont)
        }
        StatRow(label: "近 7 天", value: Fmt.compact(snapshot.weekUsage.total), font: density.detailFont)
        if snapshot.trackedSpend > 0 {
            StatRow(label: "记录消费",
                    value: Fmt.money(snapshot.trackedSpend, currency: snapshot.currency),
                    font: density.detailFont)
        }
        if let days = snapshot.daysUntilEmpty, hasEnoughTracking {
            StatRow(label: "按今日消耗可用", value: Fmt.duration(days * 86_400), font: density.detailFont)
        }
    }

    /// A spend-rate projection is only meaningful once a full day has been observed;
    /// extrapolating from a few minutes of tracking produces absurd numbers.
    private var hasEnoughTracking: Bool {
        guard let since = store.deepseek.trackedSince else { return false }
        return Date().timeIntervalSince(since) >= 86_400
    }
}

extension Notification.Name {
    static let aiTokenBarSettingsChanged = Notification.Name("aiTokenBarSettingsChanged")
}
