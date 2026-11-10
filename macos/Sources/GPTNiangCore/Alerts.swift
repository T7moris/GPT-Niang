import Foundation

public enum AlertSound: String, Codable, CaseIterable, Sendable {
    case original, ping, glass, pop, tink, basso
    public var titleKey: String {
        switch self {
        case .original: return "原有提示音"
        case .ping: return "清脆 · Ping"
        case .glass: return "玻璃 · Glass"
        case .pop: return "轻点 · Pop"
        case .tink: return "轻铃 · Tink"
        case .basso: return "低音 · Basso"
        }
    }
    public var systemName: String? {
        switch self {
        case .original: return nil
        case .ping: return "Ping"
        case .glass: return "Glass"
        case .pop: return "Pop"
        case .tink: return "Tink"
        case .basso: return "Basso"
        }
    }
}

public enum TaskAlertKind: String, Codable, CaseIterable, Sendable {
    case command, permission, question, completion, generic
    public var messageKey: String {
        switch self {
        case .command: return "需要允许执行命令"
        case .permission: return "需要你的授权"
        case .question: return "需要回答问题"
        case .completion: return "本轮回复已结束"
        case .generic: return "ChatGPT 有新提醒，请查看"
        }
    }
}

public struct AlertPreferences: Codable, Equatable {
    public var shortEnabled = false
    public var weekEnabled = false
    public var shortResetEnabled = false
    public var weekResetEnabled = false
    public var shortThreshold = 20
    public var weekThreshold = 20
    public var completionEnabled = false
    public var soundEnabled = false
    public var completionPopupEnabled = false
    public var completionSoundEnabled = false
    public var commandEnabled = false
    public var commandSoundEnabled = false
    public var commandPopupEnabled = false
    public var questionEnabled = false
    public var questionSoundEnabled = false
    public var questionPopupEnabled = false
    public var completionTone: AlertSound = .original
    public var commandTone: AlertSound = .original
    public var questionTone: AlertSound = .original
    public var quotaTone: AlertSound = .original
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case shortResetEnabled, weekResetEnabled
        case shortEnabled, weekEnabled, shortThreshold, weekThreshold, completionEnabled, soundEnabled, completionPopupEnabled
        case completionSoundEnabled, commandEnabled, commandSoundEnabled, commandPopupEnabled
        case questionEnabled, questionSoundEnabled, questionPopupEnabled
        case completionTone, commandTone, questionTone, quotaTone
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shortEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortEnabled) ?? false
        weekEnabled = try values.decodeIfPresent(Bool.self, forKey: .weekEnabled) ?? false
        shortResetEnabled = try values.decodeIfPresent(Bool.self, forKey: .shortResetEnabled) ?? false
        weekResetEnabled = try values.decodeIfPresent(Bool.self, forKey: .weekResetEnabled) ?? false
        shortThreshold = try values.decodeIfPresent(Int.self, forKey: .shortThreshold) ?? 20
        weekThreshold = try values.decodeIfPresent(Int.self, forKey: .weekThreshold) ?? 20
        completionEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionEnabled) ?? false
        soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        completionPopupEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionPopupEnabled) ?? false
        completionSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionSoundEnabled) ?? soundEnabled
        commandEnabled = try values.decodeIfPresent(Bool.self, forKey: .commandEnabled) ?? completionEnabled
        questionEnabled = try values.decodeIfPresent(Bool.self, forKey: .questionEnabled) ?? completionEnabled
        commandSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .commandSoundEnabled) ?? soundEnabled
        questionSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .questionSoundEnabled) ?? soundEnabled
        commandPopupEnabled = try values.decodeIfPresent(Bool.self, forKey: .commandPopupEnabled) ?? completionPopupEnabled
        questionPopupEnabled = try values.decodeIfPresent(Bool.self, forKey: .questionPopupEnabled) ?? completionPopupEnabled
        completionTone = (try? values.decode(AlertSound.self, forKey: .completionTone)) ?? .original
        commandTone = (try? values.decode(AlertSound.self, forKey: .commandTone)) ?? .original
        questionTone = (try? values.decode(AlertSound.self, forKey: .questionTone)) ?? .original
        quotaTone = (try? values.decode(AlertSound.self, forKey: .quotaTone)) ?? .original
        validate()
    }
    public var taskEnabled: Bool { completionEnabled || commandEnabled || questionEnabled }
    public func enabled(for kind: TaskAlertKind) -> Bool {
        switch kind {
        case .completion, .generic: return completionEnabled
        case .command, .permission: return commandEnabled
        case .question: return questionEnabled
        }
    }
    public func sound(for kind: TaskAlertKind) -> Bool {
        switch kind {
        case .completion, .generic: return completionSoundEnabled
        case .command, .permission: return commandSoundEnabled
        case .question: return questionSoundEnabled
        }
    }
    public func tone(for kind: TaskAlertKind) -> AlertSound {
        switch kind {
        case .completion, .generic: return completionTone
        case .command, .permission: return commandTone
        case .question: return questionTone
        }
    }
    public func popup(for kind: TaskAlertKind) -> Bool {
        switch kind {
        case .completion, .generic: return completionPopupEnabled
        case .command, .permission: return commandPopupEnabled
        case .question: return questionPopupEnabled
        }
    }
    public var anyTaskPopup: Bool { TaskAlertKind.allCases.contains { enabled(for: $0) && popup(for: $0) } }
    public var quotaEnabled: Bool { shortEnabled || weekEnabled || shortResetEnabled || weekResetEnabled }
    public mutating func validate() {
        shortThreshold = min(99, max(1, shortThreshold))
        weekThreshold = min(99, max(1, weekThreshold))
    }
}

public struct QuotaAlert: Equatable {
    public let window: QuotaWindow
    public let exhausted: Bool
    public var reset: Bool = false
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
    public struct ResetObservation: Codable, Equatable {
        public let weekly: Bool
        public let resetsAt: Double
        public let observedAt: Double
    }
    public var latches: [String: Latch] = [:]
    public var resetObservations: [String: ResetObservation] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case latches, resetObservations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latches = try values.decodeIfPresent([String: Latch].self, forKey: .latches) ?? [:]
        resetObservations = try values.decodeIfPresent([String: ResetObservation].self, forKey: .resetObservations) ?? [:]
    }
    // Called on preference changes even when all quota monitoring is disabled.
    public mutating func synchronizeResetPreferences(_ preferences: AlertPreferences) {
        resetObservations = resetObservations.filter {
            $0.value.weekly ? preferences.weekResetEnabled : preferences.shortResetEnabled
        }
    }
    public mutating func evaluate(_ snapshot: UsageSnapshot, preferences: AlertPreferences, now: Date) -> [QuotaAlert] {
        synchronizeResetPreferences(preferences)
        guard snapshot.ok, snapshot.queryOk == true, !snapshot.stale(at: now),
              let account = snapshot.accountKey, !account.isEmpty else { return [] }
        let windows = snapshot.validWindows
        let short = windows.filter { !$0.isIndividual && ($0.minutes ?? 0) < 1440 }
            .min { ($0.minutes ?? 0) < ($1.minutes ?? 0) }
        let week = windows.first { $0.minutes == 10080 }
        var alerts: [QuotaAlert] = []
        for (window, enabled) in [(short, preferences.shortResetEnabled), (week, preferences.weekResetEnabled)] {
            guard enabled, let window, !window.expired(at: now),
                  let reset = window.resetsAt, reset.isFinite, reset > 0, reset <= 253402271999,
                  let observed = snapshot.observedAt else { continue }
            let key = account + ":" + window.id
            if let previous = resetObservations[key] {
                // Repeated/out-of-order replies cannot move the baseline backwards.
                guard observed > previous.observedAt, reset >= previous.resetsAt else { continue }
                if previous.resetsAt <= observed / 1000, previous.resetsAt <= now.timeIntervalSince1970,
                   reset > previous.resetsAt {
                    alerts.append(QuotaAlert(window: window, exhausted: false, reset: true))
                }
            }
            resetObservations[key] = ResetObservation(weekly: window.minutes == 10080, resetsAt: reset, observedAt: observed)
        }
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
