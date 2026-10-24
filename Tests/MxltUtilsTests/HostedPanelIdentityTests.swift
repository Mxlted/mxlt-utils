import ApplicationServices
import CallQuitsCore
import XCTest
@testable import MxltUtils

final class HostedPanelIdentityTests: XCTestCase {
    private func identity(native: Int64 = 42, window: Int64 = 100, owner: Int64? = 43,
                          bundle: String? = "com.apple.TextEdit",
                          service: String? = HostedPanelEventIdentity.serviceBundleID,
                          executable: String? = HostedPanelEventIdentity.serviceExecutable) -> HostedPanelEventIdentity? {
        HostedPanelEventIdentity(nativeProcessID: native, eventWindowID: window, windowOwnerProcessID: owner,
                                 ownerBundleIdentifier: bundle, recipientBundleIdentifier: service,
                                 recipientExecutable: executable)
    }

    func testSystemPanelPinsHostServiceAndExactWindowWithoutRelaxingOrdinaryIdentity() throws {
        XCTAssertNil(EventIdentity(nativeProcessID: 42, eventWindowID: 100, windowOwnerProcessID: 43))
        let hosted = try XCTUnwrap(identity())
        XCTAssertEqual(hosted.host.processID, 43)
        XCTAssertEqual(hosted.host.windowID, 100)
        XCTAssertTrue(hosted.matchesRelease(nativeProcessID: 42, eventWindowID: 100, windowOwnerProcessID: 43))
        XCTAssertTrue(hosted.matchesRelease(nativeProcessID: 42, eventWindowID: 100, windowOwnerProcessID: nil))
        for (recipient, window, owner): (Int64, Int64, Int64?) in [
            (0, 100, 43), (43, 100, 43), (44, 100, 43), (42, 0, 43),
            (42, 101, 43), (42, 100, 44), (42, 100, 0)
        ] {
            XCTAssertFalse(hosted.matchesRelease(nativeProcessID: recipient, eventWindowID: window, windowOwnerProcessID: owner))
        }
    }

    func testSystemServiceProofSupportsAnyIdentifiedHostApp() {
        for bundle in ["com.apple.TextEdit", "com.apple.Preview", "com.apple.QuickTimePlayerX", "com.example.editor"] {
            XCTAssertNotNil(identity(bundle: bundle))
            XCTAssertNil(identity(bundle: bundle, service: "com.example.fakeService"))
            XCTAssertNil(identity(bundle: bundle, executable: "/Applications/Fake.app/Contents/MacOS/service"))
        }
    }

    func testUnknownOwnersSpoofedServicesAndInvalidNativeMetadataCannotUseHostedPath() {
        XCTAssertNil(identity(owner: nil))
        XCTAssertNil(identity(owner: 42))
        XCTAssertNil(identity(bundle: nil))
        XCTAssertNil(identity(bundle: ""))
        XCTAssertNil(identity(bundle: " com.apple.Preview"))
        XCTAssertNil(identity(bundle: "invalid bundle"))
        XCTAssertNil(identity(service: "com.example.panel"))
        XCTAssertNil(identity(executable: nil))
        XCTAssertNil(identity(executable: "/Applications/Fake.app/Contents/MacOS/" + HostedPanelEventIdentity.serviceBundleID))
        for pid: Int64 in [-1, 0, 1, Int64(Int32.max) + 1] {
            XCTAssertNil(identity(native: pid))
            XCTAssertNil(identity(owner: pid))
        }
        for window: Int64 in [-1, 0, Int64(UInt32.max) + 1] { XCTAssertNil(identity(window: window)) }
    }
}

final class DialogCloseReadRecoveryTests: XCTestCase {
    private let unreliable = CloseSnapshot(windowCount: 0, targetWindowPresent: true, hasBlockingUI: false, isReliable: false)
    private let empty = CloseSnapshot(windowCount: 0, targetWindowPresent: false, hasBlockingUI: false, isReliable: true)

    func testAtMostTwoCannotCompleteReadsCanBeRetried() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        var recovery = DialogCloseReadRecovery()
        XCTAssertTrue(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertTrue(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertFalse(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        for trigger in [CloseTrigger.windowButton, .tabButton, .middleClickTab, .keyboardShortcut] {
            recovery = DialogCloseReadRecovery()
            XCTAssertFalse(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: trigger, snapshot: unreliable, error: .cannotComplete))
        }
        for error: AXError? in [nil, .failure, .invalidUIElement, .apiDisabled, .attributeUnsupported, .noValue] {
            recovery = DialogCloseReadRecovery()
            XCTAssertFalse(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: error))
        }
    }

    func testUnverifiedPanelCannotRetryOrDiscardItsConfirmationInterval() {
        var recovery = DialogCloseReadRecovery()
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.1), .wait)
        XCTAssertFalse(recovery.prepareRetry(session: &session, verifiedHostedPanel: false,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.3), .quit)
    }

    func testUnavailableReadCannotBridgeEmptyConfirmationOrExtendOriginalDeadline() {
        var recovery = DialogCloseReadRecovery()
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertTrue(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.4), .wait)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.6), .quit)

        recovery = DialogCloseReadRecovery()
        session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertFalse(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: empty, error: nil))
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.1), .wait)
        XCTAssertTrue(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.4), .wait)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.5), .wait)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.6), .quit)

        recovery = DialogCloseReadRecovery()
        session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertTrue(recovery.prepareRetry(session: &session, verifiedHostedPanel: true,
                                             trigger: .dialogCancel, snapshot: unreliable, error: .cannotComplete))
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 3), .cancel(.expired))
    }

    func testDiscardedIntervalPreservesDisappearanceHistoryAndTerminalFailures() {
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.1), .wait)
        session.discardConfirmationInterval()
        let reappeared = CloseSnapshot(windowCount: 1, targetWindowPresent: true, hasBlockingUI: false, isReliable: true)
        XCTAssertEqual(session.evaluate(snapshot: reappeared, now: 0.4), .cancel(.windowSetChanged))
        session.discardConfirmationInterval()
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.6), .cancel(.windowSetChanged))

        session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: empty, now: 0.1), .wait)
        session.discardConfirmationInterval()
        let replacement = CloseSnapshot(windowCount: 1, targetWindowPresent: false, hasBlockingUI: false,
                                        isReliable: true, hasReplacementWindow: true)
        XCTAssertEqual(session.evaluate(snapshot: replacement, now: 0.4), .cancel(.replacementWindow))
    }
}
