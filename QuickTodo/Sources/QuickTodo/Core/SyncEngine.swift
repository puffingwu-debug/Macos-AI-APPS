import AppKit
import Foundation

/// 同步引擎：先上抛 outbox，再增量拉取（契约 §5）。
///
/// 关键不变量：
/// 1. 同步永远不阻塞 UI —— 所有网络调用都在后台任务里，UI 只观察 `state`；
/// 2. 任何失败都不丢数据 —— outbox 留在本地，指数退避后重试；
/// 3. 未配置云端时安静地退化为纯本地模式，不弹任何错误。
@MainActor
final class SyncEngine: ObservableObject {

    enum State: Equatable {
        case localOnly          // 未配置云端
        case idle               // 已同步
        case syncing
        case offline(String)    // 网络问题，稍后重试
        case error(String)      // 业务错误
        case unauthorized       // 需要重新登录

        var label: String {
            switch self {
            case .localOnly: return "本地模式"
            case .idle: return "已同步"
            case .syncing: return "同步中"
            case .offline: return "离线"
            case .error: return "同步异常"
            case .unauthorized: return "未登录"
            }
        }

        var isBusy: Bool { self == .syncing }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSyncTime: Int64 = 0
    /// 最近一次同步的结果摘要，设置面板展示用。
    @Published private(set) var lastSummary: String = "尚未同步"

    private let store: LocalStore
    private let settings: AppSettings
    private let api: QuickTodoAPI
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void
    private let onDataChanged: () -> Void

    private var timer: Timer?
    private var inFlight = false
    private var consecutiveFailures = 0
    private var retryNotBefore: Date = .distantPast
    private var lastTickAt: Date = .distantPast

    init(
        store: LocalStore,
        settings: AppSettings,
        api: QuickTodoAPI,
        tokenProvider: @escaping () -> String?,
        onUnauthorized: @escaping () -> Void,
        onDataChanged: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.api = api
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        self.onDataChanged = onDataChanged
        self.lastSyncTime = store.lastSyncTime
        refreshLocalOnlyState()
    }

    deinit { timer?.invalidate() }

    // MARK: - 生命周期

    func start() {
        timer?.invalidate()
        // 每 5 秒醒一次做判断：前台 15s 一拉，后台 60s 一拉，退避期内直接跳过。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard settings.hasCloud else {
            refreshLocalOnlyState()
            return
        }
        let isForeground = NSApplication.shared.isActive
        let interval: TimeInterval = isForeground ? 15 : 60
        guard Date().timeIntervalSince(lastTickAt) >= interval else { return }
        guard Date() >= retryNotBefore else { return }
        Task { await sync() }
    }

    private func refreshLocalOnlyState() {
        if !settings.hasCloud {
            state = .localOnly
        } else if state == .localOnly {
            state = .idle
        }
    }

    // MARK: - 主流程

    /// 立即同步（用户点「立即同步」或下拉刷新时调用）。
    func syncNow() async {
        retryNotBefore = .distantPast
        await sync(force: true)
    }

    func sync(force: Bool = false) async {
        guard settings.hasCloud else {
            state = .localOnly
            return
        }
        guard let token = tokenProvider(), !token.isEmpty else {
            state = .unauthorized
            return
        }
        if inFlight && !force { return }
        inFlight = true
        lastTickAt = Date()
        state = .syncing
        defer { inFlight = false }

        let baseURL = settings.normalizedBaseURL
        do {
            let pushed = try await flushOutbox(baseURL: baseURL, token: token)
            let pulled = try await pull(baseURL: baseURL, token: token)
            consecutiveFailures = 0
            lastSyncTime = store.lastSyncTime
            state = .idle
            lastSummary = "\(Self.clockText()) 推送 \(pushed) 条 / 拉取 \(pulled) 条"
        } catch let error as CloudError {
            if error.isUnauthorized {
                state = .unauthorized
                lastSummary = error.message
                onUnauthorized()
                return
            }
            consecutiveFailures += 1
            let delay = min(60.0, pow(2.0, Double(consecutiveFailures - 1)))
            retryNotBefore = Date().addingTimeInterval(delay)
            state = error.code == "network" ? .offline(error.message) : .error(error.message)
            lastSummary = "\(Self.clockText()) \(error.message)（\(Int(delay))s 后重试）"
        } catch {
            consecutiveFailures += 1
            let delay = min(60.0, pow(2.0, Double(consecutiveFailures - 1)))
            retryNotBefore = Date().addingTimeInterval(delay)
            state = .error(error.localizedDescription)
            lastSummary = "\(Self.clockText()) \(error.localizedDescription)"
        }
    }

    /// 上抛本地待同步队列，返回成功上抛的条数。
    @discardableResult
    private func flushOutbox(baseURL: String, token: String) async throws -> Int {
        let ops = store.outbox
        guard !ops.isEmpty else { return 0 }

        var pushed = 0
        let upsertOps = ops.filter { $0.kind == .upsert }
        let removeOps = ops.filter { $0.kind == .remove }

        if !upsertOps.isEmpty {
            let items = upsertOps.compactMap(\.payload)
            let result = try await api.bulkUpsert(baseURL: baseURL, token: token, items: items)
            // 抬高本地时钟水位：后续本地改动的 updateTime 一定排在已知服务端版本之后
            if let serverTime = result.serverTime { store.observeServerTime(serverTime) }
            var done = Set<String>()
            let appliedIDs = Set((result.applied ?? []).map(\.id))
            for op in upsertOps where appliedIDs.contains(op.todoID) {
                done.insert(op.id)
            }
            // 采用服务端盖章时间，保持两端时间线一致（并修正本机时钟偏快/偏慢带来的漂移）
            let pushedStamps = Dictionary(
                upsertOps.compactMap { op in op.payload.map { (op.todoID, $0.updateTime) } },
                uniquingKeysWith: { first, _ in first }
            )
            store.adoptServerStamps(result.applied ?? [], pushedStamps: pushedStamps)
            // 服务端判定 stale：本地版本过旧，用服务端权威值纠正本地缓存。
            if let stale = result.stale, !stale.isEmpty {
                store.applyAuthoritative(stale)
                for op in upsertOps where stale.contains(where: { $0.id == op.todoID }) {
                    done.insert(op.id)
                }
            }
            // 被服务端拒绝（例如内容为空）：丢弃该 op，避免死循环重试。
            if let rejected = result.rejected {
                for item in rejected {
                    for op in upsertOps where op.todoID == item.id { done.insert(op.id) }
                }
            }
            store.completeOps(done)
            let remaining = Set(upsertOps.map(\.id)).subtracting(done)
            store.bumpAttempts(remaining)
            pushed += done.count
            if !done.isEmpty { onDataChanged() }
        }

        if !removeOps.isEmpty {
            let ids = removeOps.map(\.todoID)
            let result = try await api.remove(baseURL: baseURL, token: token, ids: ids)
            if let serverTime = result.serverTime { store.observeServerTime(serverTime) }
            let done = Set(removeOps.map(\.id))
            store.completeOps(done)
            pushed += done.count
        }

        return pushed
    }

    /// 增量拉取直到拉空，返回拉取条数。
    @discardableResult
    private func pull(baseURL: String, token: String) async throws -> Int {
        var fetched = 0
        var guardCounter = 0
        while true {
            guardCounter += 1
            if guardCounter > 20 { break }   // 防御：极端情况下不要无限循环
            let result = try await api.list(baseURL: baseURL, token: token, since: store.cursor, limit: 100)
            let items = result.items ?? []
            let nextCursor = result.cursor ?? store.cursor
            store.applyRemote(items, cursor: nextCursor)
            if let serverTime = result.serverTime { store.observeServerTime(serverTime) }
            fetched += items.count
            if !(result.hasMore ?? false) { break }
            if items.isEmpty { break }
        }
        if fetched > 0 { onDataChanged() }
        return fetched
    }

    static func clockText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
