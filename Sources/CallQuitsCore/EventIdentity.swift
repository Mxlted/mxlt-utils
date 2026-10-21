// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
/// The original recipient of a mouse press, established using event metadata rather than
/// the current frontmost application or whatever window happens to occupy the click point later.
public struct EventIdentity: Equatable, Sendable {
    public let processID: Int32
    public let windowID: UInt32?

    /// Zero native process/window IDs mean that metadata is absent. The owner PID, when supplied,
    /// must come from a WindowServer lookup of this exact event-stamped global window ID.
    /// Never supply a guessed window ID, screen-location lookup, or an AppKit window-device number.
    public init?(
        nativeProcessID: Int64,
        eventWindowID: Int64,
        windowOwnerProcessID: Int64?
    ) {
        guard Self.metadataIsValid(nativeProcessID: nativeProcessID,
                                   eventWindowID: eventWindowID,
                                   windowOwnerProcessID: windowOwnerProcessID) else { return nil }
        let nativePID = Self.processID(nativeProcessID)
        let ownerPID = windowOwnerProcessID.flatMap(Self.processID)
        if let nativePID, let ownerPID, nativePID != ownerPID { return nil }
        guard let resolvedPID = nativePID ?? ownerPID else { return nil }
        processID = resolvedPID
        windowID = eventWindowID == 0 ? nil : UInt32(eventWindowID)
    }

    /// Mouse-up may arrive after native close has removed the original WindowServer entry.
    /// A missing owner lookup is therefore allowed only with matching event identity: a matching
    /// native target PID, or the exact original nonzero stamped window ID. Conflicting positive
    /// native PID, window ID, or owner PID always cancels, even when another field matches.
    public func matchesRelease(
        nativeProcessID: Int64,
        eventWindowID: Int64,
        windowOwnerProcessID: Int64?
    ) -> Bool {
        guard Self.metadataIsValid(nativeProcessID: nativeProcessID,
                                   eventWindowID: eventWindowID,
                                   windowOwnerProcessID: windowOwnerProcessID) else { return false }
        let releaseWindowID = eventWindowID == 0 ? nil : UInt32(eventWindowID)
        if let windowID, let releaseWindowID, windowID != releaseWindowID { return false }
        if let ownerPID = windowOwnerProcessID.flatMap(Self.processID), ownerPID != processID { return false }
        if let nativePID = Self.processID(nativeProcessID) { return nativePID == processID }
        guard let windowID, let releaseWindowID else { return false }
        return windowID == releaseWindowID
    }

    private static func processID(_ value: Int64) -> Int32? {
        guard value > 1, value <= Int64(Int32.max) else { return nil }
        return Int32(value)
    }

    private static func metadataIsValid(
        nativeProcessID: Int64,
        eventWindowID: Int64,
        windowOwnerProcessID: Int64?
    ) -> Bool {
        guard nativeProcessID == 0 || processID(nativeProcessID) != nil,
              eventWindowID >= 0, eventWindowID <= Int64(UInt32.max) else { return false }
        if let windowOwnerProcessID {
            // An owner lookup without a valid global window ID cannot establish identity.
            guard eventWindowID > 0, processID(windowOwnerProcessID) != nil else { return false }
        }
        return true
    }
}
