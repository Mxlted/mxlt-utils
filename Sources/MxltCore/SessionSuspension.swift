/// Sleep, display sleep, and session activity are independent. Waking the display
/// on a locked Mac must not resume features while the user session is inactive.
public struct SessionSuspension: Equatable, Sendable {
    public enum Reason: Hashable, Sendable { case systemSleep, displaySleep, inactiveSession }
    private var reasons: Set<Reason> = []
    public var isSuspended: Bool { !reasons.isEmpty }

    public init() {}

    public mutating func set(_ reason: Reason, suspended: Bool) {
        if suspended { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
