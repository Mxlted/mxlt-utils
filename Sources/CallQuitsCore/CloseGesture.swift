// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import Foundation

/// Tabs and shortcuts may close only part of a window. They never inherit the
/// red button's any-window or force-quit behavior.
public enum CloseTrigger: Sendable {
    case windowButton, tabButton, keyboardShortcut

    public func behavior(configured: CloseBehavior) -> CloseBehavior {
        self == .windowButton ? configured : .lastWindow
    }

    public var allowsForceQuit: Bool { self == .windowButton }
}

public enum CloseShortcut {
    /// Match the layout-resolved character, not the physical QWERTY W position.
    /// Missing text, repeats and modified shortcuts remain the application's own commands.
    public static func matches(character: String?, command: Bool, shift: Bool,
                               option: Bool, control: Bool, isRepeat: Bool) -> Bool {
        command && !shift && !option && !control && !isRepeat && character?.lowercased() == "w"
    }
}

/// Pins a shortcut request to one native recipient and a bounded capture interval.
/// Window observation alone authorizes nothing; a matching W is mandatory.
public struct CloseShortcutIntent: Sendable {
    public let startedAt: TimeInterval
    public private(set) var requestedAt: TimeInterval?
    private let processID: Int32

    public init?(processID: Int32, startedAt: TimeInterval) {
        guard processID > 1, startedAt.isFinite, startedAt >= 0 else { return nil }
        self.processID = processID
        self.startedAt = startedAt
    }

    public mutating func request(processID: Int32, at timestamp: TimeInterval) -> Bool {
        guard requestedAt == nil, processID == self.processID, timestamp.isFinite,
              timestamp >= startedAt, timestamp - startedAt < CloseSession.maximumDuration else { return false }
        requestedAt = timestamp
        return true
    }

    public func isReady(at timestamp: TimeInterval) -> Bool {
        guard let requestedAt, timestamp.isFinite, timestamp >= requestedAt else { return false }
        return timestamp - requestedAt < 0.8
    }
}

/// The integration maps input modifiers to these values. `.force` requires explicit opt-in.
public enum CloseGestureModifiers: Equatable, Sendable {
    case normal
    case force
    case bypass
}

public enum CloseGestureAction: Equatable, Sendable {
    case graceful
    case force
}

/// Validates the pointer sequence independently of Accessibility and AppKit.
///
/// The integration must positively identify the actual close button and compare its application's
/// PID with the verified event identity. When the native PID is missing, verified ownership of
/// the exact event-stamped window is supported; never substitute the frontmost application.
/// Store this value only for the current press; discard it on release, an invalid drag, or cancellation.
public struct CloseGesture: Sendable {
    public static let maximumMovement: Double = 4
    public static let maximumDuration: TimeInterval = 3

    private let x: Double
    private let y: Double
    private let timestamp: TimeInterval
    private let targetProcessID: Int32
    private let modifiers: CloseGestureModifiers

    public init?(
        x: Double,
        y: Double,
        timestamp: TimeInterval,
        targetProcessID: Int32,
        modifiers: CloseGestureModifiers
    ) {
        guard x.isFinite, y.isFinite, timestamp.isFinite, timestamp >= 0,
              targetProcessID > 1, modifiers != .bypass else { return nil }
        self.x = x
        self.y = y
        self.timestamp = timestamp
        self.targetProcessID = targetProcessID
        self.modifiers = modifiers
    }

    public func allowsDrag(toX x: Double, y: Double) -> Bool {
        guard x.isFinite, y.isFinite else { return false }
        return hypot(x - self.x, y - self.y) <= Self.maximumMovement
    }

    public func actionOnRelease(
        x: Double,
        y: Double,
        timestamp: TimeInterval,
        targetProcessID: Int32,
        modifiers: CloseGestureModifiers
    ) -> CloseGestureAction? {
        guard timestamp.isFinite, timestamp >= self.timestamp,
              timestamp - self.timestamp <= Self.maximumDuration,
              targetProcessID == self.targetProcessID,
              modifiers == self.modifiers,
              allowsDrag(toX: x, y: y) else { return nil }
        return modifiers == .force ? .force : .graceful
    }
}
