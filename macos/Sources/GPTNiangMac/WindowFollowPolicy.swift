import AppKit

/// Decisions independent of WindowServer, so transitions can be regression tested.
struct WindowFollowPolicy {
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
        .stationary, .ignoresCycle
    ]

    func mayFollow(stageManager: Bool, hostActive: Bool, companionActive: Bool, frontmostOnAnotherScreen: Bool) -> Bool {
        !stageManager || hostActive || companionActive || frontmostOnAnotherScreen
    }

    static func level(hostActive: Bool, companionActive: Bool) -> NSWindow.Level {
        // A click can raise the host before the next polling tick. Keeping the
        // active companion at floating level prevents that visible one-tick dip.
        hostActive || companionActive ? .floating : .normal
    }

    static func screen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        screens.filter { !$0.intersection(frame).isEmpty }.max {
            let a = $0.intersection(frame), b = $1.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
    }

    static func usableHost(_ frame: CGRect, screens: [CGRect], allowClipped: Bool = false) -> Bool {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.width >= 480, frame.height >= 300 else { return false }
        // Stage Manager and Space animations can leave an "onscreen" window
        // outside the actual displays. Never place the widget on a fallback screen.
        return screens.contains {
            let intersection = frame.intersection($0)
            return !intersection.isNull && (allowClipped
                ? intersection.width > 0 && intersection.height > 0
                : intersection.width >= 240 && intersection.height >= 150)
        }
    }

    static func needsOrdering(host: Int, panel: Int, frontToBack: [Int]) -> Bool {
        guard let hostIndex = frontToBack.firstIndex(of: host) else { return false }
        guard let panelIndex = frontToBack.firstIndex(of: panel) else { return true }
        return panelIndex > hostIndex
    }
}

/// A desktop click can activate Finder without an ordinary onscreen window.
/// Keep the interaction's display as a fallback; pointer motion alone must not
/// change which display is considered active.
struct FocusDisplayTracker {
    private var interactionScreen: CGRect?

    mutating func recordInteraction(at point: CGPoint, screens: [CGRect]) {
        interactionScreen = screens.first { $0.contains(point) }
    }

    func resolve(window: CGRect?, screens: [CGRect]) -> CGRect? {
        if let window, let screen = WindowFollowPolicy.screen(for: window, screens: screens) {
            return screen
        }
        // A disconnected or rearranged display must not remain the fallback.
        return interactionScreen.flatMap { screens.contains($0) ? $0 : nil }
    }
}

/// WindowServer reports animated Space positions as real coordinates, including
/// positions on a neighbouring monitor. Follow a mouse drag immediately, but
/// hide during other geometry transitions until the host stops moving.
struct HostGeometryStability {
    private struct Sample {
        var number: Int
        var frame: CGRect
        func matches(_ other: Sample) -> Bool {
            number == other.number && abs(frame.minX - other.frame.minX) <= 1 &&
                abs(frame.minY - other.frame.minY) <= 1 && abs(frame.width - other.frame.width) <= 1 &&
                abs(frame.height - other.frame.height) <= 1
        }
    }
    func isTracking(number: Int) -> Bool { accepted?.number == number }

    private var accepted: Sample?
    private var pending: Sample?
    private var stableSince: TimeInterval = 0
    private(set) var transitioning = false

    mutating func accept(number: Int, frame: CGRect, screens: [CGRect], now: TimeInterval, mouseDraggingHost: Bool) -> Bool {
        let sample = Sample(number: number, frame: frame)
        if mouseDraggingHost || accepted == nil {
            accepted = sample; pending = nil; transitioning = false
            return true
        }
        if let pending {
            if !sample.matches(pending) {
                self.pending = sample; stableSince = now
            } else if now - stableSince >= 0.3 && !isFullscreenSlide(sample, screens: screens) {
                accepted = sample; self.pending = nil; transitioning = false
                return true
            }
            return false
        }
        if let accepted, !sample.matches(accepted) {
            pending = sample; stableSince = now; transitioning = true
            return false
        }
        return true
    }

    private func isFullscreenSlide(_ sample: Sample, screens: [CGRect]) -> Bool {
        guard let accepted, accepted.number == sample.number,
              let originalScreen = WindowFollowPolicy.screen(for: accepted.frame, screens: screens),
              abs(accepted.frame.width - originalScreen.width) <= 4,
              abs(accepted.frame.minX - originalScreen.minX) <= 4,
              accepted.frame.height >= originalScreen.height * 0.85,
              abs(sample.frame.width - accepted.frame.width) <= 4,
              abs(sample.frame.height - accepted.frame.height) <= 4 else { return false }
        // A full-screen Space slides as a fixed-size surface. Even if the
        // gesture pauses, that surface must not become a host on another monitor.
        return abs(sample.frame.minX - originalScreen.minX) > 4 ||
            abs(sample.frame.minY - accepted.frame.minY) > 4
    }
}
