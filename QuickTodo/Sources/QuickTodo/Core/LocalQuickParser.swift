import Foundation

/// Mac 端本地兜底解析器。
///
/// 云端 `ai` 云函数才是主力（DeepSeek + 规则引擎）。但有两种情况会用到本地兜底：
/// 1. 还没配置云环境（纯本地模式）也想用截图收任务；
/// 2. 云端不可用时的降级路径。
///
/// 行为刻意与云端规则引擎保持一致（契约 §3.4）：
/// 拆多条、抽出截止时间、判定优先级，并**把时间词从待办内容里去掉**，
/// 这样用户在本地模式和云端模式下看到的待办长得一样。
enum LocalQuickParser {

    // MARK: - 词表

    /// 相对「天」的词 → 天数偏移
    private static let dayOffsets: [(String, Int)] = [
        ("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1), ("明晚", 1),
        ("今晚", 0), ("今天", 0), ("今日", 0), ("当天", 0)
    ]

    /// 时段词 → 该时段的默认小时 + 是否属于下午/晚上
    private static let dayParts: [(String, Int, Bool)] = [
        ("凌晨", 5, false), ("早上", 8, false), ("早晨", 8, false), ("上午", 10, false),
        ("中午", 12, false), ("下午", 15, true), ("傍晚", 18, true), ("晚上", 20, true), ("今晚", 20, true)
    ]

    private static let highWords = ["紧急", "尽快", "立刻", "马上", "立即", "asap", "重要", "优先", "务必", "必须", "deadline"]
    private static let lowWords = ["不急", "有空", "随意", "顺便", "可选"]

    /// 前缀噪声，导入前去掉让待办更干净。
    private static let noisePrefixes = [
        "记得", "帮我", "请帮我", "请", "需要", "要", "别忘记", "不要忘记", "提醒我",
        "待办：", "待办:", "todo:", "todo：", "任务：", "任务:"
    ]

    /// 需要从内容里抹掉的时间表达（保留结构见 analyze）。
    private static let stripPatterns: [String] = [
        #"(大后天|后天|明天|明日|今晚|明晚|今天|今日|当天)"#,
        #"下{0,1}(?:周|星期|礼拜)[一二三四五六日天1-7]"#,
        #"\d{1,2}\s*[月/]\s*\d{1,2}\s*[日号]?\s*(?:之前|以前|前)?"#,
        #"(?:凌晨|早上|早晨|上午|中午|下午|傍晚|晚上)\s*(?:\d{1,2}|[一二两三四五六七八九十]{1,3})?\s*点?\s*(?:之前|以前|前)?"#,
        #"\d{1,2}\s*[:：]\s*\d{1,2}\s*(?:之前|以前|前)?"#,
        #"(\d{1,2}|[一二两三四五六七八九十]{1,3})\s*点\s*(半|\d{1,2}|[一二三四五六七八九十]{1,3}分?)?\s*(?:之前|以前|前)?"#,
        #"(截止到|截止时间|截止|deadline)"#
    ]

    // MARK: - 入口

    static func parse(_ text: String, source: TodoSource, maxItems: Int = 8) -> [ParsedTodo] {
        let now = Date()
        var results: [ParsedTodo] = []

        for rawLine in splitSegments(text) {
            guard results.count < maxItems else { break }
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            line = stripNoise(line)
            guard line.count >= 2 else { continue }
            guard containsReadableCharacter(line) else { continue }

            let analysis = analyze(line, now: now)
            let priority = detectPriority(line)

            // 时间词从内容里去掉，剩下的才是「要做什么」
            var content = stripTimeExpressions(line, analysis.ranges)
            content = tidy(content)
            if content.count < 2 { content = tidy(line) }

            results.append(ParsedTodo(content: content, deadline: analysis.deadline, priority: priority))
        }

        // 一条都没解析出来时，至少保留原文，避免用户白截一张图
        if results.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                results.append(ParsedTodo(content: String(fallback.prefix(120)), deadline: nil, priority: .normal))
            }
        }
        return results
    }

    /// 只取时间（导入预览里用户改内容时用）。
    static func detectDeadline(in line: String, now: Date = Date()) -> Int64? {
        analyze(line, now: now).deadline
    }

    // MARK: - 分句

    /// 一条 OCR/语音文本里通常挤着好几件事，按换行、标点、连接词切开。
    private static func splitSegments(_ text: String) -> [String] {
        var segments: [String] = []
        let connectors = ["然后", "还要", "另外", "以及", "顺便", "再有", "还有就是", "同时", "接下来"]
        var normalized = text
        for connector in connectors {
            normalized = normalized.replacingOccurrences(of: connector, with: "\n")
        }
        for chunk in normalized.components(separatedBy: CharacterSet.newlines) {
            for piece in chunk.components(separatedBy: CharacterSet(charactersIn: "；;。！!？?")) {
                for last in piece.components(separatedBy: CharacterSet(charactersIn: "，,、")) {
                    let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { segments.append(trimmed) }
                }
            }
        }
        return segments
    }

    /// 去掉列表符号和口头前缀。
    private static func stripNoise(_ line: String) -> String {
        var result = line
        let bullets = CharacterSet(charactersIn: "-*•·–— \t")
        while let first = result.unicodeScalars.first, bullets.contains(first) {
            result.removeFirst()
        }
        // 列表序号：必须带明确分隔符（"1." "2、" "①"），否则会把「3月5日」的 3 一起吃掉
        if let range = result.range(of: #"^(?:[①②③④⑤⑥⑦⑧⑨⑩]|\d{1,2}\s*[\.、\)）:：]|\d{1,2}\s+)\s*"#,
                                   options: .regularExpression) {
            result.removeSubrange(range)
        }
        for prefix in noisePrefixes where result.lowercased().hasPrefix(prefix.lowercased()) {
            result.removeFirst(prefix.count)
            break
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收尾：合并多余空格、去掉首尾标点。
    private static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, " ，,。.、；;：:　".contains(first) {
            result.removeFirst()
        }
        while let last = result.last, " ，,。.、；;：:　".contains(last) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsReadableCharacter(_ line: String) -> Bool {
        let han = CharacterSet(charactersIn: Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!)
        return line.rangeOfCharacter(from: CharacterSet.letters.union(han).union(.decimalDigits)) != nil
    }

    // MARK: - 优先级

    private static func detectPriority(_ line: String) -> TodoPriority {
        let lowered = line.lowercased()
        if highWords.contains(where: { lowered.contains($0) }) { return .high }
        if lowWords.contains(where: { lowered.contains($0) }) { return .low }
        return .normal
    }

    // MARK: - 时间分析

    private struct Analysis {
        var deadline: Int64?
        var ranges: [Range<String.Index>] = []
    }

    /// 同时算出「截止时间」和「哪些文字属于时间表达（可以从内容里删掉）」。
    private static func analyze(_ line: String, now: Date) -> Analysis {
        let calendar = Calendar.current
        var analysis = Analysis()

        var dayOffset: Int?
        var hasExplicitDay = false
        var dayPartHour: Int?
        var dayPartIsAfternoon = false
        var clockHour: Int?
        var clockMinute = 0

        // 1) 相对日
        for (word, offset) in dayOffsets where line.contains(word) {
            dayOffset = offset
            hasExplicitDay = true
            break
        }

        // 2) 周几（「周三」说在周三 = 下周三）
        if dayOffset == nil,
           let match = firstMatch(in: line, pattern: #"(下{0,1})(?:周|星期|礼拜)([一二三四五六日天1-7])"#) {
            let isNextWeek = match.groups[0] == "下"
            let map: [String: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1,
                                      "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 1]
            if let target = map[match.groups[1]] {
                let current = calendar.component(.weekday, from: now)   // 1 = 周日
                var delta = (target - current + 7) % 7
                if delta == 0 { delta = 7 }
                if isNextWeek { delta += 7 }
                dayOffset = delta
                hasExplicitDay = true
            }
        }

        // 3) 月日（已过去的按明年，契约 §3.4）
        if dayOffset == nil,
           let match = firstMatch(in: line, pattern: #"(\d{1,2})\s*[月/]\s*(\d{1,2})\s*[日号]?"#),
           let month = Int(match.groups[0]), let day = Int(match.groups[1]),
           (1...12).contains(month), (1...31).contains(day) {
            var components = calendar.dateComponents([.year], from: now)
            components.month = month
            components.day = day
            if let date = calendar.date(from: components) {
                let isPast = calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
                let resolved = isPast ? (calendar.date(byAdding: .year, value: 1, to: date) ?? date) : date
                let offset = calendar.dateComponents([.day],
                                                     from: calendar.startOfDay(for: now),
                                                     to: calendar.startOfDay(for: resolved)).day ?? 0
                dayOffset = max(0, offset)
                hasExplicitDay = true
            }
        }

        // 4) 时段词
        for (word, hour, isAfternoon) in dayParts where line.contains(word) {
            dayPartHour = hour
            dayPartIsAfternoon = isAfternoon
            break
        }

        // 5) 钟点：15:30 → 「3点半」→「三点半」→「3点」
        if let match = firstMatch(in: line, pattern: #"(\d{1,2})\s*[:：]\s*(\d{1,2})"#),
           let hour = Int(match.groups[0]), let minute = Int(match.groups[1]),
           (0...23).contains(hour), (0...59).contains(minute) {
            clockHour = hour
            clockMinute = minute
        } else if let match = firstMatch(in: line, pattern: #"(\d{1,2}|[一二两三四五六七八九十]{1,3})\s*点\s*(半|\d{1,2}|[一二三四五六七八九十]{1,3}分?)?"#),
                  let rawHour = numberOf(match.groups[0]), (0...24).contains(rawHour) {
            var resolved = rawHour % 24
            // 「下午3点」→ 15 点；「上午12点」→ 0 点
            if dayPartIsAfternoon, resolved < 12 { resolved += 12 }
            if !dayPartIsAfternoon, resolved == 12, dayPartHour != nil { resolved = 0 }
            clockHour = resolved
            let minuteText = match.groups[1]
            if minuteText == "半" {
                clockMinute = 30
            } else if let minute = numberOf(minuteText.replacingOccurrences(of: "分", with: "")), (0...59).contains(minute) {
                clockMinute = minute
            }
        }

        // 6) 收集要抹掉的时间片段
        for pattern in stripPatterns {
            analysis.ranges.append(contentsOf: allMatchRanges(in: line, pattern: pattern))
        }

        guard hasExplicitDay || dayPartHour != nil || clockHour != nil else {
            analysis.ranges = []
            return analysis
        }

        // 只说「哪天」不说几点 → 当天 23:59:59.999（契约 §3.4，与云端规则引擎一致）
        let onlyDay = clockHour == nil && dayPartHour == nil
        let hour: Int
        if let clockHour {
            hour = clockHour
        } else if let dayPartHour {
            hour = dayPartHour
        } else {
            hour = 23
        }

        let base = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = hour
        components.minute = onlyDay ? 59 : (clockHour != nil ? clockMinute : 0)
        components.second = onlyDay ? 59 : 0
        components.nanosecond = onlyDay ? 999_000_000 : 0
        guard var date = calendar.date(from: components) else { return analysis }

        // 只说「下午3点」但今天已经过了 → 顺延到明天
        if !hasExplicitDay, date < now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        analysis.deadline = date.millis
        return analysis
    }

    /// 删掉命中的时间片段并收拾干净。
    ///
    /// 多个模式会命中互相重叠的片段（例如「明天」+「下午三点前」、「下午三点前」+「三点前」），
    /// 所以先把区间按起点排序并**合并**，再从后往前删，保证不会把「下午」这种半个片段留下来。
    private static func stripTimeExpressions(_ line: String, _ ranges: [Range<String.Index>]) -> String {
        guard !ranges.isEmpty else { return line }

        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        var result = line
        for range in merged.reversed() {
            result.removeSubrange(range)
        }
        return result
    }

    // MARK: - 数字与正则

    /// 支持「三」「十二」「二十」这类中文数字（时间场景足够用）。
    private static func numberOf(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let value = Int(trimmed) { return value }

        let digits: [Character: Int] = ["零": 0, "一": 1, "两": 2, "二": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if trimmed == "十" { return 10 }
        if trimmed.hasPrefix("十") {
            let rest = trimmed.dropFirst()
            return 10 + (digits[rest.first ?? "零"] ?? 0)
        }
        if let index = trimmed.firstIndex(of: "十") {
            let tens = digits[trimmed.first ?? "一"] ?? 1
            let ones = digits[trimmed[trimmed.index(after: index)]]
            return tens * 10 + (ones ?? 0)
        }
        guard let first = trimmed.first, let value = digits[first] else { return nil }
        return value
    }

    private struct Match {
        var groups: [String]
        var range: Range<String.Index>
    }

    private static func firstMatch(in text: String, pattern: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range, in: text) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            if let sub = Range(match.range(at: index), in: text) {
                groups.append(String(text[sub]))
            } else {
                groups.append("")
            }
        }
        return Match(groups: groups, range: range)
    }

    private static func allMatchRanges(in text: String, pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
    }
}
