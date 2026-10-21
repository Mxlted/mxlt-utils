import Foundation

/// Whole-point content travel. The native adapter converts these to Quartz signs.
public struct ScrollDelta: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public static let zero = ScrollDelta(x: 0, y: 0)
}

/// Integrates a bounded target velocity without storing a backlog of scroll events.
/// Kept inside ScrollGesture so every stop also clears easing and fractional travel.
struct ScrollMotion: Sendable {
    private var velocity = ScrollVelocity.zero
    private var remainder = ScrollVelocity.zero
    private static let responseTime = 0.055

    mutating func step(toward target: ScrollVelocity, elapsed: TimeInterval,
                       smooth: Bool) -> ScrollDelta {
        guard elapsed.isFinite, elapsed > 0,
              target.x.isFinite, target.y.isFinite,
              hypot(target.x, target.y) <= ScrollGesture.maximumSpeed + 0.000001 else {
            reset()
            return .zero
        }
        // A delayed callback must not produce a catch-up jump.
        let dt = min(elapsed, 1.0 / 30)
        let x = stepAxis(target: target.x, current: velocity.x, remainder: remainder.x,
                         elapsed: dt, smooth: smooth)
        let y = stepAxis(target: target.y, current: velocity.y, remainder: remainder.y,
                         elapsed: dt, smooth: smooth)
        velocity = ScrollVelocity(x: x.velocity, y: y.velocity)
        remainder = ScrollVelocity(x: x.remainder, y: y.remainder)
        return ScrollDelta(x: x.delta, y: y.delta)
    }

    mutating func reset() {
        velocity = .zero
        remainder = .zero
    }

    private func stepAxis(target: Double, current: Double, remainder: Double,
                          elapsed: Double, smooth: Bool) -> (velocity: Double, remainder: Double, delta: Int32) {
        // Stop each axis immediately. A reversal must never emit old-direction travel.
        guard target != 0 else { return (0, 0, 0) }
        let reversed = (target > 0 && current < 0) || (target < 0 && current > 0)
        let initial = reversed ? 0 : current
        let carry = reversed ? 0 : remainder
        let next: Double
        let distance: Double
        if smooth {
            let blend = -expm1(-elapsed / Self.responseTime)
            next = initial + (target - initial) * blend
            // Exact integration makes travel independent of tick frequency for a
            // constant target, including fractional points at very low speeds.
            distance = target * elapsed + (initial - target) * Self.responseTime * blend
        } else {
            next = target
            distance = target * elapsed
        }
        let total = carry + distance
        let delta = Int32(total.rounded(.towardZero))
        return (next, total - Double(delta), delta)
    }
}
