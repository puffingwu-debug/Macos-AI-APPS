import Foundation

// MARK: - 枚举（取值必须与 docs/SYNC-PROTOCOL.md 完全一致）

enum TodoPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case normal
    case low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "高"
        case .normal: return "中"
        case .low: return "低"
        }
    }

    /// 未完成分组内的排序权重：高优先在前。
    var weight: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    /// AI 返回非法值时的兜底解析。
    static func parse(_ raw: String?) -> TodoPriority {
        guard let raw = raw?.lowercased() else { return .normal }
        switch raw {
        case "high", "urgent", "p1", "高", "紧急": return .high
        case "low", "p3", "低": return .low
        default: return .normal
        }
    }
}

enum TodoStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case done
}

enum TodoSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case macScreenshot = "mac-screenshot"
    case miniVoice = "mini-voice"
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .macScreenshot: return "截图"
        case .miniVoice: return "语音"
        case .manual: return "手动"
        }
    }

    var symbol: String {
        switch self {
        case .macScreenshot: return "camera.viewfinder"
        case .miniVoice: return "waveform"
        case .manual: return "square.and.pencil"
        }
    }

    static func parse(_ raw: String?) -> TodoSource {
        guard let raw = raw, let value = TodoSource(rawValue: raw) else { return .manual }
        return value
    }
}

// MARK: - 待办模型

/// 与云端 `todos` 集合一一对应的待办模型。
///
/// 时间字段一律是 Unix 毫秒。`updateTime` 由服务端盖章，是 LWW 冲突判定的唯一依据；
/// 本地自己改动时先乐观地写 `now`，收到服务端回执后再用服务端值覆盖。
struct Todo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var content: String
    var deadline: Int64?
    var priority: TodoPriority
    var status: TodoStatus
    var source: TodoSource
    var rawText: String
    var deleted: Bool
    var createTime: Int64
    var updateTime: Int64

    enum CodingKeys: String, CodingKey {
        case id, content, deadline, priority, status, source, rawText, deleted, createTime, updateTime
        // 云端可能回传这些字段，显式忽略即可（Decodable 默认忽略未知 key，这里仅为可读性列出）
        case openid, seq
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        content: String,
        deadline: Int64? = nil,
        priority: TodoPriority = .normal,
        status: TodoStatus = .todo,
        source: TodoSource = .manual,
        rawText: String = "",
        deleted: Bool = false,
        createTime: Int64 = Date.currentMillis,
        updateTime: Int64 = Date.currentMillis
    ) {
        self.id = id
        self.content = content
        self.deadline = deadline
        self.priority = priority
        self.status = status
        self.source = source
        self.rawText = rawText
        self.deleted = deleted
        self.createTime = createTime
        self.updateTime = updateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        // 服务端可能回传 null / 数字 / 数字字符串，统一容错
        if let value = try? c.decodeIfPresent(Int64.self, forKey: .deadline) {
            deadline = value
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .deadline) {
            deadline = Int64(text)
        } else {
            deadline = nil
        }
        priority = TodoPriority.parse(try? c.decodeIfPresent(String.self, forKey: .priority))
        status = TodoStatus(rawValue: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "" ) ?? .todo
        source = TodoSource.parse(try? c.decodeIfPresent(String.self, forKey: .source))
        rawText = (try? c.decodeIfPresent(String.self, forKey: .rawText)) ?? ""
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        createTime = (try? c.decodeIfPresent(Int64.self, forKey: .createTime)) ?? Date.currentMillis
        updateTime = (try? c.decodeIfPresent(Int64.self, forKey: .updateTime)) ?? createTime
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        if let deadline {
            try c.encode(deadline, forKey: .deadline)
        } else {
            try c.encodeNil(forKey: .deadline)
        }
        try c.encode(priority.rawValue, forKey: .priority)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(source.rawValue, forKey: .source)
        try c.encode(rawText, forKey: .rawText)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(createTime, forKey: .createTime)
        try c.encode(updateTime, forKey: .updateTime)
    }
}

// MARK: - 展示辅助

extension Todo {
    var isDone: Bool { status == .done }

    var isOverdue: Bool {
        guard !isDone, let deadline else { return false }
        return deadline < Date.currentMillis
    }

    /// 从 AI 解析结果构造待办草稿（导入前用户还可编辑）。
    static func from(parsed: ParsedTodo, source: TodoSource, rawText: String) -> Todo {
        Todo(
            content: parsed.content,
            deadline: parsed.deadline,
            priority: parsed.priority,
            source: source,
            rawText: rawText
        )
    }

    func withContent(_ text: String) -> Todo {
        var copy = self
        copy.content = text
        return copy
    }
}

/// AI 解析出来的单条结果（见契约 §3.2）。
struct ParsedTodo: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString.lowercased()
    var content: String
    var deadline: Int64?
    var priority: TodoPriority

    enum CodingKeys: String, CodingKey { case content, deadline, priority }

    init(content: String, deadline: Int64? = nil, priority: TodoPriority = .normal) {
        self.content = content
        self.deadline = deadline
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        if let value = try? c.decodeIfPresent(Int64.self, forKey: .deadline) {
            deadline = value
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .deadline) {
            deadline = Int64(text) ?? ISO8601DateFormatter().date(from: text).map { Int64($0.timeIntervalSince1970 * 1000) }
        } else {
            deadline = nil
        }
        priority = TodoPriority.parse(try? c.decodeIfPresent(String.self, forKey: .priority))
    }
}

// MARK: - 排序（契约 §5.5，两端必须一致）

enum TodoSortMode: String, CaseIterable, Identifiable {
    case smart      // 优先级 → 截止时间 → 创建时间
    case createdAt  // 创建时间倒序

    var id: String { rawValue }
    var label: String { self == .smart ? "按优先级" : "按创建时间" }
}

struct TodoGroups {
    var pending: [Todo] = []
    var done: [Todo] = []

    var isEmpty: Bool { pending.isEmpty && done.isEmpty }
}

extension Array where Element == Todo {
    /// 未完成：priority 权重升序 → deadline 升序（无截止排最后）→ createTime 降序。
    /// 已完成：updateTime 降序。分组顺序固定为未完成在前。
    func groupedAndSorted(by mode: TodoSortMode) -> TodoGroups {
        let alive = filter { !$0.deleted }
        var groups = TodoGroups()

        groups.pending = alive.filter { !$0.isDone }.sorted { lhs, rhs in
            if mode == .createdAt {
                return lhs.createTime > rhs.createTime
            }
            if lhs.priority.weight != rhs.priority.weight {
                return lhs.priority.weight < rhs.priority.weight
            }
            switch (lhs.deadline, rhs.deadline) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.createTime > rhs.createTime
            }
        }

        // 已完成：updateTime 降序；同一毫秒完成的用 createTime 兜底，避免列表跳动
        // （与小程序端 utils/store.js 的次级排序键保持一致）
        groups.done = alive.filter { $0.isDone }.sorted { lhs, rhs in
            if lhs.updateTime != rhs.updateTime { return lhs.updateTime > rhs.updateTime }
            return lhs.createTime > rhs.createTime
        }
        return groups
    }
}

extension Date {
    /// 契约里的所有时间戳都是 Unix 毫秒。
    static var currentMillis: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
