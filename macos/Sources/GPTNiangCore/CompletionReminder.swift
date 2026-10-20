import Foundation

public struct CompletionReminderState {
    public enum Surface: Equatable { case foreground, background }
    public private(set) var pending = false
    public private(set) var surface: Surface?
    public private(set) var deadline: TimeInterval = 0
    public private(set) var acknowledgedAt: TimeInterval = 0
    public init() {}
    public mutating func receive(endedAt: TimeInterval) {
        if endedAt.isFinite && endedAt >= acknowledgedAt { pending = true }
    }
    public mutating func show(_ target: Surface, now: TimeInterval, openingDelay: TimeInterval = 0) {
        guard surface == nil, pending else { return }
        surface = target; deadline = now + openingDelay + 5
    }
    public mutating func pause() { surface = nil; deadline = 0 }
    public mutating func dismiss(now: TimeInterval) {
        pending = false; acknowledgedAt = now; pause()
    }
}
