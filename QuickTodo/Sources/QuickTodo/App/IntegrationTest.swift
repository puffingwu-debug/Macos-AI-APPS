import Foundation

/// 跨端联调自检：`QuickTodo --integration <baseURL> <sessionToken>`
///
/// 与 `--selftest`（纯离线单机校验）不同，这个模式跑的是**真实的端到端链路**：
/// 本文件里的每一条断言，用的都是 Mac 客户端真实的 `QuickTodoAPI` / `LocalStore` / `SyncEngine`，
/// 打到的是真实的云函数代码（由 `quicktodo-weapp/tools/cloud-harness.js` 在本地以
/// 微信云开发的 event/response 形状托管）。
///
/// 覆盖：连通性、鉴权（含非法 token）、字段往返、LWW 冲突两个方向、
/// 软删除下发、增量游标、分页推进（150 条）、AI 解析（含未授权拒绝）、
/// 以及「本地改动 → 上抛 → 其他端可见」的完整同步闭环。
enum IntegrationTest {

    private final class Box<T> { var value: T? }

    private final class Counter {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
                print("  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                failed += 1
                print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }
    }

    static func run(baseURL: String, token: String) -> Int32 {
        let box = Box<Int32>()
        Task { @MainActor in
            box.value = await execute(baseURL: baseURL, token: token)
        }
        // 命令行自检没有 async 入口，这里靠 RunLoop 泵着等 MainActor 任务完成
        while box.value == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return box.value ?? 1
    }

    // swiftlint:disable:next function_body_length
    @MainActor
    private static func execute(baseURL: String, token: String) async -> Int32 {
        let counter = Counter()
        let api = QuickTodoAPI()
        let now = Date.currentMillis
        let tag = "【联调\(Int(now % 100000))】"

        print("== QuickTodo 跨端联调自检 ==")
        print("   云端：\(baseURL)\n")

        // MARK: 1. 鉴权
        print("[1] 连通性与鉴权")
        do {
            let ping = try await api.ping(baseURL: baseURL, token: token)
            counter.check("ping 返回契约版本 v1", ping.version == "v1", "version=\(ping.version ?? "nil")")
            counter.check("ping 带回 openid", !(ping.openid ?? "").isEmpty, ping.openid ?? "nil")
        } catch {
            counter.check("ping", false, describe(error))
            print("\n== 结果：\(counter.passed) 项通过，\(counter.failed) 项失败（连通失败，后续用例跳过）==")
            return 1
        }

        do {
            _ = try await api.ping(baseURL: baseURL, token: "0123456789abcdef0123456789abcdef0123456789abcdef")
            counter.check("非法 token 被拒绝", false, "居然通过了")
        } catch let error as CloudError {
            counter.check("非法 token 被拒绝（401 unauthorized）", error.isUnauthorized, error.code)
        } catch {
            counter.check("非法 token 被拒绝（401 unauthorized）", false, describe(error))
        }

        // MARK: 2. 写入与字段往返
        print("\n[2] 写入与字段往返")
        let samples: [Todo] = [
            Todo(content: "\(tag)交给张总的季度报表", deadline: now + 3_600_000, priority: .high,
                 source: .macScreenshot, rawText: "明天下午三点前把季度报表发给张总", createTime: now - 3000),
            Todo(content: "\(tag)买牛奶", priority: .normal,
                 source: .miniVoice, rawText: "还要买牛奶", createTime: now - 2000),
            Todo(content: "\(tag)整理桌面", priority: .low, status: .done,
                 source: .manual, createTime: now - 1000)
        ]
        let push: UpsertResult
        do {
            push = try await api.bulkUpsert(baseURL: baseURL, token: token, items: samples)
        } catch {
            counter.check("批量写入 3 条", false, describe(error))
            print("\n== 结果：\(counter.passed) 项通过，\(counter.failed) 项失败 ==")
            return 1
        }
        counter.check("批量写入 3 条", (push.applied?.count ?? 0) == 3, "applied=\(push.applied?.count ?? 0)")
        counter.check("写入未被拒绝", (push.rejected?.count ?? 0) == 0,
                      (push.rejected ?? []).compactMap(\.reason).joined(separator: ","))
        counter.check("服务端盖章 updateTime", (push.applied ?? []).allSatisfy { $0.updateTime >= now },
                      "最早 \(push.applied?.map(\.updateTime).min() ?? 0) vs 本地 \(now)")

        var cursor: Int64 = 0
        do {
            let page = try await api.list(baseURL: baseURL, token: token, since: 0, limit: 100)
            let items = page.items ?? []
            counter.check("首次全量拉取包含这 3 条", items.filter { $0.content.hasPrefix(tag) }.count == 3,
                          "共 \(items.count) 条")
            counter.check("游标前进", (page.cursor ?? 0) > 0, "cursor=\(page.cursor ?? 0)")
            counter.check("hasMore=false", page.hasMore == false)

            if let report = items.first(where: { $0.content == samples[0].content }) {
                counter.check("content 往返一致", report.content == samples[0].content)
                counter.check("deadline 往返一致", report.deadline == samples[0].deadline,
                              "\(report.deadline ?? -1) vs \(samples[0].deadline ?? -1)")
                counter.check("priority 往返一致", report.priority == .high, report.priority.rawValue)
                counter.check("source 往返一致", report.source == .macScreenshot, report.source.rawValue)
                counter.check("rawText 往返一致", report.rawText == samples[0].rawText)
                counter.check("status 往返一致", report.status == .todo, report.status.rawValue)
                counter.check("deleted 默认 false", report.deleted == false)
                counter.check("createTime 保留客户端值", report.createTime == samples[0].createTime,
                              "\(report.createTime) vs \(samples[0].createTime)")
                counter.check("updateTime 由服务端盖章（≠ 客户端原值或已更新）",
                              report.updateTime >= samples[0].updateTime)
            } else {
                counter.check("找到刚写入的报表条目", false)
            }
            if let done = items.first(where: { $0.content == samples[2].content }) {
                counter.check("已完成状态往返一致", done.status == .done, done.status.rawValue)
            }
            cursor = page.cursor ?? 0
        } catch {
            counter.check("首次全量拉取", false, describe(error))
        }

        // MARK: 3. LWW 冲突（旧版本必须被拒、新版本必须被接受）
        print("\n[3] LWW 冲突解决（契约 §2.4）")
        var staleAttempt = samples[0]
        staleAttempt.content = "\(tag)不该被写入的内容"
        staleAttempt.updateTime = 1                    // 远古时间戳，必然输给服务端版本

        do {
            let result = try await api.bulkUpsert(baseURL: baseURL, token: token, items: [staleAttempt])
            counter.check("旧版本被判 stale", (result.stale?.count ?? 0) == 1, "stale=\(result.stale?.count ?? 0)")
            counter.check("旧版本未被 applied", (result.applied?.count ?? 0) == 0)
            let authoritative = result.stale?.first
            counter.check("stale 回传完整文档（客户端可据此纠正本地）",
                          authoritative?.content == samples[0].content && authoritative?.deadline != nil,
                          authoritative?.content ?? "nil")
        } catch {
            counter.check("旧版本写入被拒", false, describe(error))
        }

        let changed = samples[1]
        var freshAttempt = changed
        freshAttempt.content = "\(tag)买牛奶（已改）"
        freshAttempt.updateTime = now + 100_000        // 领先服务端，必然获胜
        do {
            let result = try await api.bulkUpsert(baseURL: baseURL, token: token, items: [freshAttempt])
            counter.check("新版本被接受", (result.applied?.contains { $0.id == changed.id } ?? false),
                          "applied=\(result.applied?.count ?? 0)")
        } catch {
            counter.check("新版本被接受", false, describe(error))
        }

        // MARK: 4. 软删除与增量拉取
        print("\n[4] 软删除与增量游标（契约 §2.5 / §2.3）")
        do {
            let result = try await api.remove(baseURL: baseURL, token: token, ids: [samples[2].id])
            counter.check("remove 回执列出被删 id", result.removed?.contains(samples[2].id) == true)
        } catch {
            counter.check("软删除", false, describe(error))
        }

        do {
            let page = try await api.list(baseURL: baseURL, token: token, since: cursor, limit: 100)
            let items = page.items ?? []
            counter.check("增量只下发变化过的条目", items.count == 2, "\(items.count) 条：\(items.map(\.content))")
            counter.check("删除以 deleted=true 下发（其他端才能同步删除）",
                          items.first { $0.id == samples[2].id }?.deleted == true)
            counter.check("被拒的旧版本确实没写进去",
                          !items.contains { $0.content == "\(tag)不该被写入的内容" })
            counter.check("改动后的内容已下发",
                          items.first { $0.id == changed.id }?.content == "\(tag)买牛奶（已改）")
            cursor = page.cursor ?? cursor
        } catch {
            counter.check("增量拉取", false, describe(error))
        }

        // MARK: 5. 分页推进（150 条 → limit=100，两轮拉完，不丢不重）
        print("\n[5] 分页推进（契约 §2.3：limit=100 + 严格递增 updateTime 游标）")
        do {
            let many = (0..<150).map { index in
                Todo(content: "\(tag)分页第 \(index) 条", priority: .low,
                     source: .manual, createTime: now + Int64(index))
            }
            let ids = Set(many.map(\.id))
            let result = try await api.bulkUpsert(baseURL: baseURL, token: token, items: many)
            counter.check("150 条全部写入", (result.applied?.count ?? 0) == 150, "applied=\(result.applied?.count ?? 0)")

            var seen = Set<String>()
            var pageCursor = cursor
            var rounds = 0
            var hasMore = true
            var firstRoundCount = 0
            while hasMore && rounds < 6 {
                let page = try await api.list(baseURL: baseURL, token: token, since: pageCursor, limit: 100)
                let items = page.items ?? []
                items.forEach { seen.insert($0.id) }
                pageCursor = page.cursor ?? pageCursor
                hasMore = page.hasMore ?? false
                rounds += 1
                if rounds == 1 { firstRoundCount = items.count }
            }
            counter.check("第一轮返回整页 100 条", firstRoundCount == 100, "\(firstRoundCount) 条")
            counter.check("游标持续推进到拉空", !hasMore, "\(rounds) 轮")
            counter.check("150 条全部拉到且无重复丢失", ids.isSubset(of: seen), "共收到 \(seen.count) 条")
            cursor = pageCursor
        } catch {
            counter.check("分页推进", false, describe(error))
        }

        // MARK: 6. AI 解析（含登录态要求）
        print("\n[6] AI 结构化解析（契约 §3）")
        do {
            let result = try await api.parse(baseURL: baseURL, token: token,
                                            text: "明天下午三点前把季度报表发给张总，还要买牛奶",
                                            source: .macScreenshot)
            let todos = result.todos ?? []
            counter.check("返回结构化待办", !todos.isEmpty, "\(todos.count) 条：\(todos.map(\.content))")
            counter.check("engine 取值合法", ["deepseek", "rule"].contains(result.engine ?? ""),
                          result.engine ?? "nil")
            counter.check("每条都有内容", todos.allSatisfy { !$0.content.isEmpty })
            if result.engine == "rule" {
                counter.check("规则引擎识别出「报表」任务", todos.contains { $0.content.contains("报表") },
                              todos.map(\.content).joined(separator: " | "))
                counter.check("规则引擎拆出「买牛奶」", todos.contains { $0.content.contains("牛奶") })
            }
        } catch {
            counter.check("AI 解析", false, describe(error))
        }

        do {
            _ = try await api.parse(baseURL: baseURL, token: "bad-token", text: "测试", source: .manual)
            counter.check("未登录调用 ai 被拒绝", false, "居然通过了（会被人白烧额度）")
        } catch let error as CloudError {
            counter.check("未登录调用 ai 被拒绝（401）", error.isUnauthorized, error.code)
        } catch {
            counter.check("未登录调用 ai 被拒绝（401）", false, describe(error))
        }

        // MARK: 7. 真实 SyncEngine + LocalStore 闭环
        print("\n[7] 本地优先 + 增量同步闭环（真实 SyncEngine）")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktodo-itest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let suiteName = "com.dsh.quicktodo.itest.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
        settings.cloudBaseURL = baseURL
        let store = LocalStore(fileURL: sandbox.appendingPathComponent("store.json"))
        let engine = SyncEngine(store: store, settings: settings, api: api,
                                tokenProvider: { token }, onUnauthorized: {}, onDataChanged: {})

        var localA = Todo(content: "\(tag)本地新增 A", deadline: now + 7_200_000,
                          priority: .high, source: .manual)
        let localB = Todo(content: "\(tag)本地新增 B", source: .miniVoice, rawText: "语音原文")
        store.upsert(localA)
        store.upsert(localB)
        counter.check("写入本地后立即有数据（UI 不等网络）", store.visibleTodos.count == 2 && store.hasPendingChanges)

        await engine.sync(force: true)
        counter.check("上抛后 outbox 清空", !store.hasPendingChanges,
                      "仍有 \(store.outbox.count) 条待上传")
        counter.check("同步状态正常", engine.state == .idle, engine.state.label)

        do {
            // 走完整游标全量拉取：此时库里已有 150+ 条分页用例，单页 100 条是看不到新数据的
            let remote = try await fetchAll(api: api, baseURL: baseURL, token: token)
            counter.check("云端已存在本地新增的 A", remote.contains { $0.content == localA.content })
            counter.check("云端已存在本地新增的 B", remote.contains { $0.content == localB.content })
            // 服务端盖章时间必须回写到本地（否则下次会误判冲突）
            if let remoteA = remote.first(where: { $0.id == localA.id }) {
                store.applyRemote([remoteA], cursor: 0)
                counter.check("服务端盖章时间已回写本地", store.todos[localA.id]?.updateTime == remoteA.updateTime,
                              "\(store.todos[localA.id]?.updateTime ?? -1) vs \(remoteA.updateTime)")
            }
        } catch {
            counter.check("校验云端数据", false, describe(error))
        }

        // 第二次同步：勾选完成 + 删除，验证增量与软删除一起工作
        localA = store.todos[localA.id] ?? localA
        store.toggleDone(localA.id)
        store.remove(localB.id)
        await engine.sync(force: true)
        counter.check("第二轮同步后 outbox 清空", !store.hasPendingChanges)

        do {
            let remote = try await fetchAll(api: api, baseURL: baseURL, token: token)
            counter.check("完成状态已同步到云端",
                          remote.first { $0.id == localA.id }?.status == .done,
                          remote.first { $0.id == localA.id }?.status.rawValue ?? "nil")
            counter.check("删除已同步到云端（软删除）",
                          remote.first { $0.id == localB.id }?.deleted == true)
        } catch {
            counter.check("校验第二轮结果", false, describe(error))
        }

        // 模拟「另一台设备」：新建一个空 LocalStore，从 0 全量拉取，应该看到一模一样的状态
        let otherStore = LocalStore(fileURL: sandbox.appendingPathComponent("other.json"))
        let otherEngine = SyncEngine(store: otherStore, settings: settings, api: api,
                                     tokenProvider: { token }, onUnauthorized: {}, onDataChanged: {})
        await otherEngine.sync(force: true)
        counter.check("新设备全量拉取拿到同样的数据", otherStore.todos.count == store.todos.count,
                      "\(otherStore.todos.count) vs \(store.todos.count)")
        counter.check("新设备看到 A 是已完成", otherStore.todos[localA.id]?.status == .done)
        counter.check("新设备看到 B 已删除", otherStore.todos[localB.id]?.deleted == true)

        // 清理联调现场
        try? FileManager.default.removeItem(at: sandbox)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        print("\n== 结果：\(counter.passed) 项通过，\(counter.failed) 项失败 ==")
        return counter.failed == 0 ? 0 : 1
    }

    private static func describe(_ error: Error) -> String {
        if let cloud = error as? CloudError { return "\(cloud.code)：\(cloud.message)" }
        return error.localizedDescription
    }

    /// 走真实游标把云端数据全量拉完（等价于客户端启动时的全量同步）。
    @MainActor
    private static func fetchAll(api: QuickTodoAPI, baseURL: String, token: String) async throws -> [Todo] {
        var collected: [Todo] = []
        var cursor: Int64 = 0
        var hasMore = true
        var rounds = 0
        while hasMore && rounds < 20 {
            let page = try await api.list(baseURL: baseURL, token: token, since: cursor, limit: 100)
            collected.append(contentsOf: page.items ?? [])
            cursor = page.cursor ?? cursor
            hasMore = page.hasMore ?? false
            rounds += 1
        }
        return collected
    }
}
