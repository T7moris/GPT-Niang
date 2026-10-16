import Foundation
import CoreGraphics

public struct FollowWindowTarget: Equatable {
    public let number: Int
    public let frame: CGRect
    public let area: CGRect
    public let scale: Double

    public init(number: Int, frame: CGRect, area: CGRect, scale: Double) {
        self.number = number
        self.frame = frame
        self.area = area
        self.scale = scale
    }
}

/// Rejects Stage Manager thumbnails and waits for a newly visible host to settle.
/// Callers supply monotonic uptime and whether the host belongs to the active stage.
public struct WindowFollowPolicy {
    private static let widgetSide: CGFloat = 378
    private static let minimumScale = 0.6
    private static let settleInterval: TimeInterval = 0.15
    private static let sizeTolerance: CGFloat = 2

    private var pending: FollowWindowTarget?
    private var pendingSince: TimeInterval?
    private var visibleNumber: Int?
    private var lastTime: TimeInterval?

    public init() {}

    public static func target(number: Int, frame: CGRect, visibleScreen: CGRect,
                              requestedScale: Double) -> FollowWindowTarget? {
        guard finite(frame), finite(visibleScreen), requestedScale.isFinite,
              frame.width >= 480, frame.height >= 300,
              visibleScreen.width > 0, visibleScreen.height > 0 else { return nil }
        let area = frame.intersection(visibleScreen)
        let minimumSide = widgetSide * minimumScale
        guard !area.isNull, !area.isEmpty, finite(area),
              area.width >= minimumSide, area.height >= minimumSide else { return nil }
        let scale = min(requestedScale, Double(area.width / widgetSide),
                        Double(area.height / widgetSide))
        guard scale >= minimumScale else { return nil }
        return FollowWindowTarget(number: number, frame: frame, area: area, scale: scale)
    }

    public mutating func update(target: FollowWindowTarget?, now: TimeInterval,
                                allowed: Bool) -> FollowWindowTarget? {
        guard allowed, let target, now.isFinite else {
            clear()
            return nil
        }
        // A clock rollback must never leave a pending window waiting indefinitely.
        if let lastTime, now < lastTime { clear() }
        lastTime = now

        // Once shown, normal dragging and resizing remain continuous. Invalid
        // geometry or an inactive stage is hidden above/by target(), then must
        // settle again before reappearing, preventing thumbnail/desktop flashes.
        if visibleNumber == target.number { return target }
        visibleNumber = nil

        if let pending, pending.number == target.number,
           abs(pending.frame.width - target.frame.width) <= Self.sizeTolerance,
           abs(pending.frame.height - target.frame.height) <= Self.sizeTolerance {
            if let pendingSince, now - pendingSince >= Self.settleInterval {
                visibleNumber = target.number
                self.pending = nil
                self.pendingSince = nil
                return target
            }
        } else {
            pending = target
            pendingSince = now
        }
        return nil
    }

    private mutating func clear() {
        pending = nil
        pendingSince = nil
        visibleNumber = nil
        lastTime = nil
    }

    private static func finite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite
    }
}
