import ApplicationServices
import CallQuitsCore

/// TextEdit can briefly refuse AXWindows while its hosted chooser dismisses. Permit
/// at most two fresh reads, never an inferred empty window list. The caller must discard the
/// preceding confirmation interval so a retry cannot bridge empty confirmation samples.
struct DialogCloseReadRecovery {
    private var remainingAttempts = 2

    mutating func shouldRetry(trigger: CloseTrigger, snapshot: CloseSnapshot, error: AXError?) -> Bool {
        guard remainingAttempts > 0, trigger == .dialogCancel, !snapshot.isReliable, error == .cannotComplete else { return false }
        remainingAttempts -= 1
        return true
    }
}
