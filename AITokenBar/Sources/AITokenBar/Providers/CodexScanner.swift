import Foundation

/// Parses Codex rollout logs (`~/.codex/sessions/**/*.jsonl`).
///
/// Those logs hold everything the ChatGPT/Codex UI shows as "剩余 N%":
/// every `token_count` event carries both the running token totals and the
/// `rate_limits` block (used %, window length, reset timestamp).
///
/// The directory can be multiple gigabytes, so the scanner is deliberately cheap:
///   * only files modified inside the retention window are considered,
///   * an unseen file is parsed from an adaptive tail region, not from byte 0,
///   * a file already parsed resumes from its last complete line,
///   * each refresh runs under a time budget and simply continues next round.
final class CodexScanner {

    // MARK: - Persisted per-file state

    struct WindowSample: Codable, Hashable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Double?
    }

    struct CreditSample: Codable, Hashable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: Double?
    }

    /// One `rate_limits` block, stamped with when the log wrote it.
    struct RateLimitSample: Codable, Hashable {
        var at: Double
        var primary: WindowSample?
        var secondary: WindowSample?
        var credits: CreditSample?
        var planType: String?
    }

    struct FileState: Codable {
        var size: Int64 = 0
        var mtime: Double = 0
        var parsedUpTo: Int64 = 0
        var daily: [String: TokenUsage] = [:]
        var lastEventAt: Double?
        var rateLimit: RateLimitSample?
    }

    struct Result {
        var daily: [String: TokenUsage] = [:]
        var latestRateLimit: RateLimitSample?
        var lastEventAt: Date?
        var filesConsidered = 0
        var filesParsed = 0
        var bytesRead = 0
        var coverageStart: Date?
        /// False when the time budget ran out before every candidate was parsed.
        var complete = true
        /// True when ~/.codex/sessions exists but holds no usable rollout logs.
        var noData = false
    }

    // MARK: - Tunables

    /// Bytes read from the end of a file the scanner has never seen. Bounded so a
    /// cold start on a huge rollout still finishes in well under a second.
    private let initialTailBytes: Int64 = 8 * 1024 * 1024
    /// Ceiling on how much *appended* data one file may contribute per refresh.
    private let maxForwardBytes: Int64 = 64 * 1024 * 1024
    private let chunkBytes: Int64 = 8 * 1024 * 1024
    private let tokenMarker: [UInt8] = Array("\"token_count\"".utf8)

    // MARK: - State

    private var states: [String: FileState] = [:]
    private let lock = NSLock()
    private let cacheURL = ScanPaths.appSupport.appendingPathComponent("codex-scan-cache.json")

    init() {
        load()
    }

    // MARK: - Public API

    /// Scans within `budget` seconds. Safe to call repeatedly; progress is retained.
    func refresh(retentionDays: Int, budget: TimeInterval = 2.5) -> Result {
        lock.lock()
        defer { lock.unlock() }

        let deadline = Date().addingTimeInterval(budget)
        let calendar = Calendar.current
        let cutoffDay = calendar.startOfDay(for: Date().addingTimeInterval(-Double(retentionDays) * 86_400))
        let cutoffKey = DayKey.key(for: cutoffDay, calendar: calendar)
        let cutoffEpoch = Date().timeIntervalSince1970 - Double(retentionDays) * 86_400

        var result = Result()
        let fm = FileManager.default

        guard fm.fileExists(atPath: ScanPaths.codexSessions.path) else {
            result.noData = true
            result.complete = true
            return result
        }

        let candidates = candidateFiles(olderThan: cutoffEpoch)
        result.filesConsidered = candidates.count

        var livePaths = Set<String>()
        for candidate in candidates {
            livePaths.insert(candidate.path)
            if Date() > deadline && result.filesParsed > 0 {
                result.complete = false
                break
            }
            if let bytes = refreshFile(candidate, cutoffEpoch: cutoffEpoch, state: &states[candidate.path, default: FileState()]) {
                if bytes > 0 {
                    result.filesParsed += 1
                    result.bytesRead += bytes
                }
            }
        }

        // Forget files that fell out of the retention window so the cache stays small.
        for path in states.keys where !livePaths.contains(path) {
            states.removeValue(forKey: path)
        }

        // Merge every file's aggregates.
        var merged: [String: TokenUsage] = [:]
        var latest: RateLimitSample?
        var lastEvent: Double?
        var earliest: Double?
        for state in states.values {
            // "yyyy-MM-dd" sorts chronologically, so a string compare is the cheapest filter.
            for (day, usage) in state.daily where day >= cutoffKey {
                merged[day, default: TokenUsage()] += usage
            }
            if let rl = state.rateLimit, rl.at > (latest?.at ?? -.infinity) { latest = rl }
            if let t = state.lastEventAt {
                if t > (lastEvent ?? -.infinity) { lastEvent = t }
                if t < (earliest ?? .infinity) { earliest = t }
            }
        }

        result.daily = merged
        result.latestRateLimit = latest
        result.lastEventAt = lastEvent.map { Date(timeIntervalSince1970: $0) }
        result.coverageStart = earliest.map { Date(timeIntervalSince1970: $0) }
        if candidates.isEmpty { result.noData = true }

        saveIfNeeded()
        return result
    }

    /// Per-day token totals for the last `days` days (index 0 = today).
    static func series(from daily: [String: TokenUsage], days: Int) -> [(day: Date, usage: TokenUsage)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = DayKey.key(for: day, calendar: calendar)
            return (day, daily[key] ?? TokenUsage())
        }
    }

    // MARK: - File discovery

    private struct Candidate {
        let path: String
        let size: Int64
        let mtime: Double
    }

    private func candidateFiles(olderThan cutoffEpoch: Double) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        guard let enumerator = fm.enumerator(
            at: ScanPaths.codexSessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate?.timeIntervalSince1970,
                  mtime >= cutoffEpoch
            else { continue }
            out.append(Candidate(path: url.path, size: Int64(values.fileSize ?? 0), mtime: mtime))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    // MARK: - Per-file parsing

    /// Returns the number of bytes actually read (0 when the file was already up to date).
    ///
    /// Two paths, both of which read a *bounded* amount of data so no single file
    /// can stall a refresh:
    ///  * resume — the file only grew, so read forward from where we stopped;
    ///  * cold   — read one tail region from the end of the file.
    ///
    /// Cold reads deliberately do not walk backwards: an earlier revision re-parsed
    /// an ever-growing region until it reached the retention window, which is
    /// quadratic on the multi-hundred-megabyte rollouts this machine produces.
    /// Coverage instead accumulates across refreshes, and forward reads are lossless
    /// because the resume offset only ever moves through complete lines.
    private func refreshFile(_ candidate: Candidate, cutoffEpoch: Double, state: inout FileState) -> Int? {
        let unchanged = state.size == candidate.size && abs(state.mtime - candidate.mtime) < 0.001 && state.parsedUpTo > 0
        if unchanged { return 0 }

        let resuming = state.parsedUpTo > 0
            && state.parsedUpTo <= candidate.size
            && candidate.size > state.size          // file only grew

        var accumulator = Accumulator()
        var bytesRead = 0

        if resuming {
            // Fast path: only the appended region, capped per pass so a large
            // backlog is spread over several refreshes.
            let from = state.parsedUpTo
            let to = min(candidate.size, from + maxForwardBytes)
            bytesRead += parse(path: candidate.path, from: from, to: to, into: &accumulator, state: &state, cutoffEpoch: cutoffEpoch)
            state.daily = accumulator.daily
            state.rateLimit = accumulator.rateLimit ?? state.rateLimit
            state.lastEventAt = accumulator.lastEvent ?? state.lastEventAt
            state.size = candidate.size
            state.mtime = candidate.mtime
        } else {
            // Cold start (or the file shrank / was rewritten): single tail read.
            var scratch = FileState()
            let regionStart = max(0, candidate.size - initialTailBytes)
            bytesRead += parse(path: candidate.path, from: regionStart, to: candidate.size, into: &accumulator, state: &scratch, cutoffEpoch: cutoffEpoch)
            scratch.size = candidate.size
            scratch.mtime = candidate.mtime
            scratch.daily = accumulator.daily
            scratch.rateLimit = accumulator.rateLimit
            scratch.lastEventAt = accumulator.lastEvent
            state = scratch
        }

        if bytesRead > 0 { dirty = true }
        return bytesRead
    }

    /// Streams `[from, to)` and folds `token_count` events into `accumulator`.
    /// `state.parsedUpTo` ends up at the last complete line boundary.
    @discardableResult
    private func parse(
        path: String,
        from: Int64,
        to: Int64,
        into accumulator: inout Accumulator,
        state: inout FileState,
        cutoffEpoch: Double
    ) -> Int {
        guard to > from, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            state.parsedUpTo = to
            return 0
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(from))
        } catch {
            state.parsedUpTo = to
            return 0
        }

        var bytesRead = 0
        var carry = Data()
        var carryStart = from
        var consumed: Int64 = from

        while consumed < to {
            let want = Int(min(chunkBytes, to - consumed))
            let chunk = (try? handle.read(upToCount: want)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            bytesRead += chunk.count
            consumed += Int64(chunk.count)

            var buffer = carry
            buffer.append(chunk)
            let base = carryStart

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let line = buffer[lineStart..<newline]
                if !line.isEmpty {
                    let absoluteStart = base + Int64(buffer.distance(from: buffer.startIndex, to: lineStart))
                    consume(line: Data(line), absoluteEnd: absoluteStart + Int64(line.count) + 1, accumulator: &accumulator, state: &state, cutoffEpoch: cutoffEpoch)
                }
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                carryStart = base + Int64(buffer.distance(from: buffer.startIndex, to: lineStart))
                carry = Data(buffer[lineStart...])
            }
        }

        // `carry` is an unterminated trailing line; leave it for the next refresh.
        state.parsedUpTo = max(carryStart, from)
        return bytesRead
    }

    private func consume(line: Data, absoluteEnd: Int64, accumulator: inout Accumulator, state: inout FileState, cutoffEpoch: Double) {
        guard line.containsBytes(of: tokenMarker) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let payload = JSON.dict(object["payload"]), JSON.string(payload["type"]) == "token_count" else { return }

        let timestamp = JSON.date(fromISO: JSON.string(object["timestamp"]))
        _ = absoluteEnd

        if let timestamp {
            accumulator.observe(timestamp: timestamp)
        }

        if let info = JSON.dict(payload["info"]), let last = JSON.dict(info["last_token_usage"]) {
            let rawInput = JSON.int(last["input_tokens"]) ?? 0
            let cached = min(JSON.int(last["cached_input_tokens"]) ?? 0, rawInput)
            var usage = TokenUsage()
            usage.input = max(0, rawInput - cached)
            usage.cachedInput = cached
            usage.output = JSON.int(last["output_tokens"]) ?? 0
            usage.reasoning = JSON.int(last["reasoning_output_tokens"]) ?? 0
            usage.requests = 1
            if let timestamp {
                let key = DayKey.key(for: timestamp)
                accumulator.daily[key, default: TokenUsage()] += usage
                _ = cutoffEpoch
            }
        }

        if let rl = JSON.dict(payload["rate_limits"]), let sample = Self.sample(from: rl, at: timestamp ?? Date()) {
            if sample.at >= (accumulator.rateLimit?.at ?? -.infinity) {
                accumulator.rateLimit = sample
            }
        }
    }

    static func sample(from rl: [String: Any], at date: Date) -> RateLimitSample? {
        func window(_ any: Any?) -> WindowSample? {
            guard let d = JSON.dict(any) else { return nil }
            guard let used = JSON.double(d["used_percent"]) else { return nil }
            return WindowSample(
                usedPercent: used,
                windowMinutes: JSON.int(d["window_minutes"]),
                resetsAt: JSON.double(d["resets_at"])
            )
        }
        let primary = window(rl["primary"])
        let secondary = window(rl["secondary"])
        guard primary != nil || secondary != nil else { return nil }

        var credits: CreditSample?
        if let c = JSON.dict(rl["credits"]) {
            credits = CreditSample(
                hasCredits: JSON.bool(c["has_credits"]) ?? false,
                unlimited: JSON.bool(c["unlimited"]) ?? false,
                balance: JSON.double(c["balance"])
            )
        }
        return RateLimitSample(
            at: date.timeIntervalSince1970,
            primary: primary,
            secondary: secondary,
            credits: credits,
            planType: JSON.string(rl["plan_type"])
        )
    }

    // MARK: - Accumulator

    struct Accumulator {
        var daily: [String: TokenUsage] = [:]
        var rateLimit: RateLimitSample?
        var lastEvent: Double?
        var earliestEvent: Double?

        mutating func observe(timestamp: Date) {
            let t = timestamp.timeIntervalSince1970
            if t > (lastEvent ?? -.infinity) { lastEvent = t }
            if t < (earliestEvent ?? .infinity) { earliestEvent = t }
        }
    }

    // MARK: - Cache persistence

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

    func markDirty() { dirty = true }
}

// MARK: - Codex global state (reset history, plan info)

/// Reads the small, structured pieces of `~/.codex/.codex-global-state.json`.
/// The file is ~1.5 MB of JSON, so it is only re-read when its mtime changes.
final class CodexGlobalStateReader {
    struct Info {
        var resetCount = 0
        var lastResetAt: Date?
        var accountID: String?
    }

    private var cachedMtime: Double = -1
    private var cached = Info()
    private let lock = NSLock()

    func read() -> Info {
        lock.lock()
        defer { lock.unlock() }

        let url = ScanPaths.codexGlobalState
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return cached }

        if abs(mtime - cachedMtime) < 0.001 { return cached }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return cached }

        var info = Info()
        if let persisted = JSON.dict(root["electron-persisted-atom-state"]),
           let history = JSON.array(persisted["codex-rate-limit-reset-history"]) {
            info.resetCount = history.count
            let dates = history.compactMap { JSON.dict($0) }.compactMap { JSON.double($0["occurredAtMs"]) }
            info.lastResetAt = dates.max().map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        cached = info
        cachedMtime = mtime
        return info
    }
}
