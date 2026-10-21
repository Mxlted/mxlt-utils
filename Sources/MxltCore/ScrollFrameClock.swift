import Foundation

/// Measures accepted output frames, so a skipped validation does not drop travel.
/// Reset at every stop; long gaps are bounded rather than queued for catch-up.
public struct ScrollFrameClock: Sendable {
    private var previous: TimeInterval?

    public init() {}

    public mutating func reset() { previous = nil }

    public mutating func advance(at timestamp: TimeInterval, initialInterval: TimeInterval) -> TimeInterval {
        guard timestamp.isFinite, timestamp >= 0,
              initialInterval.isFinite, initialInterval > 0 else {
            reset()
            return 0
        }
        let elapsed = previous.map { timestamp - $0 } ?? initialInterval
        previous = timestamp
        guard elapsed > 0 else { return 0 }
        return min(elapsed, 1.0 / 30)
    }
}
