// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import AppKit
import ServiceManagement
import XCTest
@testable import MxltUtils

final class QuitModelTests: XCTestCase {
    @MainActor
    private func makeModel(
        readAccessibility: @escaping () -> Bool = { true },
        readLoginStatus: @escaping () -> SMAppService.Status = { .notRegistered }
    ) -> QuitModel {
        let suite = "MxltUtilsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = QuitModel(defaults: defaults, readAccessibility: readAccessibility, readLoginStatus: readLoginStatus)
        model.enabled = true
        return model
    }

    @MainActor
    func testLoginRefreshReplacesApprovalAndErrorMessagesForEveryStatus() async {
        var status: SMAppService.Status = .requiresApproval
        let model = makeModel(readLoginStatus: { status })
        XCTAssertTrue(model.launchAtLogin, "approval keeps the requested login setting enabled")
        XCTAssertNotNil(model.loginMessage, "approval instructions at initialization")

        let cases: [(name: String, status: SMAppService.Status, enabled: Bool, message: String?)] = [
            ("enabled", .enabled, true, nil),
            ("not registered", .notRegistered, false, nil),
            ("not found", .notFound, false, "couldn’t find"),
            ("unknown", SMAppService.Status(rawValue: 999)!, false, "unavailable"),
            ("requires approval", .requiresApproval, true, "Approve")
        ]
        for item in cases {
            model.loginMessage = "stale approval or operation error"
            status = item.status
            model.refreshLoginStatus()
            XCTAssertEqual(model.launchAtLogin, item.enabled, "status=\(item.name)")
            if let message = item.message {
                XCTAssertTrue(model.loginMessage?.contains(message) == true, "status=\(item.name)")
            } else {
                XCTAssertNil(model.loginMessage, "status=\(item.name) must clear stale messages")
            }
        }
    }

    @MainActor
    func testPermissionPollingRecordsOnlyTransitionsAndDoesNotReadLoginStatus() async {
        var granted = false
        var loginReads = 0
        var configurationChanges = 0
        let model = makeModel(readAccessibility: { granted }, readLoginStatus: {
            loginReads += 1
            return .notRegistered
        })
        model.onConfigurationChange = { configurationChanges += 1 }
        for _ in 0..<3 { model.refreshPermission() }
        XCTAssertTrue(model.activity.isEmpty, "unchanged denied permission")
        granted = true
        for _ in 0..<3 { model.refreshPermission() }
        XCTAssertTrue(model.accessibilityGranted)
        granted = false
        for _ in 0..<3 { model.refreshPermission() }
        XCTAssertFalse(model.accessibilityGranted)
        XCTAssertTrue(model.enabled, "Revoking access retains the user's enabled preference")
        XCTAssertEqual(configurationChanges, 2, "one reconfiguration per trust transition")
        XCTAssertEqual(model.activity.map(\.message), [
            "Accessibility access is unavailable.", "Accessibility access granted."
        ])
        XCTAssertEqual(loginReads, 1, "only initialization queries ServiceManagement")
    }

    @MainActor
    func testMonitoringRetryIsExplicitAndRespectsPauseAndRunningState() async {
        let model = makeModel()
        var retries = 0
        model.onMonitoringRetry = { retries += 1 }
        model.setMonitoringState(.unavailable)
        model.setMonitoringState(.unavailable)
        XCTAssertEqual(model.activity.count, 1, "repeated failure is not another transition")
        XCTAssertTrue(model.canRetryMonitoring)
        model.refreshPermission()
        XCTAssertEqual(retries, 0, "unchanged trust must not automatically retry")
        model.retryMonitoring()
        XCTAssertEqual(retries, 1, "explicit retry")

        model.enabled = false
        XCTAssertFalse(model.canRetryMonitoring, "intentional pause")
        model.retryMonitoring()
        XCTAssertEqual(retries, 1, "paused monitoring stays paused")
        model.enabled = true
        model.setMonitoringState(.running)
        model.retryMonitoring()
        XCTAssertEqual(retries, 1, "a working monitor needs no retry")
    }

    @MainActor
    func testMonitoringRetryRechecksRevokedPermission() async {
        var granted = true
        let model = makeModel(readAccessibility: { granted })
        var retries = 0
        var configurationChanges = 0
        model.onMonitoringRetry = { retries += 1 }
        model.onConfigurationChange = { configurationChanges += 1 }
        model.setMonitoringState(.unavailable)
        granted = false
        model.retryMonitoring()
        XCTAssertFalse(model.canRetryMonitoring)
        XCTAssertEqual(retries, 0, "revoked permission must prevent a new tap")
        XCTAssertEqual(configurationChanges, 1, "revocation uses the same state update as polling")
    }

    @MainActor
    func testActivityRemainsBoundedAndSessionOnly() async {
        let model = makeModel()
        for index in 0..<90 { model.record("Verified attempt \(index)") }
        XCTAssertEqual(model.activity.count, 80)
        XCTAssertEqual(model.activity.first?.message, "Verified attempt 89")
        XCTAssertEqual(model.activity.last?.message, "Verified attempt 10")
        XCTAssertTrue(makeModel().activity.isEmpty, "a new session starts empty")
    }

    @MainActor
    func testAdditionalCloseMethodsPersistAndInvalidatePendingDecisions() async {
        let suite = "MxltUtilsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = QuitModel(defaults: defaults, readAccessibility: { true }, readLoginStatus: { .notRegistered })
        XCTAssertTrue(model.additionalCloseMethods)
        var changes = 0
        model.onConfigurationChange = { changes += 1 }
        model.additionalCloseMethods = false
        model.additionalCloseMethods = false
        XCTAssertEqual(changes, 1)
        let restored = QuitModel(defaults: defaults, readAccessibility: { true }, readLoginStatus: { .notRegistered })
        XCTAssertFalse(restored.additionalCloseMethods)
        XCTAssertEqual(restored.behavior, .lastWindow)
        XCTAssertFalse(restored.forceQuitEnabled)
    }

    @MainActor
    func testNewFeatureIsOptInAndDoesNotReadLegacyCallQuitsPreferenceKeys() async {
        let suite = "MxltUtilsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Even if old keys were copied into this suite, this is an independent feature domain.
        defaults.set(true, forKey: "enabled")
        defaults.set(true, forKey: "forceQuitEnabled")
        defaults.set(true, forKey: "quitOnAnyWindow")
        let model = QuitModel(defaults: defaults, readAccessibility: { true }, readLoginStatus: { .notRegistered })
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.effectiveEnabled)
        XCTAssertFalse(model.forceQuitEnabled)
        XCTAssertEqual(model.behavior, .lastWindow)
        XCTAssertTrue(model.additionalCloseMethods)
        XCTAssertTrue(defaults.bool(forKey: "enabled"), "legacy settings are not mutated")
        XCTAssertTrue(defaults.bool(forKey: "forceQuitEnabled"))
    }

    @MainActor
    func testSuspensionInvalidatesWorkWithoutChangingPersistedFeatureChoice() async {
        let suite = "MxltUtilsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = QuitModel(defaults: defaults, readAccessibility: { true }, readLoginStatus: { .notRegistered })
        model.enabled = true
        var changes = 0
        model.onConfigurationChange = { changes += 1 }
        model.suspended = true
        model.suspended = true
        XCTAssertEqual(changes, 1, "suspension invalidates pending decisions once")
        XCTAssertTrue(model.enabled)
        XCTAssertFalse(model.effectiveEnabled)
        XCTAssertFalse(model.canRetryMonitoring)
        let restored = QuitModel(defaults: defaults, readAccessibility: { true }, readLoginStatus: { .notRegistered })
        XCTAssertTrue(restored.enabled)
        XCTAssertFalse(restored.suspended, "session suspension does not become a preference")
        model.suspended = false
        XCTAssertTrue(model.effectiveEnabled)
        XCTAssertEqual(changes, 2)
        model.enabled = false
        model.suspended = true
        model.suspended = false
        XCTAssertFalse(model.effectiveEnabled, "resume must not enable a disabled feature")
    }

    func testSyntheticReplayIsIdentifiableWithoutDiscardingOriginalInput() throws {
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: .zero, mouseButton: .center))
            XCTAssertFalse(CloseMonitorInput.isSynthetic(event), "original input remains eligible")
            event.setIntegerValueField(.eventSourceUserData, value: CloseMonitorInput.syntheticEventMarker)
            XCTAssertTrue(CloseMonitorInput.isSynthetic(event), "our replay never creates close intent")
            let unrelatedSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
            unrelatedSource.userData = 17
            let unrelated = try XCTUnwrap(CGEvent(mouseEventSource: unrelatedSource, mouseType: type,
                                                  mouseCursorPosition: .zero, mouseButton: .center))
            XCTAssertFalse(CloseMonitorInput.isSynthetic(unrelated), "do not discard unrelated tagged input")
        }
    }

    func testTapControlNotificationsSurviveStaleSyntheticMetadata() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        source.userData = CloseMonitorInput.syntheticEventMarker
        let event = try XCTUnwrap(CGEvent(source: source))
        XCTAssertTrue(CloseMonitorInput.shouldIgnore(.leftMouseDown, event: event))
        XCTAssertFalse(CloseMonitorInput.shouldIgnore(.tapDisabledByTimeout, event: event))
        XCTAssertFalse(CloseMonitorInput.shouldIgnore(.tapDisabledByUserInput, event: event))
    }

    func testTimeoutRecoveryIsBoundedAndRespectsDisabledOrUntrustedState() {
        var recovery = TapRecovery()
        XCTAssertFalse(recovery.shouldRetry(enabled: false, trusted: true), "intentional pause")
        XCTAssertFalse(recovery.shouldRetry(enabled: true, trusted: false), "permission revoked")
        XCTAssertTrue(recovery.shouldRetry(enabled: true, trusted: true), "first timeout")
        XCTAssertFalse(recovery.shouldRetry(enabled: true, trusted: true), "repeated timeout")
        recovery = TapRecovery()
        XCTAssertTrue(recovery.shouldRetry(enabled: true, trusted: true), "a new tap resets recovery")
    }

    func testSecondaryAndAuxiliaryPressesSubscribeAndCancelBeforeNewIntent() {
        for type in [CGEventType.keyDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertNotEqual(CloseMonitorInput.eventMask & (CGEventMask(1) << type.rawValue), 0,
                              "the native tap must receive interruption \(type)")
            XCTAssertTrue(CloseMonitorInput.interrupts(type), "must cancel before gesture/AX routing")
        }
        for mask in [NSEvent.EventTypeMask.keyDown, .rightMouseDown, .otherMouseDown, .leftMouseDown] {
            XCTAssertTrue(CloseMonitorInput.localMask.contains(mask), "interaction with CallQuits also cancels")
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .otherMouseUp, .otherMouseDragged] {
            XCTAssertNotEqual(CloseMonitorInput.eventMask & (CGEventMask(1) << type.rawValue), 0)
            XCTAssertFalse(CloseMonitorInput.interrupts(type), "native left gesture keeps its own validation")
        }
        for type in [CGEventType.mouseMoved, .flagsChanged, .rightMouseUp] {
            XCTAssertEqual(CloseMonitorInput.eventMask & (CGEventMask(1) << type.rawValue), 0,
                           "do not introduce extra input collection")
            XCTAssertFalse(CloseMonitorInput.interrupts(type))
        }
    }

    func testOnlyMiddleAuxiliaryButtonCanEnterTabCaptureAndReplayStaysIgnored() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .center))
        for button in [1, 2, 3, 4, 31] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            for type in [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged] {
                XCTAssertEqual(CloseMonitorInput.pointerButton(type, event: event), button == 2 ? 2 : nil)
            }
        }
        event.setIntegerValueField(.eventSourceUserData, value: CloseMonitorInput.syntheticEventMarker)
        for type in [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged] {
            XCTAssertTrue(CloseMonitorInput.shouldIgnore(type, event: event))
        }
        XCTAssertNil(CloseMonitorInput.pointerButton(.rightMouseDown, event: event))
    }
}
