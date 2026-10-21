import XCTest
@testable import MxltCore

final class SessionSuspensionTests: XCTestCase {
    func testWakingLockedDisplayDoesNotResumeInactiveSession() {
        var state = SessionSuspension()
        state.set(.inactiveSession, suspended: true)
        state.set(.displaySleep, suspended: true)
        state.set(.displaySleep, suspended: false)
        XCTAssertTrue(state.isSuspended)
        state.set(.inactiveSession, suspended: false)
        XCTAssertFalse(state.isSuspended)
    }

    func testAllIndependentReasonsMustClearBeforeResuming() {
        var state = SessionSuspension()
        state.set(.systemSleep, suspended: true)
        state.set(.displaySleep, suspended: true)
        state.set(.inactiveSession, suspended: true)
        state.set(.systemSleep, suspended: false)
        XCTAssertTrue(state.isSuspended)
        state.set(.inactiveSession, suspended: false)
        XCTAssertTrue(state.isSuspended)
        state.set(.displaySleep, suspended: false)
        XCTAssertFalse(state.isSuspended)
    }

    func testRepeatedAndUnmatchedNotificationsAreIdempotent() {
        var state = SessionSuspension()
        state.set(.systemSleep, suspended: false)
        XCTAssertFalse(state.isSuspended)
        state.set(.inactiveSession, suspended: true)
        state.set(.inactiveSession, suspended: true)
        state.set(.displaySleep, suspended: false)
        XCTAssertTrue(state.isSuspended)
        state.set(.inactiveSession, suspended: false)
        XCTAssertFalse(state.isSuspended)
    }
}
