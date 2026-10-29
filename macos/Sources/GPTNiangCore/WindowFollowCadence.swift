import Foundation

// Use monotonic uptime so wall-clock adjustments cannot suspend following.
public struct WindowFollowCadence {
    private var lastDiscovery = -Double.infinity
    private var lastPresence = -Double.infinity
    private var lastDiagnostics = -Double.infinity
    private var visible: Bool?

    public init() {}

    public mutating func discover(now: TimeInterval, force: Bool = false) -> Bool {
        guard force || now - lastDiscovery >= 0.25 else { return false }
        lastDiscovery = now
        return true
    }

    public mutating func presence(now: TimeInterval, visible: Bool) -> Bool {
        guard self.visible != visible || now - lastPresence >= 1 else { return false }
        self.visible = visible
        lastPresence = now
        return true
    }

    public mutating func diagnostics(now: TimeInterval) -> Bool {
        guard now - lastDiagnostics >= 0.25 else { return false }
        lastDiagnostics = now
        return true
    }
}

// isVisible stays true when a panel slips behind its host (for example after
// switching Spaces or closing settings). Repair that ordering on discovery.
public enum WindowFollowOrdering {
    public static func needsOrdering(frontToBack: [Int], host: Int, panel: Int) -> Bool {
        guard let hostIndex = frontToBack.firstIndex(of: host) else { return false }
        guard let panelIndex = frontToBack.firstIndex(of: panel) else { return true }
        return panelIndex > hostIndex
    }
}

// Only an unavailable WindowServer reply gets a short anti-flicker grace.
// A successful snapshot showing no eligible host (minimized/closed/off-Space)
// is authoritative and must not leave the pet floating after its host is gone.
public enum WindowFollowVisibility {
    public static func keepDuringMissingHost(appHidden: Bool, confirmedMissing: Bool, missingFor: TimeInterval) -> Bool {
        !appHidden && !confirmedMissing && missingFor >= 0 && missingFor < 0.75
    }
}

// Poll quickly only during real motion; a static accessory should not keep a
// 60 Hz run-loop timer alive in desktop mode or behind another application.
public enum WidgetRefreshPolicy {
    public static func windowInterval(follow: Bool, foreground: Bool, moving: Bool) -> TimeInterval {
        guard follow else { return 1 }
        guard foreground else { return 1 }
        return moving ? 1.0 / 60 : 0.1
    }
    public static func animates(visible: Bool, bubble: Bool, fullColor: Bool, textColor: Bool) -> Bool {
        visible && (fullColor || (bubble && textColor))
    }
}
