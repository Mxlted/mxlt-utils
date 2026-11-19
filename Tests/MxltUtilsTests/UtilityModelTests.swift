import MxltCore
import XCTest
@testable import MxltUtils

@MainActor
private final class TestScrollService: MiddleScrollService {
    var canStart = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var immediateStops = 0
    private(set) var currentExclusions: Set<String> = []
    private(set) var readSettings: (() -> ScrollSettings)?

    override func start(readSettings: @escaping () -> ScrollSettings, exclusions: Set<String>) -> Bool {
        starts += 1
        self.readSettings = readSettings
        currentExclusions = exclusions
        return canStart
    }

    override func updateExclusions(_ exclusions: Set<String>) { currentExclusions = exclusions }
    override func stop() { stops += 1 }
    override func stopImmediately() { immediateStops += 1 }
}

final class UtilityModelTests: XCTestCase {
    @MainActor
    private func makeModel(_ service: TestScrollService, trusted: @escaping () -> Bool = { true }) -> UtilityModel {
        let suite = "MxltUtilsCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let quit = QuitModel(defaults: defaults, readAccessibility: trusted, readLoginStatus: { .notRegistered })
        return UtilityModel(defaults: defaults, quit: quit, scrollService: service)
    }

    @MainActor
    func testReenablingFailedScrollingMakesOneFreshStartAttempt() async {
        let service = TestScrollService()
        let model = makeModel(service)
        model.start()
        defer { model.stop() }
        model.scroll.enabled = true
        XCTAssertEqual(model.status, "Some features need attention")
        XCTAssertEqual(service.starts, 1)
        model.refresh()
        XCTAssertEqual(service.starts, 1)

        model.scroll.enabled = false
        XCTAssertEqual(model.scroll.status, "Off")
        // Read the menu summary with only Quit on Close selected. Its native tap
        // is installed on the next run-loop turn and is unnecessary in this fixture.
        model.quit.enabled = true
        XCTAssertEqual(model.status, "Ready")
        model.quit.enabled = false

        service.canStart = true
        model.scroll.enabled = true
        model.refresh()
        XCTAssertEqual(service.starts, 2)
        XCTAssertEqual(model.status, "Ready")
    }

    @MainActor
    func testExplicitRetryIsScopedToFailedMonitoring() async {
        let service = TestScrollService()
        let model = makeModel(service)
        model.start()
        defer { model.stop() }
        model.scroll.enabled = true
        service.canStart = true
        model.retry()
        XCTAssertEqual(service.starts, 2)
        let stops = service.stops
        model.retry()
        XCTAssertEqual(model.status, "Ready")
        XCTAssertEqual(service.starts, 2)
        XCTAssertEqual(service.stops, stops)
        XCTAssertEqual(service.immediateStops, 0)
    }

    @MainActor
    func testFailureAfterStartupWaitsForRetryAndADisabledDrainCannotReportFailure() async {
        let service = TestScrollService()
        service.canStart = true
        let model = makeModel(service)
        model.start()
        defer { model.stop() }
        model.scroll.enabled = true
        service.onFailure?()
        model.refresh()
        XCTAssertEqual(model.status, "Some features need attention")
        XCTAssertEqual(service.starts, 1)
        model.scroll.enabled = false
        service.onFailure?()
        XCTAssertEqual(model.scroll.status, "Off")
        model.scroll.enabled = true
        XCTAssertEqual(service.starts, 2)
        XCTAssertEqual(model.status, "Ready")
    }

    @MainActor
    func testEnableChecksCurrentTrustAndWaitsForPermissionAndResume() async {
        var trusted = true
        let service = TestScrollService()
        service.canStart = true
        let model = makeModel(service, trusted: { trusted })
        model.start()
        defer { model.stop() }
        trusted = false
        model.scroll.enabled = true
        XCTAssertEqual(service.starts, 0)
        XCTAssertEqual(model.scroll.status, "Accessibility access needed")
        model.paused = true
        trusted = true
        model.refresh()
        XCTAssertEqual(model.scroll.status, "Paused")
        XCTAssertEqual(service.starts, 0)
        model.paused = false
        XCTAssertEqual(service.starts, 1)
        XCTAssertEqual(model.status, "Ready")
    }

    @MainActor
    func testSettingsApplyOnNextPressAndExclusionsUpdateWithoutRestarting() async throws {
        let service = TestScrollService()
        service.canStart = true
        let model = makeModel(service)
        model.start()
        defer { model.stop() }
        model.scroll.enabled = true
        let readSettings = try XCTUnwrap(service.readSettings)
        let anchor = ScrollPoint(x: 0, y: 0)
        var gesture = ScrollGesture()
        XCTAssertTrue(gesture.begin(at: anchor, timestamp: 1, settings: readSettings()))
        for speed in [1.2, 1.4, 1.6] {
            model.scroll.sensitivity = speed
            model.refresh()
        }
        model.scroll.deadZone = 20
        model.scroll.reversed = true
        model.scroll.smooth = false
        XCTAssertEqual(gesture.settings, ScrollSettings())
        XCTAssertTrue(gesture.move(to: ScrollPoint(x: 12, y: 0)))
        _ = gesture.release(at: anchor, timestamp: 1.3, targetIsValid: true)
        XCTAssertTrue(gesture.begin(at: anchor, timestamp: 2, settings: readSettings()))
        XCTAssertEqual(gesture.settings, ScrollSettings(sensitivity: 1.6, deadZone: 20, reversed: true, smooth: false))
        XCTAssertFalse(gesture.move(to: ScrollPoint(x: 12, y: 0)))
        XCTAssertTrue(gesture.move(to: ScrollPoint(x: 25, y: 0)))
        XCTAssertLessThan(gesture.velocity.x, 0)

        model.scroll.exclusions = [AppException(bundleID: "example.CAD", name: "CAD")]
        XCTAssertEqual(service.currentExclusions, ["example.cad"])
        XCTAssertEqual(service.starts, 1)
        XCTAssertEqual(service.stops, 0)
        XCTAssertEqual(service.immediateStops, 0)
    }
}
