// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import Foundation

/// Whether a verified close-button click should quit after the final window or after any window.
public enum CloseBehavior: String, CaseIterable, Codable, Sendable {
    case lastWindow
    case everyWindow
}

/// A narrow compatibility allowance for Discord hiding after a verified normal close gesture.
/// The integration creates this only after matching native mouse-down/up identities and still
/// requires a positive AX close-button hit and a safe, complete window snapshot before quitting.
public struct HiddenCloseIntent: Sendable {
    private let processID: Int32
    private let bundleIdentifier: String
    private let releasedAt: TimeInterval
    private var hiddenAt: TimeInterval?

    public static func supports(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.hnc.Discord"
    }

    public init?(processID: Int32, bundleIdentifier: String?, releasedAt: TimeInterval) {
        guard processID > 1, let bundleIdentifier, Self.supports(bundleIdentifier: bundleIdentifier),
              releasedAt.isFinite, releasedAt >= 0 else { return nil }
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.releasedAt = releasedAt
    }

    /// Only an observed hide of this exact process after release can authorize hidden state.
    /// Repeated notifications never move the original release deadline or first hide timestamp.
    @discardableResult
    public mutating func recordHide(processID: Int32, at now: TimeInterval) -> Bool {
        guard processID == self.processID, isFresh(at: now),
              hiddenAt.map({ now >= $0 }) ?? true else { return false }
        if hiddenAt == nil { hiddenAt = now }
        return true
    }

    public func allowsHiddenState(processID: Int32, bundleIdentifier: String?, at now: TimeInterval) -> Bool {
        guard processID == self.processID, bundleIdentifier == self.bundleIdentifier,
              let hiddenAt, now >= hiddenAt else { return false }
        return isFresh(at: now)
    }

    private func isFresh(at now: TimeInterval) -> Bool {
        now.isFinite && now >= releasedAt && now - releasedAt < CloseSession.maximumDuration
    }
}

/// Routes application visibility changes for the whole lifetime of one native-identified press.
/// Ownership must survive mouse-up while Accessibility capture is still pending. Notifications
/// about another application are unrelated to this attempt, even before its close control is read.
public struct CloseApplicationVisibility: Sendable {
    public enum HideDecision: Equatable, Sendable {
        case unrelated
        case cancel
        case preserveMatchedRelease
    }

    private let processID: Int32
    private let bundleIdentifier: String?
    private var releaseRecorded = false
    private var hiddenCloseIntent: HiddenCloseIntent?

    public init(identity: EventIdentity, bundleIdentifier: String?) {
        processID = identity.processID
        self.bundleIdentifier = bundleIdentifier
    }

    /// Called only after the release matches the original native identity and gesture.
    /// This records visibility evidence; positive AX close-button proof is still mandatory.
    public mutating func recordMatchedRelease(at timestamp: TimeInterval, permitsHiddenClose: Bool) {
        guard !releaseRecorded else { return }
        releaseRecorded = true
        if permitsHiddenClose {
            hiddenCloseIntent = HiddenCloseIntent(processID: processID, bundleIdentifier: bundleIdentifier,
                                                 releasedAt: timestamp)
        }
    }

    public func owns(processID: Int32?) -> Bool {
        processID == self.processID
    }

    /// A retained NSRunningApplication can describe a relaunched process after automatic
    /// termination. A fresh process must never inherit the old press or Accessibility snapshot.
    public func matchesApplication(processID: Int32, bundleIdentifier: String?) -> Bool {
        owns(processID: processID) && bundleIdentifier == self.bundleIdentifier
    }

    public mutating func applicationDidHide(processID: Int32?, at timestamp: TimeInterval) -> HideDecision {
        guard owns(processID: processID) else { return .unrelated }
        if hiddenCloseIntent?.recordHide(processID: self.processID, at: timestamp) == true {
            return .preserveMatchedRelease
        }
        return .cancel
    }

    public func allowsHiddenState(processID: Int32, bundleIdentifier: String?, at timestamp: TimeInterval) -> Bool {
        hiddenCloseIntent?.allowsHiddenState(processID: processID, bundleIdentifier: bundleIdentifier,
                                             at: timestamp) == true
    }
}

/// A complete Accessibility snapshot of an application, including minimized windows and other Spaces.
///
/// The caller must mark partially read snapshots unreliable and compare window identities against
/// the click-time snapshot to detect replacement windows. Visible screen geometry is not a window count.
public struct CloseSnapshot: Sendable {
    public let windowCount: Int
    public let targetWindowPresent: Bool
    public let hasBlockingUI: Bool
    public let isReliable: Bool
    public let hasReplacementWindow: Bool
    public let applicationHidden: Bool
    public let targetWindowMinimized: Bool

    public init(
        windowCount: Int,
        targetWindowPresent: Bool,
        hasBlockingUI: Bool,
        isReliable: Bool,
        hasReplacementWindow: Bool = false,
        applicationHidden: Bool = false,
        targetWindowMinimized: Bool = false
    ) {
        self.windowCount = windowCount
        self.targetWindowPresent = targetWindowPresent
        self.hasBlockingUI = hasBlockingUI
        self.isReliable = isReliable
        self.hasReplacementWindow = hasReplacementWindow
        self.applicationHidden = applicationHidden
        self.targetWindowMinimized = targetWindowMinimized
    }
}

/// What was observed when a verified close attempt could no longer safely request a quit.
/// None of these reasons implies that the user canceled a save dialog.
public enum CloseCancellationReason: Equatable, Sendable {
    case remainingWindows
    case blockingUI
    case replacementWindow
    case unreliableSnapshot
    case windowSetChanged
    case expired
    case invalidTiming
    case alreadyFinished
    case applicationHidden
}

public enum CloseDecision: Equatable, Sendable {
    case wait
    case cancel(CloseCancellationReason)
    case quit
}

/// A short-lived, fail-closed decision session for one positively identified close-button click.
///
/// Create a session only after Accessibility identifies the actual close button. Use a monotonic
/// clock for `startedAt` and `now`. The integration owns cancellation when a new click, preference
/// change, or process change supersedes this session. A `.quit` decision is emitted at most once.
public struct CloseSession: Sendable {
    public static let confirmationInterval: TimeInterval = 0.15
    public static let minimumElapsedTime: TimeInterval = 0.2
    public static let maximumDuration: TimeInterval = 3

    private let behavior: CloseBehavior
    private let allowsApplicationHide: Bool
    private let startedAt: TimeInterval
    private var previousObservationAt: TimeInterval
    private var hasObservedCompletion = false
    private var confirmationStartedAt: TimeInterval?
    private var confirmationWindowCount: Int?
    private var confirmationKind: CompletionKind?
    private var confirmationApplicationHidden: Bool?
    private var finishedReason: CloseCancellationReason?

    private enum CompletionKind: Sendable { case disappeared, hiddenRetainedWindow }

    public init(behavior: CloseBehavior, startedAt: TimeInterval, allowsApplicationHide: Bool = false) {
        self.behavior = behavior
        self.allowsApplicationHide = allowsApplicationHide
        self.startedAt = startedAt
        self.previousObservationAt = startedAt
    }

    /// Discard elapsed confirmation after an integration-approved transient read failure.
    /// Keep disappearance history, original deadline, and terminal decisions intact.
    /// The next reliable matching snapshot starts a fresh complete interval.
    public mutating func discardConfirmationInterval() {
        confirmationStartedAt = nil
    }

    public mutating func evaluate(snapshot: CloseSnapshot, now: TimeInterval) -> CloseDecision {
        if let finishedReason { return .cancel(finishedReason) }

        guard startedAt.isFinite,
              now.isFinite,
              now >= previousObservationAt
        else { return cancel(.invalidTiming) }
        guard now - startedAt < Self.maximumDuration else { return cancel(.expired) }
        guard snapshot.isReliable,
              snapshot.windowCount >= 0,
              !snapshot.targetWindowPresent || snapshot.windowCount > 0
        else { return cancel(.unreliableSnapshot) }
        guard !snapshot.hasBlockingUI else { return cancel(.blockingUI) }
        guard !snapshot.hasReplacementWindow else { return cancel(.replacementWindow) }
        guard !snapshot.applicationHidden || allowsApplicationHide else { return cancel(.applicationHidden) }
        previousObservationAt = now

        let completionKind: CompletionKind
        if snapshot.applicationHidden && snapshot.targetWindowPresent {
            guard snapshot.windowCount == 1 else { return cancel(.remainingWindows) }
            guard !snapshot.targetWindowMinimized else { return cancel(.windowSetChanged) }
            completionKind = .hiddenRetainedWindow
        } else if snapshot.targetWindowPresent {
            // A window that reappears may represent a canceled close or reused AX identity.
            guard !hasObservedCompletion else { return cancel(.windowSetChanged) }
            return .wait
        } else {
            completionKind = .disappeared
        }

        if completionKind == .disappeared && behavior == .lastWindow && snapshot.windowCount != 0 {
            return cancel(.remainingWindows)
        }

        guard hasObservedCompletion else {
            hasObservedCompletion = true
            confirmationStartedAt = now
            confirmationWindowCount = snapshot.windowCount
            confirmationKind = completionKind
            confirmationApplicationHidden = snapshot.applicationHidden
            return .wait
        }

        guard snapshot.windowCount == confirmationWindowCount,
              completionKind == confirmationKind,
              snapshot.applicationHidden == confirmationApplicationHidden else {
            return cancel(.windowSetChanged)
        }

        guard let confirmedAt = confirmationStartedAt else {
            confirmationStartedAt = now
            return .wait
        }
        guard now - confirmedAt >= Self.confirmationInterval,
              now - startedAt >= Self.minimumElapsedTime
        else {
            return .wait
        }
        finishedReason = .alreadyFinished
        return .quit
    }

    private mutating func cancel(_ reason: CloseCancellationReason) -> CloseDecision {
        finishedReason = reason
        return .cancel(reason)
    }
}
