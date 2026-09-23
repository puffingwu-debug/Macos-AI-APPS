import Foundation

/// ChatGPT / Codex subscription tier, plus the account name when we can find it.
///
/// Three sources, freshest first:
///  1. the live usage endpoint's `plan_type`,
///  2. the `chatgpt_plan_type` claim inside `~/.codex/auth.json`'s id_token
///     (a plain JWT — decoding it needs no network and no signature check),
///  3. the `plan_type` field on rate-limit snapshots in the rollout logs.
struct CodexPlan: Hashable, Sendable {
    var rawType: String?
    var accountName: String?
    var activeUntil: Date?
    var source: String?

    var displayName: String {
        guard let raw = rawType?.lowercased(), !raw.isEmpty else { return "未知" }
        switch raw {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return "Enterprise"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        default: return raw.uppercased()
        }
    }

    /// Short form for the badge.
    var badgeText: String {
        guard let raw = rawType?.lowercased(), !raw.isEmpty else { return "?" }
        switch raw {
        case "prolite": return "PRO LITE"
        case "self_serve_business_prolite", "self_serve_business_usage_based": return "BUSINESS"
        case "enterprise_cbp_automation", "enterprise_cbp_usage_based": return "ENTERPRISE"
        default: return displayName.uppercased()
        }
    }

    /// Paid tiers get the accent treatment and a crown.
    var isPaid: Bool {
        guard let raw = rawType?.lowercased() else { return false }
        return raw != "free" && raw != "unknown"
    }

    var hasPlan: Bool {
        guard let raw = rawType, !raw.isEmpty else { return false }
        return raw.lowercased() != "unknown"
    }

    var symbol: String {
        switch rawType?.lowercased() {
        case "pro", "prolite": return "crown.fill"
        case "plus", "go": return "star.fill"
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return "person.2.fill"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return "building.2.fill"
        case "edu", "edu_plus", "edu_pro": return "graduationcap.fill"
        case "free": return "person.fill"
        default: return "crown.fill"
        }
    }
}

/// Reads the plan out of `~/.codex/auth.json` without touching the network.
final class CodexPlanReader {

    private var cached: CodexPlan?
    private var cachedMtime: Double = -1
    private let lock = NSLock()

    func read() -> CodexPlan {
        lock.lock()
        defer { lock.unlock() }

        let url = ScanPaths.codexAuth
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return cached ?? CodexPlan() }

        if abs(mtime - cachedMtime) < 0.001, let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = JSON.dict(root["tokens"])
        else { return cached ?? CodexPlan() }

        var plan = CodexPlan()
        if let idToken = JSON.string(tokens["id_token"]),
           let claims = Self.decodeJWTPayload(idToken) {
            plan.accountName = JSON.string(claims["name"]) ?? JSON.string(claims["email"])
            if let auth = JSON.dict(claims["https://api.openai.com/auth"]) {
                plan.rawType = JSON.string(auth["chatgpt_plan_type"])
                plan.activeUntil = JSON.date(fromISO: JSON.string(auth["chatgpt_subscription_active_until"]))
            }
            plan.source = "登录凭据"
        }

        cached = plan
        cachedMtime = mtime
        return plan
    }

    /// Decodes the payload segment of a JWT. The signature is deliberately not
    /// verified: this is a local file the OS already protects, and we only read
    /// display metadata from it.
    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
