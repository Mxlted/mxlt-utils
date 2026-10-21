import XCTest
@testable import MxltCore

final class ScrollFrameClockTests: XCTestCase {
    func testTravelUsesAcceptedFramesAcrossSkippedValidationTicks() {
        var clock = ScrollFrameClock()
        var motion = ScrollMotion()
        var travel: Int32 = 0
        var elapsedTotal = 0.0
        // 120 Hz callbacks, with one validation spanning three callbacks.
        for timestamp in [0.0, 1.0 / 120, 4.0 / 120, 5.0 / 120] {
            let elapsed = clock.advance(at: timestamp, initialInterval: 1.0 / 120)
            elapsedTotal += elapsed
            travel += motion.step(toward: ScrollVelocity(x: 1200, y: 0), elapsed: elapsed, smooth: false).x
        }
        XCTAssertEqual(elapsedTotal, 6.0 / 120, accuracy: 1e-12)
        // Whole-point output may retain just under one point for the next frame.
        XCTAssertEqual(Double(travel), 60, accuracy: 1)
    }

    func testLongValidationGapIsCappedWithoutASecondCatchUpFrame() {
        var clock = ScrollFrameClock()
        _ = clock.advance(at: 1, initialInterval: 1.0 / 120)
        XCTAssertEqual(clock.advance(at: 6, initialInterval: 1.0 / 120), 1.0 / 30)
        XCTAssertEqual(clock.advance(at: 6 + 1.0 / 120, initialInterval: 1.0 / 120), 1.0 / 120, accuracy: 1e-12)
    }

    func testResetDiscardsTimeSpentStopped() {
        var clock = ScrollFrameClock()
        _ = clock.advance(at: 1, initialInterval: 1.0 / 60)
        clock.reset()
        XCTAssertEqual(clock.advance(at: 30, initialInterval: 1.0 / 144), 1.0 / 144)
    }

    func testInvalidClockSamplesCannotGenerateTravel() {
        var clock = ScrollFrameClock()
        for timestamp in [Double.nan, .infinity, -1] {
            XCTAssertEqual(clock.advance(at: timestamp, initialInterval: 1.0 / 60), 0)
        }
        for interval in [Double.nan, .infinity, -1, 0] {
            XCTAssertEqual(clock.advance(at: 1, initialInterval: interval), 0)
        }
        XCTAssertEqual(clock.advance(at: 2, initialInterval: 1.0 / 60), 1.0 / 60)
        XCTAssertEqual(clock.advance(at: 2, initialInterval: 1.0 / 60), 0)
        XCTAssertEqual(clock.advance(at: 1, initialInterval: 1.0 / 60), 0)
    }
}
