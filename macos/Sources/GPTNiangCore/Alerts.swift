import Foundation

public struct AlertPreferences: Codable, Equatable {
    public var shortEnabled = false
    public var weekEnabled = false
    public var shortThreshold = 20
    public var weekThreshold = 20
    public var completionEnabled = false
    public var soundEnabled = false
    public var completionPopupEnabled = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case shortEnabled, weekEnabled, shortThreshold, weekThreshold, completionEnabled, soundEnabled, completionPopupEnabled
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shortEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortEnabled) ?? false
        weekEnabled = try values.decodeIfPresent(Bool.self, forKey: .weekEnabled) ?? false
        shortThreshold = try values.decodeIfPresent(Int.self, forKey: .shortThreshold) ?? 20
        weekThreshold = try values.decodeIfPresent(Int.self, forKey: .weekThreshold) ?? 20
        completionEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionEnabled) ?? false
        soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        completionPopupEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionPopupEnabled) ?? false
        validate()
    }
    public var quotaEnabled: Bool { shortEnabled || weekEnabled }
    public mutating func validate() {
        shortThreshold = min(99, max(1, shortThreshold))
        weekThreshold = min(99, max(1, weekThreshold))
    }
}

public struct QuotaAlert: Equatable {
    public let window: QuotaWindow
    public let exhausted: Bool
}

// Persist latches, not raw account identities or quota replies. Evaluation is
// pure: the caller commits the new state atomically before delivering alerts.
public struct QuotaAlertState: Codable, Equatable {
    public struct Latch: Codable, Equatable {
        public var threshold: Int
        public var low: Bool
        public var exhausted: Bool
        public var resetsAt: Double? = nil
    }
    public var latches: [String: Latch] = [:]
    public init() {}
    public mutating func evaluate(_ snapshot: UsageSnapshot, preferences: AlertPreferences, now: Date) -> [QuotaAlert] {
        guard snapshot.ok, snapshot.queryOk == true, !snapshot.stale(at: now),
              let account = snapshot.accountKey, !account.isEmpty else { return [] }
        let windows = snapshot.validWindows
        let short = windows.filter { !$0.isIndividual && ($0.minutes ?? 0) < 1440 }
            .min { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let week = windows.first { $0.minutes == 10080 }
        var alerts: [QuotaAlert] = []
        for (window, enabled, rawThreshold) in [(short, preferences.shortEnabled, preferences.shortThreshold),
                                               (week, preferences.weekEnabled, preferences.weekThreshold)] {
            guard enabled, let window, !window.expired(at: now) else { continue }
            let threshold = min(99, max(1, rawThreshold))
            let key = account + ":" + window.id
            var latch = latches[key] ?? Latch(threshold: threshold, low: false, exhausted: false)
            if latch.threshold != threshold { latch = Latch(threshold: threshold, low: false, exhausted: false) }
            if let oldReset = latch.resetsAt, let newReset = window.resetsAt,
               let observed = snapshot.observedAt, oldReset <= observed / 1000, newReset > oldReset {
                latch.low = false; latch.exhausted = false
            }
            latch.resetsAt = window.resetsAt
            if window.remaining > Double(threshold) {
                latch.low = false; latch.exhausted = false
            } else if window.remaining == 0 {
                if !latch.exhausted { alerts.append(QuotaAlert(window: window, exhausted: true)) }
                latch.low = true; latch.exhausted = true
            } else if !latch.low {
                alerts.append(QuotaAlert(window: window, exhausted: false)); latch.low = true
            }
            latches[key] = latch
        }
        return alerts
    }
}

// Queue one compact bubble. Foreground user interaction always wins. Expire
// queued events rather than announcing old completions after a long absence.
public struct AlertBubbleQueue {
    private struct Entry { let text: String; let expires: Date }
    private var messages: [Entry] = []
    public init() {}
    public mutating func append(_ text: String, now: Date) {
        messages.removeAll { now > $0.expires }
        if !messages.contains(where: { $0.text == text }) { messages.append(Entry(text: text, expires: now.addingTimeInterval(120))) }
        if messages.count > 4 { messages.removeFirst(messages.count - 4) }
    }
    public mutating func take(now: Date, visible: Bool, busy: Bool) -> String? {
        messages.removeAll { now > $0.expires }
        guard visible, !busy, !messages.isEmpty else { return nil }
        let text = messages.map(\.text).joined(separator: "\n")
        messages = []; return text
    }
    public mutating func clear() { messages = [] }
}

// Presentation policy is independent of the audio switch and desktop placement.
public enum CompletionPresentation {
    public static func shouldPopup(preferences: AlertPreferences, followCodex: Bool,
                                   hostFrontmost: Bool, mainVisible: Bool) -> Bool {
        preferences.completionEnabled && preferences.completionPopupEnabled && followCodex &&
            (!hostFrontmost || !mainVisible)
    }
}

public struct CompletionPopupLifetime {
    public private(set) var count = 0
    public private(set) var deadline = -Double.infinity
    public init() {}
    public func visible(now: TimeInterval) -> Bool { count > 0 && now < deadline }
    public mutating func record(count incoming: Int, now: TimeInterval) {
        guard incoming > 0 else { return }
        if !visible(now: now) { count = 0 }
        count = min(999, count + min(999, incoming))
        deadline = now + 6
    }
    public mutating func dismiss() { count = 0; deadline = -Double.infinity }
}
