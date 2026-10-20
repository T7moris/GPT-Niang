import Foundation

/// Count a full quiet interval after visibility, interaction, or sleep changes.
/// Uses monotonic seconds; never catches up by showing several missed quotes.
public struct AutoQuoteSchedule {
    public static let intervals = [60, 300, 900]
    private var lastTick: Double?
    private var nextQuote: Double?
    private var previousEnabled = false
    private var previousInterval = 300

    public init() {}

    public static func validInterval(_ value: Int) -> Int {
        intervals.contains(value) ? value : 300
    }

    public mutating func poll(now: Double, enabled: Bool, interval: Int, eligible: Bool) -> Bool {
        let interval = Self.validInterval(interval)
        let gap = lastTick.map { now - $0 }
        let reset = enabled != previousEnabled || interval != previousInterval ||
            gap == nil || gap! < 0 || gap! > 5
        previousEnabled = enabled
        previousInterval = interval
        lastTick = now
        guard enabled, eligible, now.isFinite else { nextQuote = nil; return false }
        if reset || nextQuote == nil { nextQuote = now + Double(interval); return false }
        guard now >= nextQuote! else { return false }
        nextQuote = now + Double(interval)
        return true
    }
}
