import AppKit
import MxltCore
import XCTest
@testable import MxltUtils

final class MiddleScrollRoutingTests: XCTestCase {
    private let bounds = CGRect(x: -500, y: 120, width: 400, height: 300)
    private let anchor = ScrollPoint(x: -300, y: 200)

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
                                         initialBounds: bounds, anchor: anchor, ownProcessID: 99)
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
                                             initialBounds: bounds, anchor: anchor, ownProcessID: 99,
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

    func testNativeReplayPairRetainsButtonModifiersAndClickCountAtOriginalAnchor() throws {
        let nativeSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        nativeSource.userData = 17
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nativeSource, mouseType: .otherMouseDown,
                                        mouseCursorPosition: CGPoint(x: 4, y: 5), mouseButton: .center))
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nativeSource, mouseType: .otherMouseUp,
                                      mouseCursorPosition: CGPoint(x: 7, y: 9), mouseButton: .center))
        down.flags = .maskShift
        up.flags = .maskShift
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        up.setIntegerValueField(.mouseEventClickState, value: 2)
        for native in [down, up] {
            let event = try XCTUnwrap(MiddleScrollEventRouting.replayEvent(native, processID: 42, windowID: 7, anchor: anchor))
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
}
