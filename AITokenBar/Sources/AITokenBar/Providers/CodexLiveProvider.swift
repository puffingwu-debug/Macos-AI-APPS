import Foundation

/// Optional live quota lookup for ChatGPT / Codex.
///
/// Codex CLI reads its quota from an undocumented endpoint that returns the very
/// same numbers the ChatGPT desktop app shows. Local rollout logs remain the
/// primary source (they work offline and need no token juggling), but when the
/// network allows, this gives a fresher reading — and it is the only way to see
/// quota before any local log exists.
///
/// Failures are expected (blocked network, expired token) and are never fatal:
/// the caller simply keeps the log-derived values.
final class CodexLiveProvider {

    struct LiveUsage {
        var windows: [QuotaWindow] = []
        var credits: CreditInfo?
        var planType: String?
        var fetchedAt: Date = Date()
    }

    enum LiveError: LocalizedError {
        case noAuth
        case http(Int)
        case network(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noAuth: return "未找到 ChatGPT 登录凭据"
            case .http(404): return "接口不存在 (404)"
            case .http(let code): return "接口返回 HTTP \(code)"
            case .network(let text): return "网络不可达：\(text)"
            case .malformed: return "接口返回内容无法解析"
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Reads `~/.codex/auth.json` (ChatGPT OAuth mode only).
    static func loadAuth() -> (token: String, accountID: String?)? {
        guard let data = try? Data(contentsOf: ScanPaths.codexAuth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = JSON.dict(root["tokens"]),
              let access = JSON.string(tokens["access_token"]), !access.isEmpty
        else { return nil }
        return (access, JSON.string(tokens["account_id"]))
    }

    func fetch() async throws -> LiveUsage {
        guard let auth = Self.loadAuth() else { throw LiveError.noAuth }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli/1.0", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LiveError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveError.malformed
        }

        var usage = LiveUsage()
        usage.planType = JSON.string(root["plan_type"])

        let rateLimit = JSON.dict(root["rate_limit"])
        if let primary = Self.window(from: JSON.dict(rateLimit?["primary_window"]), id: "live-primary") {
            usage.windows.append(primary)
        }
        if let secondary = Self.window(from: JSON.dict(rateLimit?["secondary_window"]), id: "live-secondary") {
            usage.windows.append(secondary)
        }

        if let credits = JSON.dict(root["credits"]) {
            usage.credits = CreditInfo(
                hasCredits: JSON.bool(credits["has_credits"]) ?? false,
                unlimited: JSON.bool(credits["unlimited"]) ?? false,
                balance: JSON.double(credits["balance"])
            )
        }
        guard !usage.windows.isEmpty else { throw LiveError.malformed }
        return usage
    }

    /// The backend reports `limit_window_seconds`; the rollout logs report minutes.
    private static func window(from dict: [String: Any]?, id: String) -> QuotaWindow? {
        guard let dict, let used = JSON.double(dict["used_percent"]) else { return nil }
        let minutes: Int? = JSON.double(dict["limit_window_seconds"]).map { Int(($0 / 60).rounded(.up)) }
        var resetsAt: Date?
        if let epoch = JSON.double(dict["reset_at"]), epoch > 0 {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = JSON.double(dict["reset_after_seconds"]), after > 0 {
            resetsAt = Date().addingTimeInterval(after)
        }
        return QuotaWindow(
            id: id,
            windowMinutes: minutes,
            usedPercent: used,
            resetsAt: resetsAt,
            label: QuotaWindow.label(forWindowMinutes: minutes)
        )
    }
}
