import Foundation
import XCTest
@testable import MxltUtils

final class InputTapPermissionWatchdogTests: XCTestCase {
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
