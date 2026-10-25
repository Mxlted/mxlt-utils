import XCTest
@testable import MxltCore

final class ScrollGestureTests: XCTestCase {
    private let origin = ScrollPoint(x: 100, y: 100)

    func testShortMiddleClickIsPreserved() {
        var gesture = ScrollGesture()
        XCTAssertTrue(gesture.begin(at: origin, timestamp: 1))
        XCTAssertEqual(gesture.phase, .pending)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertFalse(gesture.move(to: ScrollPoint(x: 103, y: 104)))
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1.15, targetIsValid: true), .replayClick)
        XCTAssertEqual(gesture.phase, .idle)
        XCTAssertNil(gesture.anchor)
    }

    func testDeadZoneBoundaryDoesNotScroll() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        XCTAssertFalse(gesture.move(to: ScrollPoint(x: 108, y: 100)))
        XCTAssertEqual(gesture.phase, .pending)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertTrue(gesture.move(to: ScrollPoint(x: 108.001, y: 100)))
        XCTAssertGreaterThan(gesture.velocity.x, 0)
    }

    func testDistanceControlsSpeedAndStationaryPointerKeepsItsVelocity() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        XCTAssertTrue(gesture.move(to: ScrollPoint(x: 100, y: 118)))
        XCTAssertEqual(gesture.velocity, ScrollVelocity(x: 0, y: 44))
        XCTAssertFalse(gesture.move(to: ScrollPoint(x: 100, y: 128)))
        XCTAssertEqual(gesture.velocity, ScrollVelocity(x: 0, y: 96))
        // Timer ticks read this value without requiring further movement events.
        XCTAssertEqual(gesture.velocity, ScrollVelocity(x: 0, y: 96))
        XCTAssertEqual(gesture.release(at: ScrollPoint(x: 100, y: 128), timestamp: 1.2,
                                       targetIsValid: true), .consumed)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertEqual(gesture.phase, .idle)
    }

    func testDiagonalVelocityUsesOneRadialDeadZone() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        gesture.move(to: ScrollPoint(x: 130, y: 140))
        XCTAssertEqual(gesture.velocity.x / gesture.velocity.y, 3.0 / 4, accuracy: 0.0001)
        var axial = ScrollGesture()
        axial.begin(at: origin, timestamp: 1)
        axial.move(to: ScrollPoint(x: 150, y: 100))
        XCTAssertEqual(hypot(gesture.velocity.x, gesture.velocity.y), axial.velocity.x, accuracy: 0.0001)
    }

    func testReturningToDeadZoneStopsButNeverReplaysClick() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        gesture.move(to: ScrollPoint(x: 100, y: 140))
        gesture.move(to: origin)
        XCTAssertEqual(gesture.phase, .scrolling)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1.2, targetIsValid: true), .consumed)
    }

    func testMissedMoveBeforeReleaseCannotFabricateClick() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        XCTAssertEqual(gesture.release(at: ScrollPoint(x: 100, y: 140), timestamp: 1.1,
                                       targetIsValid: true), .consumed)
        XCTAssertEqual(gesture.velocity, .zero)
    }

    func testCancellationConsumesReleaseAndDoesNotRestartFromMovement() {
        for shouldScroll in [false, true] {
            var gesture = ScrollGesture()
            gesture.begin(at: origin, timestamp: 1)
            if shouldScroll { gesture.move(to: ScrollPoint(x: 100, y: 140)) }
            gesture.cancel()
            gesture.cancel()
            XCTAssertEqual(gesture.phase, .cancelled)
            XCTAssertEqual(gesture.velocity, .zero)
            XCTAssertFalse(gesture.move(to: ScrollPoint(x: 300, y: 300)))
            XCTAssertFalse(gesture.begin(at: origin, timestamp: 1.1))
            XCTAssertEqual(gesture.release(at: origin, timestamp: 1.2, targetIsValid: true), .consumed)
            XCTAssertTrue(gesture.begin(at: origin, timestamp: 2))
        }
    }

    func testInvalidTargetNeverReplaysMiddleClick() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1.1, targetIsValid: false), .consumed)
    }

    func testExpiredOrInvalidTimeNeverReplaysClick() {
        for releaseTime in [0.9, 1.501, .infinity, .nan] {
            var gesture = ScrollGesture()
            gesture.begin(at: origin, timestamp: 1)
            XCTAssertEqual(gesture.release(at: origin, timestamp: releaseTime, targetIsValid: true), .consumed)
            XCTAssertEqual(gesture.phase, .idle)
        }
    }

    func testDuplicateDownCannotReplaceOriginalAnchor() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        XCTAssertFalse(gesture.begin(at: ScrollPoint(x: 800, y: 800), timestamp: 1.1))
        XCTAssertEqual(gesture.anchor, origin)
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1.2, targetIsValid: true), .replayClick)
    }

    func testDirectionAndSensitivityAreCapturedForGesture() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1,
                      settings: ScrollSettings(sensitivity: 2, deadZone: 10, reversed: true))
        gesture.move(to: ScrollPoint(x: 100, y: 120))
        XCTAssertEqual(gesture.velocity, ScrollVelocity(x: 0, y: -88))
        gesture.move(to: ScrollPoint(x: 80, y: 100))
        XCTAssertEqual(gesture.velocity, ScrollVelocity(x: 88, y: 0))
    }

    func testVeryLargeAndMixedDisplayCoordinatesStayBounded() {
        var gesture = ScrollGesture()
        gesture.begin(at: ScrollPoint(x: -2400, y: -500), timestamp: 1,
                      settings: ScrollSettings(sensitivity: 10))
        gesture.move(to: ScrollPoint(x: 100_000, y: 100_000))
        XCTAssertEqual(hypot(gesture.velocity.x, gesture.velocity.y), ScrollGesture.maximumSpeed,
                       accuracy: 0.000001)
        XCTAssertGreaterThan(gesture.velocity.x, 0)
        XCTAssertGreaterThan(gesture.velocity.y, 0)
    }

    func testMalformedCoordinatesCancelWithoutScrollOrReplay() {
        var gesture = ScrollGesture()
        XCTAssertFalse(gesture.begin(at: ScrollPoint(x: .nan, y: 0), timestamp: 1))
        XCTAssertFalse(gesture.begin(at: origin, timestamp: -.infinity))
        XCTAssertFalse(gesture.begin(at: origin, timestamp: -1))
        XCTAssertEqual(gesture.phase, .idle)
        gesture.begin(at: origin, timestamp: 1)
        gesture.move(to: ScrollPoint(x: .infinity, y: 0))
        XCTAssertEqual(gesture.phase, .cancelled)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1.1, targetIsValid: true), .consumed)
    }

    func testOverflowingCoordinateDifferenceFailsClosed() {
        var gesture = ScrollGesture()
        gesture.begin(at: ScrollPoint(x: -Double.greatestFiniteMagnitude, y: 0), timestamp: 1)
        gesture.move(to: ScrollPoint(x: Double.greatestFiniteMagnitude, y: 0))
        XCTAssertEqual(gesture.phase, .cancelled)
        XCTAssertEqual(gesture.velocity, .zero)
    }

    func testSettingsSanitizeCorruptAndOutOfRangeValues() {
        XCTAssertEqual(ScrollSettings(sensitivity: .nan, deadZone: .infinity), ScrollSettings())
        XCTAssertEqual(ScrollSettings(sensitivity: -10, deadZone: -10).sensitivity, 0.2)
        XCTAssertEqual(ScrollSettings(sensitivity: -10, deadZone: -10).deadZone, 2)
        XCTAssertEqual(ScrollSettings(sensitivity: 100, deadZone: 100).sensitivity, 10)
        XCTAssertEqual(ScrollSettings(sensitivity: 100, deadZone: 100).deadZone, 40)
    }

    func testSpeedSliderScalesProgressiveCurveWithinSharedCeiling() {
        func speed(_ sensitivity: Double, offset: Double) -> Double {
            var gesture = ScrollGesture()
            gesture.begin(at: origin, timestamp: 1, settings: ScrollSettings(sensitivity: sensitivity))
            gesture.move(to: ScrollPoint(x: origin.x + offset, y: origin.y))
            return gesture.velocity.x
        }
        let baseline = speed(1, offset: 100)
        for sensitivity in [0.2, 1, 3, 10] {
            XCTAssertEqual(speed(sensitivity, offset: 100), baseline * sensitivity, accuracy: 0.000001)
            XCTAssertEqual(speed(sensitivity, offset: 100_000), ScrollGesture.maximumSpeed)
            XCTAssertEqual(speed(sensitivity, offset: Double.greatestFiniteMagnitude), ScrollGesture.maximumSpeed)
        }
    }

    func testProgressiveDistanceCurveHasFineControlAndContinuesPastOldPlateau() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        func speed(_ displacement: Double) -> Double {
            gesture.move(to: ScrollPoint(x: origin.x, y: origin.y + 8 + displacement))
            return gesture.velocity.y
        }
        XCTAssertLessThan(speed(1), 5, "Fine control just outside the dead zone")
        let near = speed(50)
        let medium = speed(100)
        let far = speed(150)
        XCTAssertGreaterThan(far - medium, medium - near, "Equal distance increments accelerate progressively")
        let oldPlateau = speed(300)
        XCTAssertGreaterThan(oldPlateau, 2400)
        XCTAssertGreaterThan(speed(350), oldPlateau, "Moving farther still accelerates beyond the old ceiling")
        XCTAssertEqual(speed(100), medium, "Returning closer slows back to the same requested speed")
        XCTAssertEqual(speed(0), 0)
    }

    func testDistanceCurveIsMonotonicAndSymmetricAcrossSettings() {
        for sensitivity in [0.2, 1, 3, 10] {
            for deadZone in [2.0, 8, 40] {
                var gesture = ScrollGesture()
                gesture.begin(at: origin, timestamp: 1,
                              settings: ScrollSettings(sensitivity: sensitivity, deadZone: deadZone))
                var previous = 0.0
                for displacement in stride(from: 0.0, through: 1000, by: 5) {
                    gesture.move(to: ScrollPoint(x: origin.x + deadZone + displacement, y: origin.y))
                    let speed = gesture.velocity.x
                    XCTAssertGreaterThanOrEqual(speed, previous)
                    XCTAssertLessThanOrEqual(speed, ScrollGesture.maximumSpeed)
                    gesture.move(to: ScrollPoint(x: origin.x - deadZone - displacement, y: origin.y))
                    XCTAssertEqual(gesture.velocity.x, -speed, accuracy: 0.000001)
                    previous = speed
                }
            }
        }
    }

    func testFarDistanceBoostPreservesNearControlAndHasNoThresholdJump() {
        var gesture = ScrollGesture()
        gesture.begin(at: origin, timestamp: 1)
        func speed(_ distance: Double) -> Double {
            gesture.move(to: ScrollPoint(x: origin.x + 8 + distance, y: origin.y))
            return gesture.velocity.x
        }
        for (distance, expected) in [(10.0, 44.0), (100, 800), (200, 2400)] {
            XCTAssertEqual(speed(distance), expected, accuracy: 0.000001)
        }
        XCTAssertLessThan(speed(200.001) - speed(199.999), 0.05, "No sudden speed step at boost onset")
        XCTAssertEqual(speed(400), 16_000, accuracy: 0.000001)
        XCTAssertEqual(speed(600), 48_000, accuracy: 0.000001)
        XCTAssertEqual(speed(1000), 48_000, accuracy: 0.000001)
        XCTAssertEqual(speed(100), 800, accuracy: 0.000001, "Returning closer restores precise control")
    }

    func testIdleEventsAndRepeatedCleanupDoNotInventGesture() {
        var gesture = ScrollGesture()
        gesture.cancel()
        XCTAssertEqual(gesture.phase, .idle)
        XCTAssertFalse(gesture.move(to: origin))
        XCTAssertEqual(gesture.release(at: origin, timestamp: 1, targetIsValid: true), .none)
        gesture.begin(at: origin, timestamp: 2)
        gesture.move(to: ScrollPoint(x: 100, y: 140))
        gesture.reset()
        gesture.reset()
        XCTAssertEqual(gesture.phase, .idle)
        XCTAssertNil(gesture.anchor)
        XCTAssertEqual(gesture.velocity, .zero)
        XCTAssertEqual(gesture.release(at: origin, timestamp: 2.1, targetIsValid: true), .none)
    }
}
