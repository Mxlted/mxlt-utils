import ApplicationServices

/// AXIsProcessTrusted can remain true after an enabled Accessibility row is deleted.
/// Confirm that a new filtering tap is actually allowed before trusting that result.
enum InputTapPermissionProbe {
    // A mouse-only mask can survive permission stripping. With only keyDown, an
    // unauthorized mask becomes empty and tapCreate must fail (Apple's contract).
    static let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue

    static func check(readTrust: () -> Bool = { AXIsProcessTrusted() },
                      verifyFiltering: () -> Bool = canCreateFilteringTap) -> Bool {
        readTrust() && verifyFiltering()
    }

    private static func canCreateFilteringTap() -> Bool {
        guard let probe = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                                           place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: eventMask,
                                           callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                           userInfo: nil) else { return false }
        // Never install a run-loop source or examine/post input. Creation is the
        // capability check; immediately disable and invalidate its temporary port.
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }
}
