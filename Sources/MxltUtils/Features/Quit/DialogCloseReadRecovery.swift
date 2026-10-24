import ApplicationServices
import CallQuitsCore

/// TextEdit can briefly refuse AXWindows while its hosted chooser dismisses. Permit
/// at most two fresh reads, never an inferred empty window list. Every accepted retry
/// discards elapsed confirmation so it cannot bridge empty confirmation samples.
struct DialogCloseReadRecovery {
    private var remainingAttempts = 2

    mutating func prepareRetry(session: inout CloseSession, bundleIdentifier: String?,
                               trigger: CloseTrigger, snapshot: CloseSnapshot, error: AXError?) -> Bool {
        guard bundleIdentifier == "com.apple.TextEdit", remainingAttempts > 0,
              trigger == .dialogCancel, !snapshot.isReliable, error == .cannotComplete else { return false }
        remainingAttempts -= 1
        session.discardConfirmationInterval()
        return true
    }
}
