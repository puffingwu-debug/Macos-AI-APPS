import Foundation

/// Resolves API credentials from the places this machine already keeps them.
enum CredentialStore {

    struct Resolved {
        var key: String
        var source: String
    }

    /// Resolution order: explicit override → environment → DSH credential store.
    static func deepSeekKey(override: String) -> Resolved? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.hasPrefix("sk-") {
            return Resolved(key: trimmed, source: "手动设置")
        }

        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
           env.hasPrefix("sk-"), env.count > 10 {
            return Resolved(key: env, source: "环境变量")
        }

        if let fromDSH = parseDSHCredentials() {
            return Resolved(key: fromDSH, source: "~/.dsh/.credentials.yaml")
        }

        return nil
    }

    /// `~/.dsh/.credentials.yaml` is a tiny YAML file:
    /// ```yaml
    /// refs:
    ///   DEEPSEEK_API_KEY: sk-...
    /// ```
    private static func parseDSHCredentials() -> String? {
        guard let text = try? String(contentsOf: ScanPaths.dshCredentials, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("DEEPSEEK_API_KEY") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value.hasPrefix("sk-"), value.count > 10 { return value }
        }
        return nil
    }

    /// Never log or display a full key.
    static func mask(_ key: String) -> String {
        guard key.count > 10 else { return "****" }
        return key.prefix(6) + "…" + key.suffix(4)
    }
}
