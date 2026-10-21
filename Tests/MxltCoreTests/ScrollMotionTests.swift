import XCTest
@testable import MxltCore

final class ScrollMotionTests: XCTestCase {
    func testSmoothSpeedChangesResponseButNotSteadySpeedOrImmediateStops() {
        func gesture(speed: Double, smooth: Bool = true) -> ScrollGesture {
            var gesture = ScrollGesture()
            gesture.begin(at: ScrollPoint(x: 0, y: 0), timestamp: 1,
                          settings: ScrollSettings(smooth: smooth, smoothSpeed: speed))
            gesture.move(to: ScrollPoint(x: 83, y: 0)) // 600 points per second.
            return gesture
        }
        var initialTravel: [Int32] = []
        for speed in [0.2, 1.0, 3.0] {
            var scrolling = gesture(speed: speed)
            initialTravel.append((0..<6).reduce(0) { total, _ in total + scrolling.scrollDelta(elapsed: 1.0 / 60).x })
            for _ in 0..<240 { _ = scrolling.scrollDelta(elapsed: 1.0 / 60) }
            XCTAssertEqual(Double(scrolling.scrollDelta(elapsed: 1.0 / 60).x), 10, accuracy: 1)
            for stop in ["center", "release", "cancel"] {
                var stopped = scrolling
                switch stop {
                case "center": stopped.move(to: ScrollPoint(x: 0, y: 0))
                case "release": _ = stopped.release(at: ScrollPoint(x: 83, y: 0), timestamp: 2, targetIsValid: true)
                default: stopped.cancel()
                }
                XCTAssertEqual(stopped.scrollDelta(elapsed: 1.0 / 60), .zero)
            }
            var direct = gesture(speed: speed, smooth: false)
            XCTAssertEqual(direct.scrollDelta(elapsed: 1.0 / 60).x, 10)
        }
        XCTAssertLessThan(initialTravel[0], initialTravel[1])
        XCTAssertLessThan(initialTravel[1], initialTravel[2])
    }

    func testMaximumScrollSpeedStillBoundsDelayedOutput() {
        for speed in [0.2, 3.0] {
            var gesture = ScrollGesture()
            gesture.begin(at: ScrollPoint(x: 0, y: 0), timestamp: 1,
                          settings: ScrollSettings(sensitivity: 10, smoothSpeed: speed))
            gesture.move(to: ScrollPoint(x: 100_000, y: 100_000))
            for _ in 0..<240 { _ = gesture.scrollDelta(elapsed: 1.0 / 60) }
            let delta = gesture.scrollDelta(elapsed: 5)
            XCTAssertGreaterThan(hypot(Double(delta.x), Double(delta.y)), 80)
            XCTAssertLessThanOrEqual(hypot(Double(delta.x), Double(delta.y)), 8000.0 / 30 + 2)
        }
    }

    func testStartAndSpeedChangesEaseWithoutOvershoot() {
        var motion = ScrollMotion()
        let dt = 1.0 / 60
        let first = motion.step(toward: ScrollVelocity(x: 600, y: 0), elapsed: dt, smooth: true)
        XCTAssertGreaterThan(first.x, 0)
        XCTAssertLessThan(first.x, 10)
        for _ in 0..<60 { _ = motion.step(toward: ScrollVelocity(x: 600, y: 0), elapsed: dt, smooth: true) }
        let faster = motion.step(toward: ScrollVelocity(x: 1200, y: 0), elapsed: dt, smooth: true)
        XCTAssertGreaterThan(faster.x, 10)
        XCTAssertLessThan(faster.x, 20)
        for _ in 0..<60 {
            let delta = motion.step(toward: ScrollVelocity(x: 1200, y: 0), elapsed: dt, smooth: true)
            XCTAssertLessThanOrEqual(delta.x, 20)
        }
        let slower = motion.step(toward: ScrollVelocity(x: 600, y: 0), elapsed: dt, smooth: true)
        XCTAssertGreaterThan(slower.x, 10)
        XCTAssertLessThan(slower.x, 20)
    }

    func testIntegratedDiagonalTravelIsIndependentOfFrameRate() {
        func travel(hz: Int) -> ScrollPoint {
            var motion = ScrollMotion()
            var x = 0.0, y = 0.0
            for _ in 0..<hz {
                let delta = motion.step(toward: ScrollVelocity(x: 600, y: 800),
                                        elapsed: 1.0 / Double(hz), smooth: true)
                x += Double(delta.x); y += Double(delta.y)
            }
            return ScrollPoint(x: x, y: y)
        }
        let baseline = travel(hz: 60)
        XCTAssertEqual(baseline.x, 567, accuracy: 1)
        XCTAssertEqual(baseline.y, 756, accuracy: 1)
        for hz in [30, 120, 144, 240] {
            XCTAssertEqual(travel(hz: hz).x, baseline.x, accuracy: 1)
            XCTAssertEqual(travel(hz: hz).y, baseline.y, accuracy: 1)
        }
    }

    func testUnevenAcceptedFrameIntervalsPreserveSmoothedTravel() {
        func travel(_ intervals: [Double]) -> Double {
            var motion = ScrollMotion()
            return intervals.reduce(0) { result, elapsed in
                result + Double(motion.step(toward: ScrollVelocity(x: 600, y: 800),
                                            elapsed: elapsed, smooth: true).x)
            }
        }
        let regular = Array(repeating: 1.0 / 120, count: 120)
        let uneven = Array(repeating: [1.0 / 120, 3.0 / 120], count: 30).flatMap { $0 }
        XCTAssertEqual(travel(uneven), travel(regular), accuracy: 1)
    }

    func testLowSpeedFractionalTravelAccumulatesInBothDirections() {
        for direction in [-1.0, 1.0] {
            var motion = ScrollMotion()
            var total: Int32 = 0
            for _ in 0..<120 {
                total += motion.step(toward: ScrollVelocity(x: 3 * direction, y: 0),
                                     elapsed: 1.0 / 60, smooth: true).x
            }
            XCTAssertEqual(Double(total), 5 * direction)
        }
    }

    func testAxisStopAndReversalNeverLeakOldDirection() {
        var motion = ScrollMotion()
        for _ in 0..<60 {
            _ = motion.step(toward: ScrollVelocity(x: 600, y: 600), elapsed: 1.0 / 60, smooth: true)
        }
        let reversed = motion.step(toward: ScrollVelocity(x: -600, y: 0), elapsed: 1.0 / 60, smooth: true)
        XCTAssertLessThan(reversed.x, 0)
        XCTAssertEqual(reversed.y, 0)
        XCTAssertEqual(motion.step(toward: .zero, elapsed: 1.0 / 60, smooth: true), .zero)
        var fresh = ScrollMotion()
        XCTAssertEqual(motion.step(toward: ScrollVelocity(x: 600, y: 600), elapsed: 1.0 / 60, smooth: true),
                       fresh.step(toward: ScrollVelocity(x: 600, y: 600), elapsed: 1.0 / 60, smooth: true))
    }

    func testDisabledSmoothingUsesDirectSpeed() {
        var motion = ScrollMotion()
        XCTAssertEqual(motion.step(toward: ScrollVelocity(x: 600, y: -1200), elapsed: 1.0 / 60, smooth: false),
                       ScrollDelta(x: 10, y: -20))
        XCTAssertEqual(motion.step(toward: ScrollVelocity(x: -1200, y: 600), elapsed: 1.0 / 60, smooth: false),
                       ScrollDelta(x: -20, y: 10))
    }

    func testDelayedAndInvalidSamplesCannotQueueCatchUpTravel() {
        var motion = ScrollMotion()
        let capped = motion.step(toward: ScrollVelocity(x: 2400, y: 0), elapsed: 5, smooth: true)
        XCTAssertGreaterThan(capped.x, 0)
        XCTAssertLessThanOrEqual(capped.x, 80)
        for elapsed in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(motion.step(toward: ScrollVelocity(x: 2400, y: 0), elapsed: elapsed, smooth: true), .zero)
        }
        for target in [ScrollVelocity(x: .nan, y: 0), ScrollVelocity(x: 0, y: .infinity),
                       ScrollVelocity(x: 8000, y: 8000)] {
            XCTAssertEqual(motion.step(toward: target, elapsed: 1.0 / 60, smooth: true), .zero)
        }
        var fresh = ScrollMotion()
        XCTAssertEqual(motion.step(toward: ScrollVelocity(x: 600, y: 0), elapsed: 1.0 / 60, smooth: true),
                       fresh.step(toward: ScrollVelocity(x: 600, y: 0), elapsed: 1.0 / 60, smooth: true))
    }

    func testGestureStopsClearSmoothingBeforeAnotherTick() {
        let anchor = ScrollPoint(x: 100, y: 100)
        let moved = ScrollPoint(x: 200, y: 200)
        for stop in ["dead-zone", "dead-zone-between-ticks", "release", "cancel", "reset"] {
            var gesture = ScrollGesture()
            gesture.begin(at: anchor, timestamp: 1)
            gesture.move(to: moved)
            for _ in 0..<60 { _ = gesture.scrollDelta(elapsed: 1.0 / 60) }
            switch stop {
            case "dead-zone", "dead-zone-between-ticks": gesture.move(to: anchor)
            case "release": _ = gesture.release(at: moved, timestamp: 2, targetIsValid: true)
            case "cancel": gesture.cancel()
            default: gesture.reset()
            }
            if stop != "dead-zone-between-ticks" {
                XCTAssertEqual(gesture.scrollDelta(elapsed: 1.0 / 60), .zero, stop)
            }
            if stop.hasPrefix("dead-zone") {
                // Also cover leaving the center again before the next output tick.
                gesture.move(to: moved)
            } else {
                gesture.reset()
                gesture.begin(at: anchor, timestamp: 3)
                gesture.move(to: moved)
            }
            var fresh = ScrollGesture()
            fresh.begin(at: anchor, timestamp: 3)
            fresh.move(to: moved)
            XCTAssertEqual(gesture.scrollDelta(elapsed: 1.0 / 60), fresh.scrollDelta(elapsed: 1.0 / 60), stop)
        }
    }

    func testPendingAndCancelledGesturesNeverEmitOrReplayScrolledClick() {
        var gesture = ScrollGesture()
        let anchor = ScrollPoint(x: 100, y: 100)
        gesture.begin(at: anchor, timestamp: 1)
        XCTAssertEqual(gesture.scrollDelta(elapsed: 1.0 / 60), .zero)
        XCTAssertEqual(gesture.release(at: anchor, timestamp: 1.1, targetIsValid: true), .replayClick)
        gesture.begin(at: anchor, timestamp: 2)
        gesture.move(to: ScrollPoint(x: 200, y: 200))
        _ = gesture.scrollDelta(elapsed: 1.0 / 60)
        gesture.cancel()
        gesture.move(to: ScrollPoint(x: 300, y: 300))
        XCTAssertEqual(gesture.scrollDelta(elapsed: 1.0 / 60), .zero)
        XCTAssertEqual(gesture.release(at: anchor, timestamp: 2.1, targetIsValid: true), .consumed)
    }
}
