// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import XCTest
@testable import CallQuitsCore

final class CloseSessionTests: XCTestCase {
    private func snapshot(
        _ count: Int = 0,
        target: Bool = false,
        blocking: Bool = false,
        reliable: Bool = true,
        replacement: Bool = false,
        hidden: Bool = false,
        minimized: Bool = false
    ) -> CloseSnapshot {
        CloseSnapshot(
            windowCount: count,
            targetWindowPresent: target,
            hasBlockingUI: blocking,
            isReliable: reliable,
            hasReplacementWindow: replacement,
            applicationHidden: hidden,
            targetWindowMinimized: minimized
        )
    }

    func testFinalWindowRequiresDisappearanceAndStableConfirmation() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 0.05), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.1), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.2), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.26), .quit)
    }

    func testImmediateCloseStillNeedsMinimumElapsedTime() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.16), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.2), .quit)
    }

    func testOneLateSnapshotNeverQuitsByItself() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 2.8), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 2.96), .quit)
    }

    func testRepeatedSnapshotAtSameTimeDoesNotConfirm() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.5), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.5), .wait)
    }

    func testUnclosedOrCanceledWindowExpiresWithoutQuit() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        for time in [0.1, 0.5, 1, 2.99] {
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: time), .wait,
                           "target still present, elapsed=\(time)")
        }
        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 3), .cancel(.expired))
    }

    func testExpirationWinsEvenWhenConfirmationWouldOtherwiseSucceed() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 10)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 12.8), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 13), .cancel(.expired))
    }

    func testOtherWindowsPreventLastWindowQuitRegardlessOfVisibility() {
        // The AX adapter supplies all windows, including minimized windows and other Spaces.
        for remainingCount in [1, 2, 10] {
            let context = "last-window mode, remaining windows=\(remainingCount)"
            var session = CloseSession(behavior: .lastWindow, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(remainingCount + 1, target: true), now: 0.1), .wait, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(remainingCount), now: 0.2), .cancel(.remainingWindows), context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.5), .cancel(.remainingWindows), context)
        }
    }

    func testEveryWindowAllowsStableExistingWindowsAfterTheTargetCloses() {
        for remainingCount in [0, 1, 5] {
            let context = "every-window mode, remaining windows=\(remainingCount)"
            var session = CloseSession(behavior: .everyWindow, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(remainingCount + 1, target: true), now: 0.1), .wait, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(remainingCount), now: 0.2), .wait, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(remainingCount), now: 0.36), .quit, context)
        }
    }

    func testEveryWindowStillRequiresTargetToClose() {
        var session = CloseSession(behavior: .everyWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(3, target: true), now: 0.5), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(3, target: true), now: 2), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(3, target: true), now: 3), .cancel(.expired))
    }

    func testUnreadableBlockingAndInconsistentSnapshotsFailClosed() {
        let cases: [(name: String, snapshot: CloseSnapshot, reason: CloseCancellationReason)] = [
            ("unreadable snapshot", snapshot(reliable: false), .unreliableSnapshot),
            ("observed blocking UI", snapshot(blocking: true), .blockingUI),
            ("negative window count", snapshot(-1), .unreliableSnapshot),
            ("present target with zero windows", snapshot(0, target: true), .unreliableSnapshot),
            ("observed replacement", snapshot(replacement: true), .replacementWindow)
        ]
        for behavior in CloseBehavior.allCases {
            for testCase in cases {
                for afterDisappearance in [false, true] {
                    let context = "\(testCase.name), behavior=\(behavior), after disappearance=\(afterDisappearance)"
                    var session = CloseSession(behavior: behavior, startedAt: 0)
                    if afterDisappearance {
                        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.1), .wait, context)
                    }
                    XCTAssertEqual(session.evaluate(snapshot: testCase.snapshot, now: 0.3), .cancel(testCase.reason), context)
                    XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.5), .cancel(testCase.reason),
                                   "\(context), cancellation must remain final")
                }
            }
        }
    }

    func testSaveSheetCancelsWhileTargetStillExists() {
        for behavior in CloseBehavior.allCases {
            let context = "save sheet with target present, behavior=\(behavior)"
            var session = CloseSession(behavior: behavior, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, blocking: true), now: 0.1),
                           .cancel(.blockingUI), context)
            // Dismissing a sheet later must not revive a pending quit.
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 1), .cancel(.blockingUI), context)
        }
    }

    func testReplacementWindowAndReappearingTargetCancel() {
        let cases: [(name: String, snapshot: CloseSnapshot, lastWindowReason: CloseCancellationReason)] = [
            ("window count increases", snapshot(1), .remainingWindows),
            ("target reappears", snapshot(1, target: true), .windowSetChanged)
        ]
        for behavior in CloseBehavior.allCases {
            for testCase in cases {
                let context = "\(testCase.name), behavior=\(behavior)"
                let reason: CloseCancellationReason = behavior == .lastWindow ? testCase.lastWindowReason : .windowSetChanged
                var session = CloseSession(behavior: behavior, startedAt: 0)
                XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.1), .wait, context)
                XCTAssertEqual(session.evaluate(snapshot: testCase.snapshot, now: 0.3), .cancel(reason), context)
            }
        }
    }

    func testEveryWindowDetectsIdentityReplacementEvenWithUnchangedCount() {
        var session = CloseSession(behavior: .everyWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(2), now: 0.1), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(2, replacement: true), now: 0.3), .cancel(.replacementWindow))
    }

    func testEveryWindowCancelsWhenRemainingWindowCountChanges() {
        for changedCount in [1, 3] {
            let context = "every-window mode, remaining count changes from 2 to \(changedCount)"
            var session = CloseSession(behavior: .everyWindow, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(2), now: 0.1), .wait, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(changedCount), now: 0.3), .cancel(.windowSetChanged), context)
        }
    }

    func testQuitIsEmittedAtMostOnce() {
        for behavior in CloseBehavior.allCases {
            let context = "behavior=\(behavior)"
            var session = CloseSession(behavior: behavior, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.1), .wait, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.3), .quit, context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.5), .cancel(.alreadyFinished), context)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.7), .cancel(.alreadyFinished), context)
        }
    }

    func testInvalidAndReversedClockValuesCancel() {
        for invalidStart in [Double.nan, Double.infinity, -Double.infinity] {
            var session = CloseSession(behavior: .lastWindow, startedAt: invalidStart)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 1), .cancel(.invalidTiming), "start=\(invalidStart)")
        }
        for invalidNow in [Double.nan, Double.infinity, -Double.infinity, -1] {
            var session = CloseSession(behavior: .lastWindow, startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: invalidNow), .cancel(.invalidTiming), "now=\(invalidNow)")
        }
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.4), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.3), .cancel(.invalidTiming))
    }

    func testUnreliableSnapshotDoesNotClaimAnObservedDialogOrReplacement() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(blocking: true, reliable: false, replacement: true), now: 0.1),
                       .cancel(.unreliableSnapshot))
    }

    func testCancellationKeepsItsOriginalReasonAfterExpiry() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(blocking: true), now: 0.1), .cancel(.blockingUI))
        XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 4), .cancel(.blockingUI))
    }

    func testAuthorizedHiddenRetainedWindowRequiresStableConfirmation() {
        for behavior in CloseBehavior.allCases {
            var session = CloseSession(behavior: behavior, startedAt: 0, allowsApplicationHide: true)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 0.02), .wait)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.05), .wait)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.19), .wait)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.21), .quit)
            XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.4), .cancel(.alreadyFinished))
        }
    }

    func testHiddenCloseStillRequiresMinimumElapsedTimeAndExpires() {
        let hiddenWindow = snapshot(1, target: true, hidden: true)
        var immediate = CloseSession(behavior: .lastWindow, startedAt: 0, allowsApplicationHide: true)
        XCTAssertEqual(immediate.evaluate(snapshot: hiddenWindow, now: 0), .wait)
        XCTAssertEqual(immediate.evaluate(snapshot: hiddenWindow, now: 0.16), .wait)
        XCTAssertEqual(immediate.evaluate(snapshot: hiddenWindow, now: 0.2), .quit)

        var late = CloseSession(behavior: .lastWindow, startedAt: 0, allowsApplicationHide: true)
        XCTAssertEqual(late.evaluate(snapshot: hiddenWindow, now: 2.9), .wait)
        XCTAssertEqual(late.evaluate(snapshot: hiddenWindow, now: 3), .cancel(.expired))
    }

    func testAuthorizedHiddenAppCanConfirmAnActuallyClosedLastWindow() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0, allowsApplicationHide: true)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(hidden: true), now: 0.1), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(hidden: true), now: 0.2), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(hidden: true), now: 0.3), .quit)
    }

    func testHiddenStateWithoutVerifiedAllowanceCancelsEvenWithNoWindows() {
        for behavior in CloseBehavior.allCases {
            for current in [snapshot(hidden: true), snapshot(1, target: true, hidden: true)] {
                var session = CloseSession(behavior: behavior, startedAt: 0)
                XCTAssertEqual(session.evaluate(snapshot: current, now: 0.1), .cancel(.applicationHidden))
                XCTAssertEqual(session.evaluate(snapshot: snapshot(), now: 0.4), .cancel(.applicationHidden))
            }
        }
    }

    func testHiddenAllowanceDoesNotBypassWindowSafety() {
        let cases: [(CloseSnapshot, CloseCancellationReason)] = [
            (snapshot(1, target: true, reliable: false, hidden: true), .unreliableSnapshot),
            (snapshot(1, target: true, blocking: true, hidden: true), .blockingUI),
            (snapshot(1, target: true, replacement: true, hidden: true), .replacementWindow),
            (snapshot(1, target: true, hidden: true, minimized: true), .windowSetChanged),
            (snapshot(2, target: true, hidden: true), .remainingWindows),
            (snapshot(0, target: true, hidden: true), .unreliableSnapshot)
        ]
        for behavior in CloseBehavior.allCases {
            for (current, reason) in cases {
                for afterConfirmationStarts in [false, true] {
                    var session = CloseSession(behavior: behavior, startedAt: 0, allowsApplicationHide: true)
                    if afterConfirmationStarts {
                        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.1), .wait)
                    }
                    XCTAssertEqual(session.evaluate(snapshot: current, now: 0.3), .cancel(reason))
                    XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true, hidden: true), now: 0.5), .cancel(reason))
                }
            }
        }
    }

    func testHiddenConfirmationCancelsOnUnhideOrChangedCompletionKind() {
        let hiddenRetained = snapshot(1, target: true, hidden: true)
        let hiddenDisappeared = snapshot(hidden: true)
        let cases: [(CloseSnapshot, CloseSnapshot)] = [
            (hiddenRetained, snapshot(1, target: true)),
            (hiddenDisappeared, snapshot()),
            (hiddenRetained, hiddenDisappeared),
            (hiddenDisappeared, hiddenRetained),
            (snapshot(), hiddenDisappeared)
        ]
        for behavior in CloseBehavior.allCases {
            for (initial, changed) in cases {
                var session = CloseSession(behavior: behavior, startedAt: 0, allowsApplicationHide: true)
                XCTAssertEqual(session.evaluate(snapshot: initial, now: 0.1), .wait)
                XCTAssertEqual(session.evaluate(snapshot: changed, now: 0.3), .cancel(.windowSetChanged))
            }
        }
    }

    func testHiddenAllowanceStillRequiresVisibleTargetToDisappear() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0, allowsApplicationHide: true)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 0.2), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 2.9), .wait)
        XCTAssertEqual(session.evaluate(snapshot: snapshot(1, target: true), now: 3), .cancel(.expired))
    }

    func testHiddenIntentRequiresSupportedIdentityAndValidReleaseTime() {
        for bundle in [nil, "", "example.fixture", "com.apple.finder", "com.hnc.DiscordCanary", "COM.HNC.DISCORD"] {
            XCTAssertNil(HiddenCloseIntent(processID: 42, bundleIdentifier: bundle, releasedAt: 10))
        }
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertNil(HiddenCloseIntent(processID: pid, bundleIdentifier: "com.hnc.Discord", releasedAt: 10))
        }
        for release in [Double.nan, Double.infinity, -Double.infinity, -1] {
            XCTAssertNil(HiddenCloseIntent(processID: 42, bundleIdentifier: "com.hnc.Discord", releasedAt: release))
        }
    }

    func testHiddenIntentNeedsMatchingObservedTransitionAndFreshExactIdentity() throws {
        var intent = try XCTUnwrap(HiddenCloseIntent(processID: 42, bundleIdentifier: "com.hnc.Discord", releasedAt: 10))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.1))
        XCTAssertFalse(intent.recordHide(processID: 43, at: 10.1))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.2))
        XCTAssertTrue(intent.recordHide(processID: 42, at: 10.2))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.1))
        XCTAssertTrue(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.2))
        XCTAssertFalse(intent.allowsHiddenState(processID: 43, bundleIdentifier: "com.hnc.Discord", at: 10.3))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "example.fixture", at: 10.3))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: nil, at: 10.3))
        XCTAssertTrue(intent.recordHide(processID: 42, at: 12.9))
        XCTAssertTrue(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 12.99))
        XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 13))
        XCTAssertFalse(intent.recordHide(processID: 42, at: 13))
    }

    func testHiddenIntentRejectsInvalidOrPreReleaseTransitions() throws {
        for time in [Double.nan, Double.infinity, -Double.infinity, 9.99, 13] {
            var intent = try XCTUnwrap(HiddenCloseIntent(processID: 42, bundleIdentifier: "com.hnc.Discord", releasedAt: 10))
            XCTAssertFalse(intent.recordHide(processID: 42, at: time))
            XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.5))
        }
        var intent = try XCTUnwrap(HiddenCloseIntent(processID: 42, bundleIdentifier: "com.hnc.Discord", releasedAt: 10))
        XCTAssertTrue(intent.recordHide(processID: 42, at: 10.2))
        XCTAssertFalse(intent.recordHide(processID: 42, at: 10.1))
        for time in [Double.nan, Double.infinity, -Double.infinity, 9.99] {
            XCTAssertFalse(intent.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: time))
        }
    }

    private func visibility(_ bundle: String = "example.fixture") -> CloseApplicationVisibility {
        let identity = EventIdentity(nativeProcessID: 42, eventWindowID: 100, windowOwnerProcessID: 42)!
        return CloseApplicationVisibility(identity: identity, bundleIdentifier: bundle)
    }

    func testUnrelatedHidesCannotCancelThePressOrPendingRelease() {
        for bundle in ["example.fixture", "com.hnc.Discord"] {
            for released in [false, true] {
                var attempt = visibility(bundle)
                if released { attempt.recordMatchedRelease(at: 10, permitsHiddenClose: true) }
                for unrelatedPID: Int32? in [nil, 0, 1, 43] {
                    XCTAssertEqual(attempt.applicationDidHide(processID: unrelatedPID, at: 10.1), .unrelated,
                                   "bundle=\(bundle), released=\(released), notification PID=\(String(describing: unrelatedPID))")
                }
                XCTAssertFalse(attempt.allowsHiddenState(processID: 42, bundleIdentifier: bundle, at: 10.2),
                               "another app's transition cannot authorize hidden state")
                XCTAssertEqual(attempt.applicationDidHide(processID: 42, at: 10.2),
                               bundle == "com.hnc.Discord" && released ? .preserveMatchedRelease : .cancel)
            }
        }
    }

    func testTargetHideStillCancelsUnreleasedUnsupportedAndForceAttempts() {
        var beforeRelease = visibility("com.hnc.Discord")
        XCTAssertEqual(beforeRelease.applicationDidHide(processID: 42, at: 10.1), .cancel)
        var ordinary = visibility()
        ordinary.recordMatchedRelease(at: 10, permitsHiddenClose: true)
        XCTAssertEqual(ordinary.applicationDidHide(processID: 42, at: 10.1), .cancel)
        var force = visibility("com.hnc.Discord")
        force.recordMatchedRelease(at: 10, permitsHiddenClose: false)
        XCTAssertEqual(force.applicationDidHide(processID: 42, at: 10.1), .cancel)
        XCTAssertFalse(force.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 10.2))
    }

    func testVisibilityEvidenceRetainsOriginalDeadlineAndExactApplicationIdentity() {
        var attempt = visibility("com.hnc.Discord")
        attempt.recordMatchedRelease(at: 10, permitsHiddenClose: true)
        XCTAssertEqual(attempt.applicationDidHide(processID: 42, at: 10.1), .preserveMatchedRelease)
        attempt.recordMatchedRelease(at: 12, permitsHiddenClose: true)
        XCTAssertEqual(attempt.applicationDidHide(processID: 43, at: 12.8), .unrelated)
        XCTAssertTrue(attempt.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 12.9))
        XCTAssertEqual(attempt.applicationDidHide(processID: 42, at: 13), .cancel)
        XCTAssertFalse(attempt.allowsHiddenState(processID: 42, bundleIdentifier: "com.hnc.Discord", at: 13))

        XCTAssertTrue(attempt.matchesApplication(processID: 42, bundleIdentifier: "com.hnc.Discord"))
        XCTAssertFalse(attempt.matchesApplication(processID: 43, bundleIdentifier: "com.hnc.Discord"),
                       "a relaunched process must not inherit the old click or snapshot")
        XCTAssertFalse(attempt.matchesApplication(processID: 42, bundleIdentifier: "example.fixture"),
                       "a different application reusing a PID must not inherit the old click")
        XCTAssertFalse(attempt.matchesApplication(processID: 42, bundleIdentifier: nil))
    }
}
