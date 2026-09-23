import Foundation

/// Small helpers shared by the log scanners.
enum ScanPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where Codex CLI / the ChatGPT desktop app write rollout logs.
    static var codexSessions: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }
    static var codexGlobalState: URL { home.appendingPathComponent(".codex/.codex-global-state.json") }
    static var codexAuth: URL { home.appendingPathComponent(".codex/auth.json") }

    /// DSH (this harness) keeps its own session transcripts here.
    static var dshRoot: URL { home.appendingPathComponent(".dsh", isDirectory: true) }
    static var dshSessions: URL { dshRoot.appendingPathComponent("sessions", isDirectory: true) }
    static var dshCredentials: URL { dshRoot.appendingPathComponent(".credentials.yaml") }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("AITokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension Data {
    /// Case-sensitive byte search used to skip JSON parsing for irrelevant log lines.
    func containsBytes(of needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = count - needle.count
            let first = needle[0]
            var i = 0
            while i <= limit {
                if base[i] == first {
                    var j = 1
                    while j < needle.count, base[i + j] == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }
}

enum JSON {
    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(fromISO string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }

    static func dict(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    static func array(_ any: Any?) -> [Any]? { any as? [Any] }
}
