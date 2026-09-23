import Foundation

/// Talks to DeepSeek's official open-platform API.
///
/// `GET /user/balance` is the only documented account endpoint, so it is the one
/// authoritative number this widget can pull from the network. Token-level usage
/// is reconstructed locally (see `DSHLogScanner`) and spend is derived from
/// balance deltas (see `BalanceLedger`).
final class DeepSeekProvider {

    struct Balance {
        var isAvailable: Bool
        var currency: String
        var total: Double
        var granted: Double
        var toppedUp: Double
    }

    enum ProviderError: LocalizedError {
        case missingKey
        case http(Int)
        case network(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "未找到 DeepSeek API Key"
            case .http(let code) where code == 401:
                return "API Key 无效 (401)"
            case .http(let code) where code == 429:
                return "请求过于频繁 (429)"
            case .http(let code):
                return "接口返回 HTTP \(code)"
            case .network(let message):
                return "网络错误：\(message)"
            case .malformed:
                return "接口返回内容无法解析"
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "AITokenBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    func fetchBalance(key: String) async throws -> Balance {
        guard !key.isEmpty else { throw ProviderError.missingKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = JSON.array(root["balance_infos"]),
              let first = JSON.dict(infos.first)
        else { throw ProviderError.malformed }

        return Balance(
            isAvailable: JSON.bool(root["is_available"]) ?? false,
            currency: JSON.string(first["currency"]) ?? "CNY",
            total: JSON.double(first["total_balance"]) ?? 0,
            granted: JSON.double(first["granted_balance"]) ?? 0,
            toppedUp: JSON.double(first["topped_up_balance"]) ?? 0
        )
    }
}
