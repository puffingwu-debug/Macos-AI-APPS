import Foundation

/// 云函数调用失败的结构化错误。
struct CloudError: Error, LocalizedError, Equatable {
    var code: String
    var message: String

    var errorDescription: String? { message }

    static let unauthorized = CloudError(code: "unauthorized", message: "登录态已失效，请重新扫码登录")
    static let noCloud = CloudError(code: "no_cloud", message: "尚未配置云端地址")

    var isUnauthorized: Bool { code == "unauthorized" }
}

// MARK: - 响应模型（对应契约 §2 / §3 / §4）

struct ErrorBody: Decodable {
    var code: String?
    var message: String?
}

struct ListResult: Decodable {
    var ok: Bool
    var items: [Todo]?
    var cursor: Int64?
    var hasMore: Bool?
    var serverTime: Int64?
    var error: ErrorBody?
}

struct AppliedItem: Decodable {
    var id: String
    var updateTime: Int64
}

struct RejectedItem: Decodable {
    var id: String?
    var reason: String?
}

struct UpsertResult: Decodable {
    var ok: Bool
    var applied: [AppliedItem]?
    var stale: [Todo]?
    var rejected: [RejectedItem]?
    var serverTime: Int64?
    var error: ErrorBody?
}

struct RemoveResult: Decodable {
    var ok: Bool
    var removed: [String]?
    var serverTime: Int64?
    var error: ErrorBody?
}

struct ParseResult: Decodable {
    var ok: Bool
    var engine: String?
    var model: String?
    var todos: [ParsedTodo]?
    var elapsedMs: Int?
    var notice: String?
    var fallbackText: String?
    var error: ErrorBody?
}

struct PingResult: Decodable {
    var ok: Bool
    var openid: String?
    var count: Int?
    var serverTime: Int64?
    var version: String?
    var error: ErrorBody?
}

struct TicketResult: Decodable {
    var ok: Bool
    var ticket: String?
    var qrPayload: String?
    var expiresIn: Int?
    var expireAt: Int64?
    var error: ErrorBody?
}

struct PollResult: Decodable {
    var ok: Bool
    var status: String?
    var token: String?
    var openid: String?
    var error: ErrorBody?
}

struct CheckResult: Decodable {
    var ok: Bool
    var openid: String?
    var expireAt: Int64?
    var error: ErrorBody?
}

// MARK: - 客户端

/// 走「云函数 HTTP 访问服务（云接入）」调用 `todo` / `ai` / `auth` 三个云函数。
///
/// - 客户端**不持有任何密钥**：DeepSeek key 在云函数环境变量里；
/// - 登录态用 Keychain 里的 session token，通过 `x-todo-token` 头传递；
/// - 云函数返回的 HTTP body 是 JSON 字符串（形如 `{statusCode, body}`），这里统一拆封。
final class QuickTodoAPI {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    /// 统一 POST 调用。
    /// - Parameters:
    ///   - path: 云接入触发路径，如 `todo` / `ai` / `auth`
    ///   - body: 业务参数（会被 JSON 序列化，必须含 `action`）
    ///   - baseURL: 云环境域名
    ///   - token: 会话 token，可为空
    ///   - timeout: 覆盖默认超时（AI 解析要放宽到 45s）
    func call(
        path: String,
        body: [String: Any],
        baseURL: String,
        token: String?,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "\(trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)/\(path)") else {
            throw CloudError.noCloud
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-todo-token")
        }
        if let timeout { request.timeoutInterval = timeout }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError(code: "network", message: "网络不可用：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudError(code: "internal", message: "响应格式异常")
        }

        let payload = try unwrap(data)
        let errorCode = (payload["error"] as? [String: Any])?["code"] as? String
        let failed = (payload["ok"] as? Bool) == false
        if http.statusCode == 401 || (failed && errorCode == "unauthorized") {
            throw CloudError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (payload["error"] as? [String: Any])?["message"] as? String
            throw CloudError(code: "http_\(http.statusCode)", message: message ?? "云端返回 \(http.statusCode)")
        }
        return payload
    }

    /// 拆 HTTP 访问服务的信封：`{statusCode, headers, body:"<json 字符串>"}` → 内层字典。
    private func unwrap(_ data: Data) throws -> [String: Any] {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CloudError(code: "bad_response", message: "无法解析云端响应：\(text.prefix(120))")
        }
        if let bodyString = object["body"] as? String,
           let inner = try? JSONSerialization.jsonObject(with: bodyString.data(using: .utf8) ?? Data()) as? [String: Any] {
            object = inner
        } else if let bodyObject = object["body"] as? [String: Any] {
            object = bodyObject
        }
        return object
    }

    /// 把任意 Encodable 请求体转成字典（拼装不定长参数时更顺手）。
    static func jsonObject<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 把 `{ok:false,error:{...}}` 转成抛出。
    static func checkOK(_ ok: Bool, error: ErrorBody?) throws {
        guard !ok else { return }
        let code = error?.code ?? "internal"
        throw CloudError(code: code, message: error?.message ?? "云端处理失败")
    }
}

// MARK: - 业务动作封装

extension QuickTodoAPI {

    func ping(baseURL: String, token: String?) async throws -> PingResult {
        let payload = try await call(path: "todo", body: ["action": "ping"], baseURL: baseURL, token: token, timeout: 15)
        let result = try decode(PingResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    /// 增量拉取。`limit` 固定 100 —— 云开发单次 `where().get()` 上限就是 100（契约 §2.3）。
    func list(baseURL: String, token: String?, since: Int64, limit: Int = 100) async throws -> ListResult {
        let body: [String: Any] = ["action": "list", "since": since, "limit": limit, "includeDeleted": true]
        let payload = try await call(path: "todo", body: body, baseURL: baseURL, token: token, timeout: 25)
        let result = try decode(ListResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    func bulkUpsert(baseURL: String, token: String?, items: [Todo]) async throws -> UpsertResult {
        let body: [String: Any] = ["action": "bulkUpsert", "items": items.map { Self.jsonObject($0) }]
        let payload = try await call(path: "todo", body: body, baseURL: baseURL, token: token, timeout: 30)
        let result = try decode(UpsertResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    func remove(baseURL: String, token: String?, ids: [String]) async throws -> RemoveResult {
        let body: [String: Any] = ["action": "remove", "ids": ids]
        let payload = try await call(path: "todo", body: body, baseURL: baseURL, token: token, timeout: 25)
        let result = try decode(RemoveResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    /// DeepSeek 结构化解析（异步，不阻塞 UI；失败时云函数会降级成规则引擎）。
    func parse(
        baseURL: String,
        token: String?,
        text: String,
        source: TodoSource,
        maxItems: Int = 8
    ) async throws -> ParseResult {
        let body: [String: Any] = [
            "action": "parse",
            "text": text,
            "source": source.rawValue,
            "now": Date.currentMillis,
            "timezone": TimeZone.current.identifier,
            "maxItems": maxItems
        ]
        let payload = try await call(path: "ai", body: body, baseURL: baseURL, token: token, timeout: 45)
        let result = try decode(ParseResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    // MARK: 扫码登录（契约 §4）

    func createLoginTicket(baseURL: String, deviceName: String) async throws -> TicketResult {
        let body: [String: Any] = ["action": "createTicket", "deviceName": deviceName]
        let payload = try await call(path: "auth", body: body, baseURL: baseURL, token: nil, timeout: 15)
        let result = try decode(TicketResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    func pollLoginTicket(baseURL: String, ticket: String) async throws -> PollResult {
        let body: [String: Any] = ["action": "pollTicket", "ticket": ticket]
        let payload = try await call(path: "auth", body: body, baseURL: baseURL, token: nil, timeout: 15)
        let result = try decode(PollResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }

    func checkToken(baseURL: String, token: String) async throws -> CheckResult {
        let body: [String: Any] = ["action": "check", "token": token]
        let payload = try await call(path: "auth", body: body, baseURL: baseURL, token: nil, timeout: 15)
        let result = try decode(CheckResult.self, from: payload)
        try Self.checkOK(result.ok, error: result.error)
        return result
    }
}
