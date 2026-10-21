// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import XCTest
@testable import CallQuitsCore

final class EventIdentityTests: XCTestCase {
    private func identity(native: Int64 = 42, window: Int64 = 100, owner: Int64? = 42) -> EventIdentity? {
        EventIdentity(nativeProcessID: native, eventWindowID: window, windowOwnerProcessID: owner)
    }

    private func matches(
        _ identity: EventIdentity,
        native: Int64 = 42,
        window: Int64 = 100,
        owner: Int64? = 42
    ) -> Bool {
        identity.matchesRelease(nativeProcessID: native, eventWindowID: window, windowOwnerProcessID: owner)
    }

    func testNativeRecipientCanEstablishIdentityWithoutWindowMetadata() {
        let resolved = identity(window: 0, owner: nil)
        XCTAssertEqual(resolved?.processID, 42)
        XCTAssertNil(resolved?.windowID)
        XCTAssertTrue(matches(resolved!, window: 0, owner: nil))
    }

    func testExactWindowOwnerResolvesMissingNativeRecipient() {
        let resolved = identity(native: 0)
        XCTAssertEqual(resolved?.processID, 42)
        XCTAssertEqual(resolved?.windowID, 100)
        XCTAssertTrue(matches(resolved!, native: 0))
    }

    func testUnidentifiedPressNeverStarts() {
        XCTAssertNil(identity(native: 0, window: 0, owner: nil))
        XCTAssertNil(identity(native: 0, owner: nil))
        XCTAssertNil(identity(native: 0, window: 0, owner: 42))
    }

    func testConflictingNativeAndWindowRecipientsNeverStart() {
        XCTAssertNil(identity(native: 42, owner: 43))
        XCTAssertNil(identity(native: 43, owner: 42))
        XCTAssertNil(identity(window: 0, owner: 42))
    }

    func testReleaseCanKeepOriginalIdentityAfterNativeCloseRemovesWindowEntry() {
        let resolved = identity(native: 0)!
        XCTAssertTrue(matches(resolved, native: 0, owner: nil))
        XCTAssertTrue(matches(resolved, native: 42, owner: nil))
        XCTAssertTrue(matches(resolved, native: 42, window: 0, owner: nil))
    }

    func testReleaseCannotTransferToUnderlyingWindowOrApplication() {
        let resolved = identity()!
        XCTAssertFalse(matches(resolved, native: 43, owner: nil))
        XCTAssertFalse(matches(resolved, native: 42, window: 101, owner: 42))
        XCTAssertFalse(matches(resolved, native: 0, window: 101, owner: nil))
        XCTAssertFalse(matches(resolved, native: 0, window: 101, owner: 42))
        XCTAssertFalse(matches(resolved, native: 0, owner: 43))
        XCTAssertFalse(matches(resolved, native: 42, owner: 43))
    }

    func testReleaseWithoutAnyRecipientEvidenceIsRejected() {
        XCTAssertFalse(matches(identity()!, native: 0, window: 0, owner: nil))
        // A previously unidentified window cannot establish a mouse-up fallback.
        XCTAssertFalse(matches(identity(window: 0, owner: nil)!, native: 0))
    }

    func testKnownMatchingNativeRecipientCanSupplyPreviouslyMissingWindowMetadata() {
        XCTAssertTrue(matches(identity(window: 0, owner: nil)!))
    }

    func testInvalidProcessIdentifiersFailClosed() {
        let resolved = identity()!
        for invalid in [Int64.min, -1, 1, Int64(Int32.max) + 1, Int64.max] {
            XCTAssertNil(identity(native: invalid), "press native PID=\(invalid)")
            XCTAssertNil(identity(owner: invalid), "press window owner PID=\(invalid)")
            XCTAssertFalse(matches(resolved, native: invalid), "release native PID=\(invalid)")
            XCTAssertFalse(matches(resolved, owner: invalid), "release window owner PID=\(invalid)")
        }
        // Absent owner metadata is nil; a supplied zero is an invalid lookup result.
        XCTAssertNil(identity(owner: 0))
        XCTAssertFalse(matches(resolved, owner: 0))
    }

    func testInvalidGlobalWindowIdentifiersFailClosed() {
        let resolved = identity()!
        for invalid in [Int64.min, -1, Int64(UInt32.max) + 1, Int64.max] {
            XCTAssertNil(identity(window: invalid), "press window ID=\(invalid)")
            XCTAssertFalse(matches(resolved, window: invalid), "release window ID=\(invalid)")
        }
    }

    func testLargestRepresentableIdentitiesAreHandledWithoutTruncation() {
        let resolved = identity(native: Int64(Int32.max), window: Int64(UInt32.max), owner: Int64(Int32.max))!
        XCTAssertEqual(resolved.processID, Int32.max)
        XCTAssertEqual(resolved.windowID, UInt32.max)
        XCTAssertTrue(matches(resolved, native: Int64(Int32.max), window: Int64(UInt32.max), owner: nil))
    }
}
