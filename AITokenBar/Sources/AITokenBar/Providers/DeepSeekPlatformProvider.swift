import Foundation

/// Reads DeepSeek's own usage dashboard through the private endpoints that
/// platform.deepseek.com calls.
///
/// Why this exists: DeepSeek publishes no usage-statistics API. `GET /user/balance`
/// gives a balance and nothing else, so cumulative spend, request counts and
/// per-period token totals are only visible in the web dashboard. Those numbers are
/// what a user comparing against the dashboard expects to see.
///
/// These endpoints are undocumented and authenticated by the browser's `userToken`
/// rather than an API key, so this provider is strictly optional and entirely
/// defensive: every field is treated as `String | Number`, every envelope level is
/// unwrapped leniently, and any failure degrades to the locally computed figures.
final class DeepSeekPlatformProvider {

    enum PlatformError: LocalizedError {
        case noToken
        case unauthorized
        case http(Int)
        case network(String)
        case business(code: Int, message: String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noToken: return "未填写平台会话 Token"
            case .unauthorized: return "平台 Token 已失效，请重新获取"
            case .http(401), .http(403): return "平台 Token 被拒绝"
            case .http(let code): return "平台接口返回 HTTP \(code)"
            case .network(let text): return "网络不可达：\(text)"
            case .business(let code, let message): return "平台返回错误 \(code)：\(message)"
            case .malformed: return "平台返回内容无法解析"
            }
        }
    }

    private let session: URLSession
    private let base = "https://platform.deepseek.com"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Fetches the dashboard figures for the last `days` days.
    func fetch(token: String, days: Int = 1) async throws -> PlatformFigures {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlatformError.noToken }

        let calendar = Calendar.current
        let tzSeconds = calendar.timeZone.secondsFromGMT(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: calendar.startOfDay(for: Date())) ?? Date()

        var figures = PlatformFigures()
        figures.periodDays = max(1, days)

        // 1. Account summary → cumulative spend + wallet balances.
        if let biz = try? await get("/api/v0/users/get_user_summary", token: trimmed, query: []) {
            let root = JSON.dict(biz) ?? [:]
            if let costs = JSON.array(root["total_costs"]) {
                figures.cumulativeSpend = costs
                    .compactMap { JSON.dict($0) }
                    .first { (JSON.string($0["currency"]) ?? "CNY").uppercased() == preferredCurrency(root) }
                    .flatMap { JSON.scalar($0["amount"]) }
                    ?? costs.compactMap { JSON.dict($0) }.first.flatMap { JSON.scalar($0["amount"]) }
            }
            figures.currency = preferredCurrency(root)
        }

        // 2. Tokens + request counts for the window.
        let amountQuery = [
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(tzSeconds)),
        ]
        if let biz = try? await get("/api/v0/usage/by_api_key/amount", token: trimmed, query: amountQuery),
           let root = JSON.dict(biz),
           let series = JSON.array(root["series"]) {
            var tokens = 0, requests = 0
            var prompt = 0, hit = 0, miss = 0, response = 0
            for entry in series {
                guard let entry = JSON.dict(entry), let buckets = JSON.array(entry["buckets"]) else { continue }
                for bucket in buckets {
                    guard let usage = JSON.dict(JSON.dict(bucket)?["usage"]) else { continue }
                    let hitTokens = Int(JSON.scalar(usage["PROMPT_CACHE_HIT_TOKEN"]) ?? 0)
                    let missTokens = Int(JSON.scalar(usage["PROMPT_CACHE_MISS_TOKEN"]) ?? 0)
                    let responseTokens = Int(JSON.scalar(usage["RESPONSE_TOKEN"]) ?? 0)
                    // PROMPT_TOKEN is a prompt total that only appears when no cache
                    // split exists, so it is reported but never added in.
                    let promptTotal = Int(JSON.scalar(usage["PROMPT_TOKEN"]) ?? 0)
                    let requestCount = Int(JSON.scalar(usage["REQUEST"]) ?? 0)

                    hit += hitTokens
                    miss += missTokens
                    response += responseTokens
                    prompt += promptTotal
                    requests += requestCount
                    tokens += responseTokens + hitTokens + missTokens
                }
            }
            figures.periodTokens = tokens
            figures.periodRequests = requests
            figures.cacheHitTokens = hit
            figures.cacheMissTokens = miss
            figures.responseTokens = response
            if prompt > 0 && hit == 0 && miss == 0 { figures.promptTokens = prompt }
        }

        // 3. Cost for the same window.
        if let biz = try? await get("/api/v0/usage/by_api_key/cost", token: trimmed, query: amountQuery),
           let root = JSON.dict(biz),
           let currencyGroups = JSON.array(root["data"]) {
            let preferred = figures.currency.uppercased()
            var chosen: Double?
            var fallback: Double?
            for group in currencyGroups {
                guard let group = JSON.dict(group),
                      let series = JSON.array(group["series"]) else { continue }
                var total = 0.0
                for entry in series {
                    guard let entry = JSON.dict(entry), let buckets = JSON.array(entry["buckets"]) else { continue }
                    for bucket in buckets {
                        // The cost endpoint also emits a REQUEST row whose value is a
                        // count, not money; only `cost` is summed here.
                        total += JSON.scalar(JSON.dict(bucket)?["cost"]) ?? 0
                    }
                }
                let currency = (JSON.string(group["currency"]) ?? "CNY").uppercased()
                if currency == preferred { chosen = total }
                if fallback == nil, total > 0 { fallback = total }
            }
            figures.periodCost = chosen ?? fallback ?? 0
        }

        return figures
    }

    private func preferredCurrency(_ root: [String: Any]) -> String {
        // CNY first: this is the account's own currency on the CN platform.
        for key in ["normal_wallets", "bonus_wallets"] {
            if let wallets = JSON.array(root[key]),
               let match = wallets.compactMap({ JSON.dict($0) })
                .first(where: { (JSON.string($0["currency"]) ?? "").uppercased() == "CNY" }),
               let currency = JSON.string(match["currency"]) {
                return currency.uppercased()
            }
        }
        for key in ["normal_wallets", "bonus_wallets"] {
            if let wallets = JSON.array(root[key]),
               let currency = wallets.compactMap({ JSON.dict($0) }).first.flatMap({ JSON.string($0["currency"]) }) {
                return currency.uppercased()
            }
        }
        return "CNY"
    }

    // MARK: - Transport

    /// Performs a request and unwraps the `{code, data:{biz_code, biz_data}}` envelope.
    private func get(_ path: String, token: String, query: [URLQueryItem]) async throws -> Any {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw PlatformError.malformed }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        request.setValue(base, forHTTPHeaderField: "Origin")
        request.setValue("\(base)/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlatformError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw PlatformError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw PlatformError.http(http.statusCode) }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlatformError.malformed
        }

        // Business codes are checked before the payload is decoded, because error
        // envelopes are not schema-stable (`data` may be a bare string).
        if let code = JSON.int(root["code"]), code != 0 {
            if Self.isAuthCode(code) { throw PlatformError.unauthorized }
            throw PlatformError.business(code: code, message: JSON.string(root["msg"]) ?? "")
        }
        guard let envelope = JSON.dict(root["data"]) else { throw PlatformError.malformed }
        if let bizCode = JSON.int(envelope["biz_code"]), bizCode != 0 {
            if Self.isAuthCode(bizCode) { throw PlatformError.unauthorized }
            throw PlatformError.business(code: bizCode, message: JSON.string(envelope["biz_msg"]) ?? "")
        }
        guard let biz = envelope["biz_data"], !(biz is NSNull) else { throw PlatformError.malformed }
        return biz
    }

    private static func isAuthCode(_ code: Int) -> Bool { code == 40002 || code == 40003 }
}

extension JSON {
    /// Accepts `String | Int | Double | Bool | null` and yields a Double.
    /// The platform mixes all of these for the same logical field.
    static func scalar(_ any: Any?) -> Double? {
        switch any {
        case nil, is NSNull: return nil
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue.isFinite ? value.doubleValue : nil
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
