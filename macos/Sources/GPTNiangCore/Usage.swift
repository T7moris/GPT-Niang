import Foundation

public struct QuotaWindow: Codable, Equatable, Identifiable {
    public let kind: String?
    public let minutes: Int?
    public let total: Double?
    public let amountUsed: Double?
    public let amountRemaining: Double?
    public let remaining: Double
    public let resetsAt: Double?
    public var id: String { isIndividual ? "individual" : "time:\(minutes ?? 0)" }
    public var isIndividual: Bool { kind == "individual" }
    public var valid: Bool { remaining.isFinite && (0...100).contains(remaining) && (isIndividual || (minutes ?? 0) > 0) }
    public var percentageText: String {
        let value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), remaining)
        return value.hasSuffix(".0") ? String(value.dropLast(2)) : value
    }
    public var title: String {
        if isIndividual { return "个人额度" }
        guard let minutes else { return "未提供额度窗口" }
        if minutes == 300 { return "5 小時" }
        if minutes == 10080 { return "每週" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小時" }
        return "\(minutes) 分鐘"
    }

    public init(minutes: Int? = nil, remaining: Double, resetsAt: Double? = nil, kind: String? = nil, total: Double? = nil, amountUsed: Double? = nil, amountRemaining: Double? = nil) {
        self.minutes = minutes; self.remaining = remaining; self.resetsAt = resetsAt; self.kind = kind
        self.total = total; self.amountUsed = amountUsed; self.amountRemaining = amountRemaining
    }
    public func title(language: InterfaceLanguage) -> String {
        if isIndividual { return language.text("个人额度") }
        guard let minutes else { return language.text("未提供额度窗口") }
        if minutes == 300 { return language.text("5 小時") }
        if minutes == 10080 { return language.text("每週") }
        if minutes % 1440 == 0 { return language.text("%@ 天", String(minutes / 1440)) }
        if minutes % 60 == 0 { return language.text("%@ 小時", String(minutes / 60)) }
        return language.text("%@ 分鐘", String(minutes))
    }
    public func expired(at date: Date) -> Bool {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return false }
        return resetsAt <= date.timeIntervalSince1970
    }
    public func resetText(at date: Date, timeZone: TimeZone = .current, countdown: Bool? = nil, language: InterfaceLanguage = .traditional) -> String {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0, resetsAt <= 253402271999 else { return language.text("未提供重置時間") }
        let interval = resetsAt - date.timeIntervalSince1970
        if interval <= 0 { return language.text("等待更新後的額度") }
        if countdown == true && interval >= 86400 {
            let hours = Int(ceil(interval / 3600))
            return language.text("%@ 天 %@ 小時後重置", String(describing: hours / 24), String(describing: hours % 24))
        }
        if countdown != false && interval < 86400 {
            let minutes = max(1, Int(ceil(interval / 60)))
            return minutes >= 60 ? language.text("%@ 小時 %@ 分鐘後重置", String(describing: minutes / 60), String(describing: minutes % 60)) : language.text("%@ 分鐘後重置", String(describing: minutes))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_HK")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return language.text("%@ 重置", String(describing: formatter.string(from: Date(timeIntervalSince1970: resetsAt))))
    }
}

public struct UsageSnapshot: Decodable {
    public let ok: Bool
    public let queryOk: Bool?
    public let observedAt: Double?
    public let windows: [QuotaWindow]
    public let error: String?
    public let plan: String?
    public let planLabel: String?
    public let accountKey: String?

    public init(ok: Bool = false, queryOk: Bool? = false, observedAt: Double? = nil, windows: [QuotaWindow] = [], error: String? = nil, plan: String? = nil, planLabel: String? = nil, accountKey: String? = nil) {
        self.ok = ok; self.queryOk = queryOk; self.observedAt = observedAt; self.windows = windows; self.error = error
        self.plan = plan; self.planLabel = planLabel; self.accountKey = accountKey
    }
    public var validWindows: [QuotaWindow] {
        var seen = Set<String>()
        return windows.filter { $0.valid && seen.insert($0.id).inserted }
    }
    public var displayWindows: [QuotaWindow] {
        let personal = validWindows.filter(\.isIndividual)
        let timed = validWindows.filter { !$0.isIndividual }.sorted { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        if !personal.isEmpty { return Array((personal + timed).prefix(2)) }
        var short = timed.first { $0.minutes == 300 }
        var week = timed.first { $0.minutes == 10080 }
        var other = timed.filter { $0.minutes != 300 && $0.minutes != 10080 }
        if short == nil && !other.isEmpty { short = other.removeFirst() }
        if week == nil && !other.isEmpty { week = other.removeFirst() }
        return [short, week].compactMap { $0 }
    }
    public func stale(at date: Date) -> Bool {
        guard ok, queryOk != false, let observedAt, observedAt.isFinite else { return true }
        let age = date.timeIntervalSince1970 * 1000 - observedAt
        return age > 180000 || age < -5000
    }
}

public struct Quote: Decodable, Equatable {
    public let text: String
    public let weight: Double
    public init(text: String, weight: Double = 1) { self.text = text; self.weight = weight }
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let text = try? container.decode(String.self) {
            self.init(text: text); return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try container.decode(String.self, forKey: .text),
                  weight: try container.decodeIfPresent(Double.self, forKey: .weight) ?? 1)
    }
    private enum CodingKeys: String, CodingKey { case text, weight }
    public var valid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 200 &&
        weight.isFinite && weight > 0 && weight <= 1000 &&
        !text.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) }
    }
}

public enum QuoteFile {
    public static func editorText(_ quotes: [Quote]) -> String {
        quotes.map { $0.weight == 1 ? $0.text : "\($0.weight) | \($0.text)" }.joined(separator: "\n")
    }
    public static func editorQuotes(_ text: String) -> [Quote] {
        text.split(separator: "\n").compactMap { line -> Quote? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            guard let separator = value.firstIndex(of: "|"),
                  value[..<separator].trimmingCharacters(in: .whitespaces).range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
                  let weight = Double(value[..<separator].trimmingCharacters(in: .whitespaces)) else { return Quote(text: value) }
            return Quote(text: String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces), weight: weight)
        }
    }
    private struct Envelope: Decodable { let quotes: [Quote] }
    public static func decode(_ data: Data) throws -> [Quote] {
        // Windows' editable JSON may include a UTF-8 BOM.
        let content = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let decoder = JSONDecoder()
        let quotes: [Quote]
        if let envelope = try? decoder.decode(Envelope.self, from: content) { quotes = envelope.quotes }
        else { quotes = try decoder.decode([Quote].self, from: content) }
        return quotes.filter(\.valid)
    }
    public static func choose(_ quotes: [Quote], excluding previous: String?, draw: Double = Double.random(in: 0..<1)) -> String? {
        let valid = quotes.filter(\.valid)
        let different = valid.filter { $0.text != previous }
        let candidates = different.isEmpty ? valid : different
        guard let last = candidates.last else { return nil }
        var target = min(1, max(0, draw)) * candidates.reduce(0) { $0 + $1.weight }
        for quote in candidates { target -= quote.weight; if target < 0 { return quote.text } }
        return last.text
    }
}
