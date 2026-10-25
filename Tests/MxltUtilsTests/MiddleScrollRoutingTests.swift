import AppKit
import MxltCore
import XCTest
@testable import MxltUtils

final class MiddleScrollRoutingTests: XCTestCase {
    private let bounds = CGRect(x: -500, y: 120, width: 400, height: 300)
    private let anchor = ScrollPoint(x: -300, y: 200)

    func testGeneratedSourceExplicitlyPermitsAllHardwareInput() throws {
        let source = try XCTUnwrap(MiddleScrollEventRouting.source())
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
            XCTAssertEqual(source.getLocalEventsFilterDuringSuppressionState(state),
                           [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents])
        }
        XCTAssertEqual(source.userData, MiddleScrollEventRouting.syntheticTag)
    }

    private func window(id: UInt32 = 7, owner: Int32 = 42, frame: CGRect? = nil,
                        layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowOwnerPID as String: NSNumber(value: owner),
         kCGWindowBounds as String: (frame ?? bounds).dictionaryRepresentation,
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    private func valid(_ windows: [[String: Any]]) -> Bool {
        MiddleScrollWindowRouting.isValid(windows: windows, processID: 42, windowID: 7,
                                         initialBounds: bounds, initialLayer: 0, anchor: anchor, ownProcessID: 99)
    }

    func testNormalWindowsMenusAndPanelsCanBePinnedAndRevalidated() throws {
        for level in [NSWindow.Level.normal, .floating, .submenu, .modalPanel, .popUpMenu] {
            let layer = Int(level.rawValue)
            let metadata = window(layer: layer)
            let snapshot = try XCTUnwrap(MiddleScrollWindowSnapshot(window: metadata, processID: 42,
                                                                   windowID: 7, anchor: anchor))
            XCTAssertEqual(snapshot.layer, layer)
            XCTAssertEqual(snapshot.bounds, bounds)
            XCTAssertTrue(MiddleScrollWindowRouting.isValid(
                windows: [metadata, window(id: 8)], processID: 42, windowID: 7,
                initialBounds: snapshot.bounds, initialLayer: snapshot.layer, anchor: anchor, ownProcessID: 99),
                "A valid app-owned surface must not lose clicks just because it is above the normal level")
        }
    }

    func testPopupCannotFallThroughToParentOrRetargetAfterChanging() throws {
        let layer = Int(NSWindow.Level.popUpMenu.rawValue)
        let popup = window(layer: layer)
        let snapshot = try XCTUnwrap(MiddleScrollWindowSnapshot(window: popup, processID: 42,
                                                               windowID: 7, anchor: anchor))
        let parent = window(id: 8)
        let invalidWindows = [
            [parent], // Dismissed menu: never click the underlying browser window.
            [window(id: 9, layer: layer), parent], // Replacement menu from the same app.
            [window(owner: 43, layer: layer), parent],
            [window(frame: bounds.offsetBy(dx: 1, dy: 0), layer: layer), parent],
            [window(frame: CGRect(x: -500, y: 120, width: 401, height: 300), layer: layer), parent],
            [window(layer: 0), parent], // Same ID and bounds, different level.
            [window(layer: layer, alpha: 0), parent],
            [window(id: 9, layer: layer), popup, parent], // Nested submenu covers the anchor.
            [window(id: 9, owner: 43, layer: layer), popup, parent]
        ]
        for windows in invalidWindows {
            XCTAssertFalse(MiddleScrollWindowRouting.isValid(
                windows: windows, processID: 42, windowID: 7, initialBounds: snapshot.bounds,
                initialLayer: snapshot.layer, anchor: anchor, ownProcessID: 99))
        }
    }

    func testTargetSnapshotRejectsUncertainOrNoninteractiveMetadata() {
        var invalid = [window(id: 8), window(owner: 43), window(layer: -1),
                       window(alpha: 0), window(alpha: .nan),
                       window(frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds] {
            var metadata = window()
            metadata.removeValue(forKey: key as String)
            invalid.append(metadata)
        }
        for metadata in invalid {
            XCTAssertNil(MiddleScrollWindowSnapshot(window: metadata, processID: 42, windowID: 7, anchor: anchor))
        }
        XCTAssertNil(MiddleScrollWindowSnapshot(window: window(), processID: 42, windowID: 7,
                                               anchor: ScrollPoint(x: .nan, y: 200)))
    }

    func testSameWindowAtAnchorRemainsValidAcrossNegativeDisplayCoordinates() {
        XCTAssertTrue(valid([window()]))
        XCTAssertTrue(valid([window(id: 8, frame: CGRect(x: 0, y: 0, width: 200, height: 200)), window()]))
    }

    func testClosedMovedResizedOrReownedWindowCannotReceiveScrollOrReplay() {
        XCTAssertFalse(valid([]))
        XCTAssertFalse(valid([window(owner: 43)]))
        XCTAssertFalse(valid([window(id: 8)]))
        XCTAssertFalse(valid([window(frame: bounds.offsetBy(dx: 1, dy: 0))]))
        XCTAssertFalse(valid([window(frame: CGRect(x: -500, y: 120, width: 401, height: 300))]))
    }

    func testCoveringWindowCancelsEvenWithinSameAppOrOurSettings() {
        XCTAssertFalse(valid([window(id: 8), window()]))
        XCTAssertFalse(valid([window(id: 8, owner: 43), window()]))
        XCTAssertFalse(valid([window(id: 8, owner: 99), window()]))
        XCTAssertFalse(valid([window(id: 8, owner: 43, layer: 24), window()]))
    }

    func testNoninteractiveIndicatorAndTransparentWindowsDoNotRedirectTarget() {
        XCTAssertTrue(valid([window(id: 8, owner: 99, layer: Int(NSWindow.Level.floating.rawValue)), window()]))
        XCTAssertTrue(valid([window(id: 8, owner: 43, alpha: 0), window()]))
    }

    func testObservedSystemCanvasExceptionsRequireExactOwnerLayerAndDisplayBounds() {
        let display = CGRect(x: -600, y: 0, width: 1000, height: 800)
        func permits(_ overlay: [String: Any], hitPID: Int32? = 42) -> Bool {
            MiddleScrollWindowRouting.isValid(windows: [overlay, window()], processID: 42, windowID: 7,
                                             initialBounds: bounds, initialLayer: 0, anchor: anchor, ownProcessID: 99,
                                             systemCanvases: [459: 20, 591: 21], displayBounds: [display], systemHitProcessID: hitPID)
        }
        XCTAssertTrue(permits(window(id: 15, owner: 459, frame: display, layer: 20)))
        XCTAssertFalse(permits(window(id: 15, owner: 459, frame: display, layer: 20), hitPID: nil))
        XCTAssertFalse(permits(window(id: 15, owner: 459, frame: display, layer: 20), hitPID: 459), "interactive Dock overlay")
        XCTAssertTrue(permits(window(id: 23, owner: 591, frame: display, layer: 21)))
        XCTAssertFalse(permits(window(id: 23, owner: 591, frame: display, layer: 21), hitPID: 591))
        XCTAssertFalse(permits(window(id: 23, owner: 591, frame: display, layer: 20)))
        XCTAssertFalse(permits(window(id: 15, owner: 460, frame: display, layer: 20)))
        XCTAssertFalse(permits(window(id: 15, owner: 459, frame: display, layer: 0)))
        XCTAssertFalse(permits(window(id: 15, owner: 459, frame: bounds, layer: 20)), "real Dock/menu overlay")
        XCTAssertFalse(permits(window(id: 15, owner: 42, frame: display, layer: 0)), "same-app covering window")
    }

    func testIncompleteWindowMetadataFailsClosed() {
        var malformed = window(id: 8)
        malformed.removeValue(forKey: kCGWindowBounds as String)
        XCTAssertFalse(valid([malformed, window()]))
        malformed = window()
        malformed[kCGWindowBounds as String] = ["X": "not a number"]
        XCTAssertFalse(valid([malformed]))
    }

    func testDisplayCaptureCursorRequiresVerifiedOwnerLevelAndFreshTargetHit() {
        let cursor = window(id: 2, owner: 177, layer: Int(CGWindowLevelForKey(.cursorWindow)))
        func permits(_ overlay: [String: Any], owner: pid_t? = 177, hit: pid_t? = 42,
                     beneath: [[String: Any]]? = nil) -> Bool {
            MiddleScrollWindowRouting.isValid(
                windows: [overlay] + (beneath ?? [window()]), processID: 42, windowID: 7,
                initialBounds: bounds, initialLayer: 0, anchor: anchor, ownProcessID: 99,
                systemHitProcessID: hit, cursorProcessID: owner)
        }
        XCTAssertFalse(valid([cursor, window()]), "Reproduces the capture cursor obstruction without verification")
        XCTAssertTrue(permits(cursor))
        XCTAssertFalse(permits(cursor, owner: nil))
        XCTAssertFalse(permits(cursor, owner: 178))
        XCTAssertFalse(permits(cursor, hit: nil))
        XCTAssertFalse(permits(cursor, hit: 177))
        XCTAssertFalse(permits(window(id: 2, owner: 177, layer: 24)), "System menus remain blockers")
        XCTAssertFalse(permits(window(id: 2, owner: 43, layer: Int(CGWindowLevelForKey(.cursorWindow)))))
        XCTAssertFalse(permits(cursor, beneath: [window(id: 8), window()]), "AX app identity alone cannot bypass a same-app cover")
        XCTAssertFalse(permits(cursor, beneath: [window(id: 8, owner: 43), window()]))
        XCTAssertFalse(permits(cursor, beneath: []))
        XCTAssertFalse(permits(cursor, beneath: [window(frame: bounds.offsetBy(dx: 1, dy: 0))]))
    }

    func testCursorLevelDoesNotEstablishWindowServerIdentity() {
        let cursor = window(owner: ProcessInfo.processInfo.processIdentifier,
                            layer: Int(CGWindowLevelForKey(.cursorWindow)))
        XCTAssertNil(MiddleScrollCursorOwner.verifiedProcessID(in: [cursor]))
        XCTAssertNil(MiddleScrollCursorOwner.verifiedProcessID(in: []))
    }

    func testNativeReplayPairRetainsButtonModifiersAndClickCountAtOriginalAnchor() throws {
        let nativeSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        nativeSource.userData = 17
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nativeSource, mouseType: .otherMouseDown,
                                        mouseCursorPosition: CGPoint(x: anchor.x, y: anchor.y), mouseButton: .center))
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nativeSource, mouseType: .otherMouseUp,
                                      mouseCursorPosition: CGPoint(x: 7, y: 9), mouseButton: .center))
        down.flags = .maskShift
        up.flags = .maskShift
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        up.setIntegerValueField(.mouseEventClickState, value: 2)
        for native in [down, up] {
            let event = try XCTUnwrap(MiddleScrollEventRouting.replayEvent(native, template: down, processID: 42, windowID: 7, anchor: anchor))
            XCTAssertEqual(native.getIntegerValueField(.eventSourceUserData), 17, "native input remains untouched")
            XCTAssertEqual(event.type, native.type)
            XCTAssertEqual(event.location, CGPoint(x: -300, y: 200))
            XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), 42)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 7)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 2)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 2)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 0x4D584C54)
            XCTAssertEqual(event.flags, .maskShift)
        }
        XCTAssertEqual(down.type, .otherMouseDown)
        XCTAssertEqual(up.type, .otherMouseUp)
    }

    func testNativeWindowContextSurvivesPairedReplayAndScrollConversion() throws {
        let native = try XCTUnwrap(NSEvent.mouseEvent(with: .otherMouseDown, location: CGPoint(x: 80, y: 90),
                                                    modifierFlags: .control, timestamp: 123,
                                                    windowNumber: 999, context: nil, eventNumber: 3,
                                                    clickCount: 1, pressure: 1)?.cgEvent)
        native.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let originalSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        originalSource.userData = 17
        native.setSource(originalSource)
        let nativeAnchor = ScrollPoint(x: native.location.x, y: native.location.y)
        let replay = try XCTUnwrap(MiddleScrollEventRouting.replayEvent(native, template: native, processID: 42, windowID: 7, anchor: nativeAnchor))
        XCTAssertEqual(NSEvent(cgEvent: replay)?.windowNumber, 999, "recipient window context differs from under-pointer metadata")
        XCTAssertEqual(NSEvent(cgEvent: replay)?.locationInWindow, NSEvent(cgEvent: native)?.locationInWindow)
        let scroll = try XCTUnwrap(MiddleScrollEventRouting.scrollEvent(template: native, deltaX: 7, deltaY: -12,
                                                                       processID: 42, windowID: 7, anchor: nativeAnchor,
                                                                       timestamp: 987_000_000))
        let appKitScroll = try XCTUnwrap(NSEvent(cgEvent: scroll))
        XCTAssertEqual(appKitScroll.windowNumber, 999)
        XCTAssertEqual(appKitScroll.locationInWindow, NSEvent(cgEvent: native)?.locationInWindow)
        XCTAssertEqual(scroll.location, native.location)
        XCTAssertEqual(appKitScroll.type, .scrollWheel)
        XCTAssertTrue(appKitScroll.hasPreciseScrollingDeltas)
        XCTAssertEqual(appKitScroll.scrollingDeltaX, 7)
        XCTAssertEqual(appKitScroll.scrollingDeltaY, -12)
        XCTAssertEqual(scroll.flags, [])
        XCTAssertEqual(scroll.timestamp, 987_000_000)
        XCTAssertEqual(scroll.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
        XCTAssertEqual(scroll.getIntegerValueField(.eventSourceUserData), 0x4D584C54)
        XCTAssertEqual(native.type, .otherMouseDown)
        XCTAssertEqual(native.getIntegerValueField(.eventSourceUserData), 17)
        XCTAssertEqual(NSEvent(cgEvent: native)?.windowNumber, 999)
    }

    func testReleaseAcrossWindowEdgeRetainsDownRecipientAndReleaseSemantics() throws {
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .otherMouseDown, location: CGPoint(x: 80, y: 90),
                                                  modifierFlags: [], timestamp: 123, windowNumber: 999,
                                                  context: nil, eventNumber: 3, clickCount: 1, pressure: 1)?.cgEvent)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .otherMouseUp, location: CGPoint(x: 83, y: 90),
                                                modifierFlags: .shift, timestamp: 123.1, windowNumber: 888,
                                                context: nil, eventNumber: 4, clickCount: 1, pressure: 0)?.cgEvent)
        down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let nativeAnchor = ScrollPoint(x: down.location.x, y: down.location.y)
        let replay = try XCTUnwrap(MiddleScrollEventRouting.replayEvent(up, template: down, processID: 42,
                                                                       windowID: 7, anchor: nativeAnchor))
        XCTAssertEqual(NSEvent(cgEvent: replay)?.windowNumber, 999)
        XCTAssertEqual(NSEvent(cgEvent: up)?.windowNumber, 888, "original release stays untouched")
        XCTAssertEqual(replay.type, .otherMouseUp)
        XCTAssertEqual(replay.timestamp, up.timestamp)
        XCTAssertEqual(replay.flags, up.flags)
        XCTAssertEqual(replay.getIntegerValueField(.mouseEventNumber), up.getIntegerValueField(.mouseEventNumber))
        XCTAssertEqual(replay.getDoubleValueField(.mouseEventPressure), 0)
        XCTAssertEqual(replay.location, down.location)
        XCTAssertNil(MiddleScrollEventRouting.replayEvent(up, template: down, processID: 42,
                                                        windowID: 7, anchor: ScrollPoint(x: nativeAnchor.x + 1, y: nativeAnchor.y)))
    }

}
