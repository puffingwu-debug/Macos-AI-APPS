import AppKit
import Foundation

/// 自检：`QuickTodo --selftest`
///
/// 用来在没有 GUI 的情况下验证最容易出错的三块：
/// 1. 数据模型与 `docs/SYNC-PROTOCOL.md` 的字段是否逐字一致（多/少一个字段都会让多端对不上）；
/// 2. 本地规则解析器对中文时间/优先级的识别；
/// 3. **真实的 OCR 链路**：渲染一张中文图片 → 系统 Vision 识别 → 文本。
///
/// 这是开发期的验证工具，正常使用不会触发。
enum SelfTest {

    @MainActor
    static func run() -> Int32 {
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

        print("== QuickTodo 自检 ==")

        // MARK: 1. 契约字段
        print("\n[1] 数据模型 ↔ 契约字段")
        let sample = Todo(
            id: "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
            content: "把季度报表发给张总",
            deadline: 1_712_386_800_000,
            priority: .high,
            status: .todo,
            source: .macScreenshot,
            rawText: "明天下午三点前把季度报表发给张总",
            createTime: 1_712_345_678_901,
            updateTime: 1_712_345_678_901
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sample),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("  ❌ Todo 编码失败")
            return 1
        }
        let expectedKeys: Set<String> = ["id", "content", "deadline", "priority", "status",
                                        "source", "rawText", "deleted", "createTime", "updateTime"]
        let actualKeys = Set(object.keys)
        check("字段集合与契约一致", actualKeys == expectedKeys,
              actualKeys == expectedKeys ? "10 个字段" : "多了 \(actualKeys.subtracting(expectedKeys)) 少了 \(expectedKeys.subtracting(actualKeys))")
        check("source 取值", object["source"] as? String == "mac-screenshot", object["source"] as? String ?? "nil")
        check("priority 取值", object["priority"] as? String == "high", object["priority"] as? String ?? "nil")
        check("status 取值", object["status"] as? String == "todo", object["status"] as? String ?? "nil")

        // 服务端会回传 _id/openid/seq 等额外字段，且 deadline 可能是 null —— 客户端必须能容错解析
        let serverJSON = """
        {"_id":"abc","id":"abc","openid":"oXXX","seq":12,"content":"买牛奶","deadline":null,
         "priority":"normal","status":"done","source":"mini-voice","rawText":"买牛奶",
         "deleted":false,"createTime":1712345678901,"updateTime":1712345699999}
        """
        if let todo = try? JSONDecoder().decode(Todo.self, from: Data(serverJSON.utf8)) {
            check("容忍服务端额外字段与 null deadline", todo.deadline == nil && todo.status == .done && todo.source == .miniVoice)
        } else {
            check("容忍服务端额外字段与 null deadline", false, "解码抛错")
        }

        // MARK: 2. 排序
        print("\n[2] 分组排序（契约 §5.5）")
        let now = Date.currentMillis
        var list: [Todo] = [
            Todo(content: "低优先无截止", priority: .low, createTime: now - 3000),
            Todo(content: "高优先无截止", priority: .high, createTime: now - 2000),
            Todo(content: "高优先有截止", deadline: now + 60_000, priority: .high, createTime: now - 1000),
            Todo(content: "已完成的", priority: .high, status: .done, createTime: now)
        ]
        list[3].updateTime = now + 5000
        let groups = list.groupedAndSorted(by: .smart)
        check("未完成 3 条 / 已完成 1 条", groups.pending.count == 3 && groups.done.count == 1)
        check("高优先 + 有截止 排最前", groups.pending.first?.content == "高优先有截止", groups.pending.first?.content ?? "nil")
        check("低优先排最后", groups.pending.last?.content == "低优先无截止", groups.pending.last?.content ?? "nil")

        // MARK: 3. 本地规则解析
        print("\n[3] 本地规则解析")
        struct ParserCase {
            var input: String
            var content: String
            var priority: TodoPriority
            var hasDeadline: Bool
            var count: Int
        }
        let parserCases: [ParserCase] = [
            // 中文数字钟点 + 时段词 + 连接词拆句 + 时间词要从内容里去掉
            ParserCase(input: "明天下午三点前把季度报表发给张总，还要买牛奶",
                       content: "把季度报表发给张总", priority: .normal, hasDeadline: true, count: 2),
            ParserCase(input: "今天 18:00 前提交周报",
                       content: "提交周报", priority: .normal, hasDeadline: true, count: 1),
            ParserCase(input: "1. 尽快联系供应商\n2. 有空整理桌面",
                       content: "尽快联系供应商", priority: .high, hasDeadline: false, count: 2),
            ParserCase(input: "下周三下午两点和张总对齐需求",
                       content: "和张总对齐需求", priority: .normal, hasDeadline: true, count: 1)
        ]
        for item in parserCases {
            let results = LocalQuickParser.parse(item.input, source: .macScreenshot)
            let label = String(item.input.prefix(16))
            check("「\(label)…」拆出 \(item.count) 条", results.count == item.count, "得到 \(results.map(\.content))")
            check("「\(label)…」内容为「\(item.content)」", results.contains { $0.content == item.content },
                  results.map(\.content).joined(separator: " | "))
            check("「\(label)…」优先级 \(item.priority.label)",
                  results.contains { $0.priority == item.priority },
                  results.map(\.priority.label).joined(separator: ","))
            check("「\(label)…」截止时间\(item.hasDeadline ? "识别到" : "应为空")",
                  item.hasDeadline == results.contains { $0.deadline != nil },
                  results.compactMap(\.deadline).map { TimeText.deadline($0) }.joined(separator: ", "))
        }

        if let soon = LocalQuickParser.parse("明天下午3点开会", source: .manual).first, let deadline = soon.deadline {
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(deadline) / 1000))
            check("「明天下午3点」→ 15 点", hour == 15, "解析为 \(hour) 点 · \(TimeText.deadline(deadline))")
        } else {
            check("「明天下午3点」→ 15 点", false, "没解析出时间")
        }
        if let noon = LocalQuickParser.parse("周三上午十点站会", source: .manual).first, let deadline = noon.deadline {
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(deadline) / 1000))
            check("「上午十点」→ 10 点", hour == 10, "解析为 \(hour) 点")
            check("「上午十点」不误判为下午", hour < 12)
        } else {
            check("「上午十点」→ 10 点", false, "没解析出时间")
        }

        // 契约 §3.4：只说日期不说时间 → 当天 23:59:59.999
        if let dayOnly = LocalQuickParser.parse("3月5日交年报", source: .manual).first, let deadline = dayOnly.deadline {
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(deadline) / 1000))
            check("只给日期 → 23:59:59",
                  parts.hour == 23 && parts.minute == 59 && parts.second == 59,
                  "\(parts.hour ?? -1):\(parts.minute ?? -1):\(parts.second ?? -1)")
            check("月份日期不留在内容里", dayOnly.content == "交年报", dayOnly.content)
        } else {
            check("只给日期 → 23:59:59", false, "没解析出时间")
        }

        // MARK: 4. 真实 OCR 链路
        print("\n[4] Vision OCR（渲染图片 → 识别）")
        let sampleText = "明天下午三点前把季度报表发给张总\n还要买牛奶"
        guard let imageURL = renderTextToPNG(sampleText) else {
            check("渲染测试图片", false)
            printSummary(passed: passed, failed: failed)
            return failed == 0 ? 0 : 1
        }
        check("渲染测试图片", true, imageURL.lastPathComponent)

        let semaphore = DispatchSemaphore(value: 0)
        var recognized = ""
        var ocrError: String?
        Task {
            do {
                recognized = try await OCRService.recognizeText(in: imageURL)
            } catch {
                ocrError = error.localizedDescription
            }
            semaphore.signal()
        }
        // 自检是命令行同步流程，这里等待异步 OCR 完成
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        try? FileManager.default.removeItem(at: imageURL)

        if let ocrError {
            check("OCR 识别", false, ocrError)
        } else {
            print("  识别结果：\(recognized.replacingOccurrences(of: "\n", with: " / "))")
            check("识别出「报表」", recognized.contains("报表"))
            check("识别出「张总」", recognized.contains("张总"))
            check("识别出「牛奶」", recognized.contains("牛奶"))
            check("保持阅读顺序（报表在牛奶之前）",
                  (recognized.range(of: "报表")?.lowerBound).map { r in
                      (recognized.range(of: "牛奶")?.lowerBound).map { m in r < m } ?? false
                  } ?? false)

            // 端到端：OCR 文本 → 本地解析 → 待办
            let todos = LocalQuickParser.parse(recognized, source: .macScreenshot)
            check("OCR 文本能解析出 ≥1 条待办", !todos.isEmpty, "\(todos.count) 条：\(todos.map(\.content))")
        }

        // MARK: 5. 混合逻辑时钟（防止本机时钟偏慢导致本地改动被判 stale 而丢失）
        print("\n[5] 本地时钟保护与 LWW 时间戳")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktodo-clock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let store = LocalStore(fileURL: sandbox.appendingPathComponent("store.json"))

        // 模拟「本机时钟比服务器慢 1 小时」：同步时已经见过服务端时间
        let serverAhead = Date.currentMillis + 3_600_000
        store.observeServerTime(serverAhead)
        let guardTodo = Todo(content: "时钟保护用例")
        store.upsert(guardTodo)
        let stamped = store.todos[guardTodo.id]?.updateTime ?? 0
        check("本地改动时间戳排在已知服务端版本之后", stamped > serverAhead, "\(stamped) vs \(serverAhead)")

        let secondTodo = Todo(content: "同一毫秒内再写一条")
        store.upsert(secondTodo)
        let stamped2 = store.todos[secondTodo.id]?.updateTime ?? 0
        check("连续写入时间戳严格递增（游标必然前进）", stamped2 > stamped, "\(stamped2) vs \(stamped)")

        store.adoptServerStamps([AppliedItem(id: guardTodo.id, updateTime: serverAhead + 10)],
                                pushedStamps: [guardTodo.id: stamped])
        check("上抛后采用服务端盖章时间", store.todos[guardTodo.id]?.updateTime == serverAhead + 10,
              "\(store.todos[guardTodo.id]?.updateTime ?? -1)")

        store.adoptServerStamps([AppliedItem(id: secondTodo.id, updateTime: stamped2 + 500)],
                                pushedStamps: [secondTodo.id: stamped2 + 1])
        check("推送后又被改动过则不覆盖时间戳（避免把并发改动改小）",
              store.todos[secondTodo.id]?.updateTime == stamped2)

        let reloaded = LocalStore(fileURL: sandbox.appendingPathComponent("store.json"))
        check("时钟水位与发号器随本地缓存持久化", reloaded.lastServerTime >= serverAhead && reloaded.lastIssuedStamp >= stamped2,
              "server=\(reloaded.lastServerTime) issued=\(reloaded.lastIssuedStamp)")
        try? FileManager.default.removeItem(at: sandbox)

        printSummary(passed: passed, failed: failed)
        return failed == 0 ? 0 : 1
    }

    private static func printSummary(passed: Int, failed: Int) {
        print("\n== 结果：\(passed) 项通过，\(failed) 项失败 ==")
    }

    /// 把文字画进 PNG，用来验证 OCR 全链路（不依赖屏幕录制权限）。
    private static func renderTextToPNG(_ text: String) -> URL? {
        let size = NSSize(width: 760, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: NSRect(x: 24, y: 40, width: size.width - 48, height: size.height - 60),
                                withAttributes: attributes)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktodo-ocr-selftest.png")
        try? png.write(to: url)
        return url
    }
}
