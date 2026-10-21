import Foundation
import XCTest
@testable import MxltUtils

final class InputTapPermissionWatchdogTests: XCTestCase {
    func testDeletedAccessibilityRowOverridesStaleTrustAndRequiresFreshWatcher() {
        var canFilter = true
        var actions: [String] = []
        let readPermission = {
            InputTapPermissionProbe.check(readTrust: { true }, verifyFiltering: { canFilter })
        }
        let watchdog = InputTapPermissionWatchdog(readPermission: readPermission,
                                                  detach: { actions.append("detach") },
                                                  onRevoked: { actions.append("notify") })
        watchdog.checkPermission()
        XCTAssertTrue(watchdog.allowsInput)
        // Deleting the enabled row can leave AX trust true while creation is denied.
        canFilter = false
        watchdog.checkPermission()
        XCTAssertFalse(watchdog.allowsInput)
        XCTAssertTrue(watchdog.wasRevoked)
        XCTAssertEqual(actions, ["detach", "notify"])
        canFilter = true
        watchdog.checkPermission()
        XCTAssertFalse(watchdog.performIfAllowed { XCTFail("No old gesture or tap may resume"); return true })
        let replacement = InputTapPermissionWatchdog(readPermission: readPermission, detach: {}, onRevoked: {})
        replacement.checkPermission()
        XCTAssertTrue(replacement.allowsInput)
    }

    func testDeniedTrustDoesNotCreateProbeAndTrustAloneCannotGrantAccess() {
        XCTAssertFalse(InputTapPermissionProbe.check(readTrust: { false }, verifyFiltering: {
            XCTFail("Do not attempt a filtering tap when Accessibility is already denied")
            return true
        }))
        XCTAssertFalse(InputTapPermissionProbe.check(readTrust: { true }, verifyFiltering: { false }))
        XCTAssertTrue(InputTapPermissionProbe.check(readTrust: { true }, verifyFiltering: { true }))
    }

    func testTimeoutRecoveryProbesOffCallbackAndRejectsStaleTrust() {
        let complete = DispatchSemaphore(value: 0)
        var actions: [String] = []
        let watchdog = InputTapPermissionWatchdog(readPermission: {
            XCTAssertFalse(Thread.isMainThread)
            return InputTapPermissionProbe.check(readTrust: { true }, verifyFiltering: { false })
        }, detach: { actions.append("detach") }, onRevoked: { actions.append("notify") })
        watchdog.checkBeforeRecovery { allowed in
            XCTAssertFalse(allowed)
            XCTAssertFalse(watchdog.performIfAllowed { XCTFail("No re-enable after failed probe"); return true })
            actions.append("recovery rejected")
            complete.signal()
        }
        XCTAssertEqual(complete.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(actions, ["detach", "notify", "recovery rejected"])
    }

    func testSuccessfulRecoveryProbeCannotReviveTapStoppedDuringQuery() {
        let entered = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let complete = DispatchSemaphore(value: 0)
        let watchdog = InputTapPermissionWatchdog(readPermission: {
            entered.signal()
            _ = finishRead.wait(timeout: .now() + 2)
            return true
        }, detach: {}, onRevoked: { XCTFail("Explicit stop is not revocation") })
        watchdog.checkBeforeRecovery { allowed in
            XCTAssertFalse(allowed)
            complete.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        watchdog.invalidate()
        finishRead.signal()
        XCTAssertEqual(complete.wait(timeout: .now() + 2), .success)
    }

    func testRevocationDetachesBeforeNotificationAndCannotResumeOnRegrant() {
        var granted = true
        var actions: [String] = []
        let watchdog = InputTapPermissionWatchdog(readPermission: { granted },
                                                  detach: { actions.append("detach") },
                                                  onRevoked: { actions.append("notify") })
        watchdog.checkPermission()
        XCTAssertTrue(watchdog.allowsInput)
        XCTAssertTrue(actions.isEmpty)
        granted = false
        watchdog.checkPermission()
        XCTAssertFalse(watchdog.allowsInput)
        XCTAssertTrue(watchdog.wasRevoked, "In-flight callbacks must pass input through after revocation")
        XCTAssertEqual(actions, ["detach", "notify"])
        granted = true
        watchdog.checkPermission()
        XCTAssertFalse(watchdog.performIfAllowed { XCTFail("Revoked tap must not be re-enabled or post events"); return true })
        watchdog.invalidate()
        XCTAssertEqual(actions, ["detach", "notify"], "No duplicate cleanup or failure notification")
    }

    func testExplicitStopDoesNotReportPermissionFailure() {
        var detachCount = 0
        let watchdog = InputTapPermissionWatchdog(readPermission: { false },
                                                  detach: { detachCount += 1 },
                                                  onRevoked: { XCTFail("Explicit stop is not a failure") })
        XCTAssertTrue(watchdog.invalidate())
        XCTAssertFalse(watchdog.invalidate())
        watchdog.checkPermission()
        watchdog.start()
        XCTAssertFalse(watchdog.allowsInput)
        XCTAssertFalse(watchdog.wasRevoked, "Normal cleanup may still consume the matching captured release")
        XCTAssertEqual(detachCount, 1)
    }

    @MainActor
    func testBackgroundWatchdogDetachesWhileMainThreadIsUnavailable() async {
        let detached = DispatchSemaphore(value: 0)
        let watchdog = InputTapPermissionWatchdog(readPermission: {
            XCTAssertFalse(Thread.isMainThread)
            return false
        }, detach: {
            XCTAssertFalse(Thread.isMainThread)
            detached.signal()
        }, onRevoked: {})
        watchdog.start()
        // Deliberately do not service the main run loop. No real tap or input is used.
        XCTAssertEqual(detached.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(watchdog.allowsInput)
    }

    func testSlowPermissionResultCannotAffectReplacementWatchdog() {
        let entered = DispatchSemaphore(value: 0)
        let finishRead = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let old = InputTapPermissionWatchdog(readPermission: {
            entered.signal()
            _ = finishRead.wait(timeout: .now() + 2)
            return false
        }, detach: {}, onRevoked: { XCTFail("An old stopped watcher must not report revocation") })
        DispatchQueue.global().async { old.checkPermission(); finished.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        old.invalidate()
        let replacement = InputTapPermissionWatchdog(readPermission: { true }, detach: {}, onRevoked: {})
        finishRead.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(old.allowsInput)
        replacement.checkPermission()
        XCTAssertTrue(replacement.performIfAllowed { true })
    }

    func testDroppingWatchdogDetachesItsTap() {
        var detachCount = 0
        var watchdog: InputTapPermissionWatchdog? = InputTapPermissionWatchdog(
            readPermission: { true }, detach: { detachCount += 1 }, onRevoked: {})
        XCTAssertNotNil(watchdog)
        watchdog = nil
        XCTAssertEqual(detachCount, 1)
    }

    func testWatchdogDetachmentWaitsForPostingPairAndRejectsLaterWork() {
        let downSent = DispatchSemaphore(value: 0)
        let finishPair = DispatchSemaphore(value: 0)
        let permissionRead = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        // Gate closure waits for posting before detaching; read after both jobs finish.
        var events: [String] = []
        let watchdog = InputTapPermissionWatchdog(readPermission: {
            permissionRead.signal()
            return false
        }, detach: { events.append("detached") }, onRevoked: {})
        completed.enter()
        DispatchQueue.global().async {
            watchdog.performIfAllowed {
                events.append("down")
                downSent.signal()
                _ = finishPair.wait(timeout: .now() + 2)
                events.append("up")
                return true
            }
            completed.leave()
        }
        XCTAssertEqual(downSent.wait(timeout: .now() + 2), .success)
        completed.enter()
        DispatchQueue.global().async { watchdog.checkPermission(); completed.leave() }
        // checkPermission first takes the gate lock, so it may wait for the pair before reading.
        finishPair.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(permissionRead.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(events, ["down", "up", "detached"])
        XCTAssertFalse(watchdog.performIfAllowed { XCTFail("No late replay after detach"); return true })
    }
}
