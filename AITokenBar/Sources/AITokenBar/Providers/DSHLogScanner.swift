import Foundation
import CZstdShim

/// Aggregates token usage from DSH session transcripts.
///
/// DSH (the harness this widget was built in) writes one `session.v3.jsonl.zstd`
/// per conversation. Each `assistant/message` record carries a `usage` block with
/// input / output / cache-read / reasoning token counts, and the preceding
/// `request/header` record names the provider and model that produced it.
///
/// That makes these transcripts the most accurate *local* record of DeepSeek API
/// token consumption on this machine.
final class DSHLogScanner {

    struct FileState: Codable {
        var size: Int64 = 0
        var mtime: Double = 0
        /// day key -> provider -> usage
        var daily: [String: [String: TokenUsage]] = [:]
        /// Same shape, but only the requests served during DeepSeek peak hours.
        var peak: [String: [String: TokenUsage]] = [:]
    }

    /// Usage rolled up over the windows the widget displays.
    struct UsageWindows: Sendable {
        var today = TokenUsage()
        var week = TokenUsage()
        var month = TokenUsage()
        /// Subsets of the above that fell inside DeepSeek peak pricing hours.
        var peakToday = TokenUsage()
        var peakWeek = TokenUsage()
    }

    struct Result {
        /// provider -> day key -> usage
        var byProvider: [String: [String: TokenUsage]] = [:]
        /// provider -> day key -> peak-hour usage
        var peakByProvider: [String: [String: TokenUsage]] = [:]
        var lastEventAt: Date?
        var filesScanned = 0
        var available = true
        var errorText: String?

        func usage(providerPrefix: String, days: Int) -> UsageWindows {
            let calendar = Calendar.current
            let todayKey = DayKey.key(for: Date(), calendar: calendar)
            let weekStartKey = DayKey.key(for: calendar.startOfDay(for: Date().addingTimeInterval(-6 * 86_400)), calendar: calendar)
            let monthStartKey = DayKey.key(for: calendar.startOfDay(for: Date().addingTimeInterval(-29 * 86_400)), calendar: calendar)

            var out = UsageWindows()
            for (provider, days) in byProvider where provider.hasPrefix(providerPrefix) {
                for (day, usage) in days {
                    if day == todayKey { out.today += usage }
                    if day >= weekStartKey { out.week += usage }
                    if day >= monthStartKey { out.month += usage }
                }
            }
            for (provider, days) in peakByProvider where provider.hasPrefix(providerPrefix) {
                for (day, usage) in days {
                    if day == todayKey { out.peakToday += usage }
                    if day >= weekStartKey { out.peakWeek += usage }
                }
            }
            return out
        }

        /// Per-day totals across every provider matching `providerPrefix`,
        /// oldest first, padded with empty days so the strip stays evenly spaced.
        func dailySeries(providerPrefix: String, days: Int) -> [DayUsage] {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            return (0..<days).reversed().compactMap { offset -> DayUsage? in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let key = DayKey.key(for: day, calendar: calendar)
                var total = TokenUsage()
                for (provider, dayMap) in byProvider where provider.hasPrefix(providerPrefix) {
                    if let usage = dayMap[key] { total += usage }
                }
                return DayUsage(day: day, usage: total)
            }
        }

        /// Provider id -> total tokens over the retained window.
        var providerTotals: [String: Int] {
            var out: [String: Int] = [:]
            for (provider, days) in byProvider {
                out[provider] = days.values.reduce(0) { $0 + $1.total }
            }
            return out
        }
    }

    private var states: [String: FileState] = [:]
    private let lock = NSLock()
    private let cacheURL = ScanPaths.appSupport.appendingPathComponent("dsh-scan-cache.json")

    private static let usageMarker: [UInt8] = Array("\"usage\":".utf8)
    private static let assistantMarker: [UInt8] = Array("assistant/message".utf8)
    private static let headerMarker: [UInt8] = Array("request/header".utf8)

    init() { load() }

    func refresh(retentionDays: Int = 31) -> Result {
        lock.lock()
        defer { lock.unlock() }

        var result = Result()
        let fm = FileManager.default
        guard fm.fileExists(atPath: ScanPaths.dshSessions.path) else {
            result.available = false
            result.errorText = "未找到 ~/.dsh/sessions"
            return result
        }

        let files = sessionFiles()
        guard !files.isEmpty else {
            result.available = false
            result.errorText = "DSH 会话目录为空"
            return result
        }

        for file in files {
            let state = scan(file: file, retentionDays: retentionDays)
            states[file.path] = state
            result.filesScanned += 1
            for (day, providers) in state.daily {
                for (provider, usage) in providers {
                    result.byProvider[provider, default: [:]][day, default: TokenUsage()] += usage
                }
            }
            for (day, providers) in state.peak {
                for (provider, usage) in providers {
                    result.peakByProvider[provider, default: [:]][day, default: TokenUsage()] += usage
                }
            }
        }

        // Drop cache entries for transcripts that no longer exist.
        let live = Set(files.map(\.path))
        for path in states.keys where !live.contains(path) { states.removeValue(forKey: path) }

        saveIfNeeded()
        return result
    }

    // MARK: - Discovery

    private struct Candidate {
        let path: String
        let size: Int64
        let mtime: Double
        let compressed: Bool
    }

    private func sessionFiles() -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        guard let enumerator = fm.enumerator(
            at: ScanPaths.dshSessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isZstd = name.hasSuffix(".jsonl.zstd")
            guard isZstd || name.hasSuffix(".jsonl") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate?.timeIntervalSince1970
            else { continue }
            out.append(Candidate(path: url.path, size: Int64(values.fileSize ?? 0), mtime: mtime, compressed: isZstd))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    // MARK: - Per-file scan

    private func scan(file: Candidate, retentionDays: Int) -> FileState {
        if let cached = states[file.path],
           cached.size == file.size,
           abs(cached.mtime - file.mtime) < 0.001 {
            return cached
        }

        var state = FileState(size: file.size, mtime: file.mtime)
        guard let data = readData(file) else { return state }

        var currentProvider = "unknown"
        var daily: [String: [String: TokenUsage]] = [:]
        var peak: [String: [String: TokenUsage]] = [:]
        let cutoffKey = DayKey.key(for: Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(retentionDays) * 86_400)))

        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let line = data[lineStart..<newline]
            if !line.isEmpty {
                if line.containsBytes(of: Self.headerMarker) {
                    if let provider = Self.extractProvider(from: line) {
                        currentProvider = provider
                    }
                } else if line.containsBytes(of: Self.assistantMarker) {
                    if let (timestamp, usage) = Self.extractUsage(from: line) {
                        let key = DayKey.key(for: timestamp)
                        if key >= cutoffKey {
                            daily[key, default: [:]][currentProvider, default: TokenUsage()] += usage
                            if ModelPricing.isPeak(timestamp) {
                                peak[key, default: [:]][currentProvider, default: TokenUsage()] += usage
                            }
                        }
                    }
                }
            }
            lineStart = data.index(after: newline)
        }

        state.daily = daily
        state.peak = peak
        dirty = true
        return state
    }

    private func readData(_ file: Candidate) -> Data? {
        guard file.compressed else {
            return try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe)
        }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = file.path.withCString { tb_zstd_decompress_file($0, &pointer, &length) }
        guard status == 0, let pointer else { return nil }
        defer { tb_zstd_free(pointer) }
        return Data(bytes: pointer, count: length)
    }

    // MARK: - Targeted extraction
    //
    // Transcript lines embed the full streamed response, so they can be megabytes
    // wide. Instead of decoding the whole line we locate the two small objects we
    // actually need.

    /// Pulls the `provider` id out of a `request/header` record. The model name
    /// sits next to it but is not needed for accounting.
    static func extractProvider(from line: Data) -> String? {
        stringValue(forKey: "\"provider\":", in: line)
    }

    static func extractUsage(from line: Data) -> (timestamp: Date, usage: TokenUsage)? {
        guard let object = objectBytes(forKey: usageMarker, in: line),
              let parsed = try? JSONSerialization.jsonObject(with: object) as? [String: Any]
        else { return nil }

        let input = JSON.int(parsed["inputTokens"]) ?? 0
        let cached = JSON.int(parsed["cacheReadTokens"]) ?? 0
        let output = JSON.int(parsed["outputTokens"]) ?? 0
        let reasoning = JSON.int(parsed["reasoningTokens"]) ?? 0

        var usage = TokenUsage()
        usage.input = max(0, input)
        usage.cachedInput = max(0, cached)
        usage.output = max(0, output)
        usage.reasoning = max(0, reasoning)
        usage.requests = 1

        let millis = intValue(forKey: "\"time\":", in: line) ?? 0
        let date = millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : Date()
        return (date, usage)
    }

    /// Returns the raw bytes of the `{...}` object following `key`.
    private static func objectBytes(forKey key: [UInt8], in data: Data) -> Data? {
        guard let range = data.firstRange(of: key) else { return nil }
        var index = range.upperBound
        // Skip whitespace, expect '{'.
        while index < data.endIndex, data[index] == 0x20 || data[index] == 0x09 { index = data.index(after: index) }
        guard index < data.endIndex, data[index] == 0x7B else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var cursor = index
        while cursor < data.endIndex {
            let byte = data[cursor]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
            } else {
                if byte == 0x22 { inString = true }
                else if byte == 0x7B { depth += 1 }
                else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 { return data[index...cursor] }
                }
            }
            cursor = data.index(after: cursor)
        }
        return nil
    }

    private static func stringValue(forKey key: String, in data: Data) -> String? {
        guard let range = data.firstRange(of: Array(key.utf8)) else { return nil }
        var index = range.upperBound
        while index < data.endIndex, data[index] == 0x20 { index = data.index(after: index) }
        guard index < data.endIndex, data[index] == 0x22 else { return nil }
        index = data.index(after: index)
        var bytes: [UInt8] = []
        while index < data.endIndex, data[index] != 0x22 {
            bytes.append(data[index])
            index = data.index(after: index)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func intValue(forKey key: String, in data: Data) -> Int? {
        guard let range = data.firstRange(of: Array(key.utf8)) else { return nil }
        var index = range.upperBound
        var digits: [UInt8] = []
        while index < data.endIndex, data[index] >= 0x30, data[index] <= 0x39 {
            digits.append(data[index])
            index = data.index(after: index)
        }
        return digits.isEmpty ? nil : Int(String(bytes: digits, encoding: .utf8) ?? "")
    }

    // MARK: - Cache

    private var dirty = false

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileState].self, from: data)
        else { return }
        states = decoded
    }

    private func saveIfNeeded() {
        guard dirty else { return }
        dirty = false
        let snapshot = states
        DispatchQueue.global(qos: .utility).async { [cacheURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

extension Data {
    /// First occurrence of a byte pattern.
    func firstRange(of pattern: [UInt8]) -> Range<Index>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let limit = count - pattern.count
        let first = pattern[0]
        var i = startIndex
        var offset = 0
        while offset <= limit {
            if self[i] == first {
                var j = 1
                var cursor = index(after: i)
                while j < pattern.count, cursor < endIndex, self[cursor] == pattern[j] {
                    j += 1
                    cursor = index(after: cursor)
                }
                if j == pattern.count {
                    return i..<cursor
                }
            }
            i = index(after: i)
            offset += 1
        }
        return nil
    }
}
