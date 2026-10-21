import Foundation

/// Global Quartz coordinates, in logical points, with positive Y pointing down.
public struct ScrollPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// Desired content travel in points per second: positive X/right, positive Y/down.
/// The event adapter converts this to Quartz scroll delta signs.
public struct ScrollVelocity: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public static let zero = ScrollVelocity(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScrollSettings: Equatable, Sendable {
    public static let sensitivityRange = 0.2...10.0
    public static let smoothSpeedRange = 0.2...3.0
    public static let deadZoneRange = 2.0...40.0
    public let sensitivity: Double
    public let deadZone: Double
    public let reversed: Bool
    public let smooth: Bool
    public let smoothSpeed: Double

    // Preserve the established speed ceiling for existing settings; the extended
    // range raises it proportionally, up to 8,000 points per second at 10x.
    var speedLimit: Double { 2_400 * max(1, sensitivity / 3) }
    var responseTime: TimeInterval { 0.055 / smoothSpeed }

    public init(sensitivity: Double = 1, deadZone: Double = 8, reversed: Bool = false, smooth: Bool = true,
                smoothSpeed: Double = 1) {
        self.sensitivity = Self.sanitize(sensitivity, fallback: 1, range: Self.sensitivityRange)
        self.deadZone = Self.sanitize(deadZone, fallback: 8, range: Self.deadZoneRange)
        self.reversed = reversed
        self.smooth = smooth
        self.smoothSpeed = Self.sanitize(smoothSpeed, fallback: 1, range: Self.smoothSpeedRange)
    }

    private static func sanitize(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

public enum ScrollRelease: Equatable, Sendable {
    /// A short, stationary press. The adapter may replay a paired click only after
    /// independently revalidating the original process, window, and anchor.
    case replayClick
    /// The intercepted press was a scroll, cancelled, expired, or no longer safe.
    case consumed
    /// There was no intercepted press to complete.
    case none
}

/// One held middle-button gesture. Owns no timers, input events, or native objects.
/// Native target validation and event suppression belong to the event adapter.
public struct ScrollGesture: Sendable {
    public enum Phase: Equatable, Sendable { case idle, pending, scrolling, cancelled }

    public static let maximumClickDuration: TimeInterval = 0.5
    public static let maximumSpeed: Double = 8_000
    public private(set) var phase: Phase = .idle
    public private(set) var anchor: ScrollPoint?
    public private(set) var velocity: ScrollVelocity = .zero
    private var settings = ScrollSettings()
    private var startedAt: TimeInterval = 0
    private var motion = ScrollMotion()

    public init() {}

    /// Returns false for malformed input or a duplicate down. A duplicate down
    /// never replaces the anchor of an intercepted gesture.
    @discardableResult
    public mutating func begin(at point: ScrollPoint, timestamp: TimeInterval,
                               settings: ScrollSettings = ScrollSettings()) -> Bool {
        guard phase == .idle, point.isFinite, timestamp.isFinite, timestamp >= 0 else { return false }
        anchor = point
        startedAt = timestamp
        self.settings = settings
        velocity = .zero
        motion.reset()
        phase = .pending
        return true
    }

    /// Returns true only on the transition into scrolling. After crossing the
    /// dead zone, returning to it stops motion but cannot restore click replay.
    @discardableResult
    public mutating func move(to point: ScrollPoint) -> Bool {
        guard phase == .pending || phase == .scrolling, let anchor else { return false }
        guard point.isFinite else {
            cancel()
            return false
        }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let distance = hypot(dx, dy)
        guard distance.isFinite else {
            cancel()
            return false
        }
        guard distance > settings.deadZone else {
            velocity = .zero
            motion.reset()
            return false
        }
        let activated = phase == .pending
        phase = .scrolling
        let speed = min(settings.speedLimit, (distance - settings.deadZone) * 8 * settings.sensitivity)
        let direction = settings.reversed ? -1.0 : 1.0
        velocity = ScrollVelocity(x: dx / distance * speed * direction,
                                  y: dy / distance * speed * direction)
        return activated
    }

    /// Called only after native target validation. Never queues travel for later delivery.
    public mutating func scrollDelta(elapsed: TimeInterval) -> ScrollDelta {
        guard phase == .scrolling, velocity != .zero else {
            motion.reset()
            return .zero
        }
        return motion.step(toward: velocity, elapsed: elapsed, smooth: settings.smooth,
                           responseTime: settings.responseTime)
    }

    /// Checks the release position too: a missed final move must not become a
    /// click. No momentum or velocity survives release, including invalid input.
    public mutating func release(at point: ScrollPoint, timestamp: TimeInterval,
                                 targetIsValid: Bool) -> ScrollRelease {
        guard phase != .idle else { return .none }
        move(to: point)
        let elapsed = timestamp - startedAt
        let mayReplay = phase == .pending && targetIsValid && timestamp.isFinite
            && elapsed >= 0 && elapsed <= Self.maximumClickDuration
        reset()
        return mayReplay ? .replayClick : .consumed
    }

    /// Retains a cancelled phase so the eventual physical button-up is consumed.
    /// Repeated cancel is safe and never creates an intercepted gesture from idle.
    public mutating func cancel() {
        guard phase != .idle else { return }
        phase = .cancelled
        velocity = .zero
        motion.reset()
    }

    /// For final teardown after the native adapter has handled its input pairing.
    public mutating func reset() {
        phase = .idle
        anchor = nil
        velocity = .zero
        motion.reset()
        startedAt = 0
    }
}
