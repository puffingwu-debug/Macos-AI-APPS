import Foundation

/// 本地持久化 + 离线队列（outbox）。
///
/// 设计要点（契约 §5）：
/// - 所有增删改**先落本地**，UI 立即刷新，网络永远是异步的；
/// - 每次本地改动同时写一条 outbox 记录，同步引擎按序上抛；
/// - `cursor` 是增量拉取游标，等于上次拉到的 max(updateTime)；
/// - 退出/崩溃都不会丢数据：整个 store 原子写盘。
@MainActor
final class LocalStore {

    /// 待上抛的变更。同一 id 只保留最新一条（写合并）。
    struct OutboxOp: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case upsert, remove }

        var id: String
        var kind: Kind
        var todoID: String
        var payload: Todo?
        var createdAt: Int64
        var attempts: Int

        static func upsert(_ todo: Todo) -> OutboxOp {
            OutboxOp(id: UUID().uuidString, kind: .upsert, todoID: todo.id,
                     payload: todo, createdAt: Date.currentMillis, attempts: 0)
        }

        static func remove(_ todoID: String) -> OutboxOp {
            OutboxOp(id: UUID().uuidString, kind: .remove, todoID: todoID,
                     payload: nil, createdAt: Date.currentMillis, attempts: 0)
        }
    }

    private struct Snapshot: Codable {
        var version: Int = 1
        var cursor: Int64 = 0
        var todos: [Todo] = []
        var outbox: [OutboxOp] = []
        var lastSyncTime: Int64 = 0
        var openid: String = ""
        /// 见过的最大服务端时间（混合逻辑时钟的水位），与 lastIssuedStamp 一起保证
        /// 本地新改动的 updateTime 永远排在「任何已知服务端版本」之后
        var lastServerTime: Int64 = 0
        var lastIssuedStamp: Int64 = 0
    }

    private(set) var todos: [String: Todo] = [:]
    private(set) var outbox: [OutboxOp] = []
    private(set) var cursor: Int64 = 0
    private(set) var lastSyncTime: Int64 = 0
    private(set) var openid: String = ""
    /// 服务端时钟水位：每次同步响应里的 serverTime 都会抬高它
    private(set) var lastServerTime: Int64 = 0
    /// 本地已发出过的最大 updateTime（本机单调递增）
    private(set) var lastIssuedStamp: Int64 = 0

    /// 有未上抛改动 = 与云端不一致，UI 用「待同步」小圆点提示。
    var hasPendingChanges: Bool { !outbox.isEmpty }

    /// 契约约定的字段长度上限（云端会再校验一次）
    static let maxContentLength = 500
    static let maxRawTextLength = 4000

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.homeDirectoryForCurrentUser
            let dir = base.appendingPathComponent("QuickTodo", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("store.json")
        }
        load()
    }

    // MARK: - 读写

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        cursor = snapshot.cursor
        lastSyncTime = snapshot.lastSyncTime
        openid = snapshot.openid
        lastServerTime = snapshot.lastServerTime
        lastIssuedStamp = snapshot.lastIssuedStamp
        todos = Dictionary(uniqueKeysWithValues: snapshot.todos.map { ($0.id, $0) })
        outbox = snapshot.outbox
    }

    func save() {
        let snapshot = Snapshot(
            cursor: cursor,
            todos: todos.values.sorted { $0.createTime < $1.createTime },
            outbox: outbox,
            lastSyncTime: lastSyncTime,
            openid: openid,
            lastServerTime: lastServerTime,
            lastIssuedStamp: lastIssuedStamp
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 本地变更（都会进 outbox）

    /// 新增或修改：本地立即生效 + 入队。
    func upsert(_ todo: Todo) {
        var stored = sanitize(todo)
        stored.updateTime = nextUpdateTime()
        guard !stored.content.isEmpty else { return }
        todos[stored.id] = stored
        enqueue(.upsert(stored))
        save()
    }

    /// 批量导入（截图 / 语音解析结果一次导入多条）。
    func upsertBatch(_ items: [Todo]) {
        guard !items.isEmpty else { return }
        for item in items {
            var stored = sanitize(item)
            stored.updateTime = nextUpdateTime()
            guard !stored.content.isEmpty else { continue }
            todos[stored.id] = stored
            enqueue(.upsert(stored))
        }
        save()
    }

    /// 按契约做长度与格式收敛（云函数也会再做一遍，客户端先做可以少一次失败往返）。
    private func sanitize(_ todo: Todo) -> Todo {
        var value = todo
        value.content = String(value.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxContentLength))
        value.rawText = String(value.rawText.prefix(Self.maxRawTextLength))
        return value
    }

    // MARK: - 混合逻辑时钟（HLC-lite）

    /// 抬高服务端时钟水位。每次同步响应都会带 `serverTime`，存下来用于给本地改动打时间戳。
    func observeServerTime(_ serverTime: Int64) {
        guard serverTime > lastServerTime else { return }
        lastServerTime = serverTime
        save()
    }

    /// 给本地改动分配 updateTime。
    ///
    /// 契约用 `updateTime` 做 LWW 判定，而客户端离线时只能用本机时钟。
    /// 如果本机时钟比服务器慢，本地新改动的 updateTime 会小于服务端已存的版本，
    /// 上抛时被判 `stale`、服务端旧版本反覆盖本地 —— 用户刚改的东西就"自己变回去了"。
    /// 所以这里取三者最大值：本机时间 / 见过的服务端时间 + 1 / 本机上次发号 + 1。
    func nextUpdateTime() -> Int64 {
        let stamp = max(Date.currentMillis, max(lastServerTime + 1, lastIssuedStamp + 1))
        lastIssuedStamp = stamp
        return stamp
    }

    /// 上抛成功后采用服务端盖章的 `updateTime`，让本地与服务端的时间线完全一致。
    ///
    /// - Parameter pushedStamps: id → 本次上抛时用的本地 updateTime。
    ///   只有在「推送之后用户没再改过这条」时才采纳，避免把并发的新改动时间戳改小。
    func adoptServerStamps(_ applied: [AppliedItem], pushedStamps: [String: Int64]) {
        var changed = false
        for item in applied {
            guard var local = todos[item.id] else { continue }
            if let pushed = pushedStamps[item.id] {
                guard local.updateTime == pushed else { continue }
            }
            guard local.updateTime != item.updateTime else { continue }
            local.updateTime = item.updateTime
            todos[item.id] = local
            lastIssuedStamp = max(lastIssuedStamp, item.updateTime)
            changed = true
        }
        if changed { save() }
    }

    func toggleDone(_ id: String) {
        guard var todo = todos[id] else { return }
        todo.status = todo.isDone ? .todo : .done
        upsert(todo)
    }

    func setDone(_ id: String, done: Bool) {
        guard var todo = todos[id] else { return }
        guard todo.isDone != done else { return }
        todo.status = done ? .done : .todo
        upsert(todo)
    }

    /// 软删除：契约要求删除也必须能被增量下发，所以是 `deleted = true` 而不是物理删除。
    func remove(_ id: String) {
        guard var todo = todos[id] else { return }
        todo.deleted = true
        todo.updateTime = nextUpdateTime()
        todos[id] = todo
        enqueue(.remove(id))
        save()
    }

    func removeDone() {
        for todo in todos.values where todo.isDone && !todo.deleted {
            remove(todo.id)
        }
    }

    // MARK: - 同步结果应用

    /// 应用服务端下发的条目。
    ///
    /// - 本地有未上抛改动的条目**不覆盖**（本地优先，等推上去以后服务端会回传盖章版本）；
    /// - 其余按 LWW：`updateTime` 更新的一方胜出。
    func applyRemote(_ items: [Todo], cursor newCursor: Int64) {
        let pendingIDs = Set(outbox.map(\.todoID))
        for item in items {
            if pendingIDs.contains(item.id) { continue }
            if let local = todos[item.id], local.updateTime > item.updateTime { continue }
            todos[item.id] = item
        }
        if newCursor > cursor { cursor = newCursor }
        lastSyncTime = Date.currentMillis
        save()
    }

    /// 服务端判定 stale 时回传的权威版本：直接覆盖本地（服务端为准）。
    ///
    /// 契约要求服务端回传**完整文档**；万一拿到的是残缺数据（content 为空），
    /// 宁可保留本地版本，也不要被空值洗掉用户数据。
    func applyAuthoritative(_ items: [Todo]) {
        for item in items {
            guard !item.content.isEmpty, var local = todos[item.id] else { continue }
            local.content = item.content
            local.deadline = item.deadline
            local.priority = item.priority
            local.status = item.status
            local.source = item.source
            if !item.rawText.isEmpty { local.rawText = item.rawText }
            local.deleted = item.deleted
            local.updateTime = item.updateTime
            todos[item.id] = local
        }
        save()
    }

    /// 上抛成功后把对应 op 移出队列。
    func completeOps(_ opIDs: Set<String>) {
        guard !opIDs.isEmpty else { return }
        outbox.removeAll { opIDs.contains($0.id) }
        save()
    }

    func bumpAttempts(_ opIDs: Set<String>) {
        for index in outbox.indices where opIDs.contains(outbox[index].id) {
            outbox[index].attempts += 1
        }
        save()
    }

    func setOpenid(_ value: String) {
        openid = value
        save()
    }

    /// 退出登录：清空本地数据与游标，避免换账号后串数据。
    func resetForLogout() {
        todos = [:]
        outbox = []
        cursor = 0
        lastSyncTime = 0
        openid = ""
        save()
    }

    var storeFileURL: URL { fileURL }

    // MARK: - 私有

    /// 同一待办只保留最新一条 op，避免离线期间反复编辑堆积成几十条请求。
    private func enqueue(_ op: OutboxOp) {
        outbox.removeAll { $0.todoID == op.todoID }
        outbox.append(op)
    }
}

// MARK: - 展示数据

extension LocalStore {
    /// 未删除的待办（UI 用）。
    var visibleTodos: [Todo] {
        todos.values.filter { !$0.deleted }
    }

    var pendingCount: Int {
        visibleTodos.filter { !$0.isDone }.count
    }
}
