// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import XCTest
@testable import CallQuitsCore

final class CloseGestureTests: XCTestCase {
    private func gesture(_ modifiers: CloseGestureModifiers = .normal) -> CloseGesture {
        CloseGesture(x: 100, y: 200, timestamp: 10, targetProcessID: 42, modifiers: modifiers)!
    }

    private func release(
        _ gesture: CloseGesture,
        x: Double = 100,
        y: Double = 200,
        timestamp: TimeInterval = 10.1,
        targetProcessID: Int32 = 42,
        modifiers: CloseGestureModifiers = .normal
    ) -> CloseGestureAction? {
        gesture.actionOnRelease(x: x, y: y, timestamp: timestamp,
                                targetProcessID: targetProcessID, modifiers: modifiers)
    }

    func testOrdinaryClickRequestsOnlyGracefulQuit() {
        XCTAssertEqual(release(gesture()), .graceful)
    }

    func testForceRequiresMatchingForceIntentAcrossTheClick() {
        XCTAssertEqual(release(gesture(.force), modifiers: .force), .force)
        // Pressing Shift only after an ordinary press must never upgrade it to force quit.
        XCTAssertNil(release(gesture(.normal), modifiers: .force))
        // Releasing Shift before mouse-up cancels rather than changing the meaning of the gesture.
        XCTAssertNil(release(gesture(.force), modifiers: .normal))
        XCTAssertNil(release(gesture(.force), modifiers: .bypass))
        XCTAssertNil(release(gesture(.normal), modifiers: .bypass))
    }

    func testUnsupportedModifiersCannotStartAGesture() {
        XCTAssertNil(CloseGesture(x: 100, y: 200, timestamp: 10, targetProcessID: 42, modifiers: .bypass))
    }

    func testDifferentEventRecipientCannotReceiveTheQuit() {
        for modifiers in [CloseGestureModifiers.normal, .force] {
            for otherPID: Int32 in [-1, 0, 1, 43, Int32.max] {
                XCTAssertNil(release(gesture(modifiers), targetProcessID: otherPID, modifiers: modifiers),
                             "press PID=42, release PID=\(otherPID), modifiers=\(modifiers)")
            }
        }
    }

    func testUnknownEventRecipientCannotStartAGesture() {
        for unknownPID: Int32 in [-1, 0, 1] {
            XCTAssertNil(CloseGesture(x: 100, y: 200, timestamp: 10, targetProcessID: unknownPID, modifiers: .normal),
                         "press PID=\(unknownPID)")
        }
    }

    func testSlightPointerMovementIsAllowedButDraggingAwayCancels() {
        let gesture = gesture()
        XCTAssertTrue(gesture.allowsDrag(toX: 102, y: 202))
        XCTAssertTrue(gesture.allowsDrag(toX: 104, y: 200))
        XCTAssertFalse(gesture.allowsDrag(toX: 104.01, y: 200))
        XCTAssertFalse(gesture.allowsDrag(toX: 103, y: 203))
        XCTAssertEqual(release(gesture, x: 104), .graceful)
        // Validate the release too, even if the event system omitted intermediate drag events.
        XCTAssertNil(release(gesture, x: 105))
    }

    func testLongHoldsAndReversedTimestampsCancel() {
        let gesture = gesture()
        XCTAssertEqual(release(gesture, timestamp: 13), .graceful)
        XCTAssertNil(release(gesture, timestamp: 13.001))
        XCTAssertNil(release(gesture, timestamp: 9.9))
        XCTAssertEqual(release(gesture, timestamp: 10), .graceful)
    }

    func testInvalidNumbersFailClosed() {
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(CloseGesture(x: invalid, y: 200, timestamp: 10, targetProcessID: 42, modifiers: .normal),
                         "press x=\(invalid)")
            XCTAssertNil(CloseGesture(x: 100, y: invalid, timestamp: 10, targetProcessID: 42, modifiers: .normal),
                         "press y=\(invalid)")
            XCTAssertNil(CloseGesture(x: 100, y: 200, timestamp: invalid, targetProcessID: 42, modifiers: .normal),
                         "press timestamp=\(invalid)")
            XCTAssertFalse(gesture().allowsDrag(toX: invalid, y: 200), "drag x=\(invalid)")
            XCTAssertFalse(gesture().allowsDrag(toX: 100, y: invalid), "drag y=\(invalid)")
            XCTAssertNil(release(gesture(), x: invalid), "release x=\(invalid)")
            XCTAssertNil(release(gesture(), y: invalid), "release y=\(invalid)")
            XCTAssertNil(release(gesture(), timestamp: invalid), "release timestamp=\(invalid)")
        }
        XCTAssertNil(CloseGesture(x: 100, y: 200, timestamp: -1, targetProcessID: 42, modifiers: .normal))
    }

    func testNegativeCoordinatesSupportDisplaysLeftOfOrAboveTheMainDisplay() {
        let gesture = CloseGesture(x: -800, y: -200, timestamp: 10, targetProcessID: 42, modifiers: .normal)!
        XCTAssertEqual(release(gesture, x: -800, y: -200), .graceful)
    }
}

final class CloseShortcutTests: XCTestCase {
    func testLayoutResolvedWAndModifiers() {
        for character in ["w", "W"] {
            XCTAssertTrue(CloseShortcut.matches(character: character, command: true, shift: false,
                                                option: false, control: false, isRepeat: false))
        }
        for character: String? in [nil, "", "z", "q", "ww"] {
            XCTAssertFalse(CloseShortcut.matches(character: character, command: true, shift: false,
                                                 option: false, control: false, isRepeat: false))
        }
        for flags in [(false, false, false, false, false), (true, true, false, false, false),
                      (true, false, true, false, false), (true, false, false, true, false),
                      (true, false, false, false, true)] {
            XCTAssertFalse(CloseShortcut.matches(character: "w", command: flags.0, shift: flags.1,
                                                 option: flags.2, control: flags.3, isRepeat: flags.4))
        }
    }

    func testTabsAndShortcutsCannotForceQuitOrInheritAnyWindowMode() {
        for trigger in [CloseTrigger.tabButton, .keyboardShortcut] {
            XCTAssertFalse(trigger.allowsForceQuit)
            XCTAssertEqual(trigger.behavior(configured: .everyWindow), .lastWindow)
            var session = CloseSession(behavior: trigger.behavior(configured: .everyWindow), startedAt: 10)
            let survivingWindow = CloseSnapshot(windowCount: 1, targetWindowPresent: false,
                                                 hasBlockingUI: false, isReliable: true)
            XCTAssertEqual(session.evaluate(snapshot: survivingWindow, now: 10.1), .cancel(.remainingWindows))
        }
        XCTAssertTrue(CloseTrigger.windowButton.allowsForceQuit)
        XCTAssertEqual(CloseTrigger.windowButton.behavior(configured: .everyWindow), .everyWindow)
    }

    func testShortcutPreflightPinsRecipientExpiryAndOneRequest() throws {
        var intent = try XCTUnwrap(CloseShortcutIntent(processID: 42, startedAt: 10))
        XCTAssertFalse(intent.isReady(at: 10.1), "Command alone never requests quit")
        XCTAssertFalse(intent.request(processID: 43, at: 10.1))
        XCTAssertFalse(intent.request(processID: 42, at: 9))
        XCTAssertFalse(intent.request(processID: 42, at: .nan))
        XCTAssertFalse(intent.request(processID: 42, at: 13))
        XCTAssertTrue(intent.request(processID: 42, at: 10.2))
        XCTAssertFalse(intent.request(processID: 42, at: 10.3))
        XCTAssertFalse(intent.isReady(at: 10.1))
        XCTAssertTrue(intent.isReady(at: 10.21))
        XCTAssertFalse(intent.isReady(at: 11.01), "a stalled capture cannot use an old command")
        XCTAssertFalse(intent.isReady(at: .infinity))
        XCTAssertNil(CloseShortcutIntent(processID: 0, startedAt: 10))
        XCTAssertNil(CloseShortcutIntent(processID: 42, startedAt: .nan))
    }
}
