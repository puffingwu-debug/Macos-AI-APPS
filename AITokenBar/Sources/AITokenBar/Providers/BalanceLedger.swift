import Foundation

/// Turns a stream of balance readings into spend figures.
///
/// DeepSeek's API exposes the current balance but no spend history, so the widget
/// records every balance it observes and sums the *decreases*. That way a top-up
/// (balance going up) never shows up as negative spend.
///
/// Coverage starts the first time the app runs — the ledger is explicit about that
/// rather than pretending to know lifetime totals.
final class BalanceLedger {

    struct Sample: Codable {
        var t: Double
        var b: Double
    }

    private struct Storage: Codable {
        var samples: [Sample] = []
        var currency: String = "CNY"
    }

    private var storage = Storage()
    private let lock = NSLock()
    private let url = ScanPaths.appSupport.appendingPathComponent("deepseek-ledger.json")

    /// Most recent readings are kept verbatim; older ones are thinned out.
    private let maxSamples = 4000

    init() { load() }

    // MARK: - Writing

    /// Records a balance reading. Returns true when the sample was stored.
    @discardableResult
    func record(balance: Double, currency: String, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        storage.currency = currency
        if let last = storage.samples.last, abs(last.b - balance) < 0.0000001 {
            // Balance unchanged: only refresh the timestamp of the newest sample.
            storage.samples[storage.samples.count - 1].t = date.timeIntervalSince1970
            persist()
            return false
        }
        storage.samples.append(Sample(t: date.timeIntervalSince1970, b: balance))
        thin()
        persist()
        return true
    }

    // MARK: - Reading

    /// Total spend inferred from balance decreases since tracking began.
    var trackedSpend: Double {
        lock.lock()
        defer { lock.unlock() }
        return spendLocked(since: nil)
    }

    var trackedSince: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storage.samples.first.map { Date(timeIntervalSince1970: $0.t) }
    }

    func spendToday(now: Date = Date()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        return spendLocked(since: start)
    }

    /// Sum of decreases between consecutive samples, optionally limited to a start time.
    private func spendLocked(since start: Double?) -> Double {
        guard storage.samples.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<storage.samples.count {
            let previous = storage.samples[index - 1]
            let current = storage.samples[index]
            guard current.b < previous.b else { continue }  // increase = top-up, not spend
            if let start {
                // Attribute a drop to the interval it happened in; only count drops
                // that fall inside the requested window.
                guard current.t >= start else { continue }
            }
            total += previous.b - current.b
        }
        return total
    }

    // MARK: - Maintenance

    /// Keeps the ledger bounded by dropping every other old sample.
    private func thin() {
        guard storage.samples.count > maxSamples else { return }
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var keptToday: [Sample] = []
        var older: [Sample] = []
        for sample in storage.samples {
            if sample.t >= todayStart { keptToday.append(sample) } else { older.append(sample) }
        }
        let thinned = older.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
        storage.samples = thinned + keptToday
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else { return }
        storage = decoded
    }

    private func persist() {
        let snapshot = storage
        let target = url
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
