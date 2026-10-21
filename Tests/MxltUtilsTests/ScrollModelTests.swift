import XCTest
import MxltCore
@testable import MxltUtils

final class ScrollModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "MxltUtilsScrollTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testNewProfileIsOptInWithSensibleSettings() async {
        let model = ScrollModel(defaults: makeDefaults())
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(model.settings, ScrollSettings())
        XCTAssertTrue(model.smooth)
        XCTAssertEqual(model.status, "Off")
        XCTAssertTrue(model.exclusions.contains { $0.bundleID == "org.blenderfoundation.blender" })
    }

    @MainActor
    func testDisablePreservesSettingsAndExceptionsAcrossRelaunch() async {
        let defaults = makeDefaults()
        let model = ScrollModel(defaults: defaults)
        model.enabled = true
        model.sensitivity = 2.1
        model.deadZone = 17
        model.reversed = true
        model.smooth = false
        model.exclusions = [AppException(bundleID: "example.cad", name: "CAD")]
        model.enabled = false
        let restored = ScrollModel(defaults: defaults)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.settings, ScrollSettings(sensitivity: 2.1, deadZone: 17, reversed: true, smooth: false))
        XCTAssertEqual(restored.exclusions, model.exclusions)
        restored.enabled = true
        XCTAssertEqual(restored.settings, model.settings)
    }

    @MainActor
    func testNonfinitePersistedSettingsAreRepairedBeforeUIReadsThem() async {
        for value in [Double.nan, .infinity, -.infinity] {
            let defaults = makeDefaults()
            defaults.set(value, forKey: "scroll.sensitivity")
            defaults.set(value, forKey: "scroll.deadZone")
            let model = ScrollModel(defaults: defaults)
            XCTAssertEqual(model.sensitivity, 1)
            XCTAssertEqual(model.deadZone, 8)
            XCTAssertTrue(defaults.double(forKey: "scroll.sensitivity").isFinite)
            XCTAssertTrue(defaults.double(forKey: "scroll.deadZone").isFinite)
        }
    }

    @MainActor
    func testOutOfRangePersistedSettingsAreClampedForUIAndGesture() async {
        for (input, sensitivity, deadZone) in [(-100.0, 0.2, 2.0), (1_000.0, 3.0, 40.0)] {
            let defaults = makeDefaults()
            defaults.set(input, forKey: "scroll.sensitivity")
            defaults.set(input, forKey: "scroll.deadZone")
            let model = ScrollModel(defaults: defaults)
            XCTAssertEqual(model.sensitivity, sensitivity)
            XCTAssertEqual(model.deadZone, deadZone)
            XCTAssertEqual(model.settings.sensitivity, model.sensitivity)
            XCTAssertEqual(model.settings.deadZone, model.deadZone)
            XCTAssertEqual(defaults.double(forKey: "scroll.sensitivity"), sensitivity)
            XCTAssertEqual(defaults.double(forKey: "scroll.deadZone"), deadZone)
        }
    }

    @MainActor
    func testRuntimeSettingChangesCannotPersistInvalidNumbers() async {
        let defaults = makeDefaults()
        let model = ScrollModel(defaults: defaults)
        model.sensitivity = .nan
        model.deadZone = .infinity
        XCTAssertEqual(model.sensitivity, 1)
        XCTAssertEqual(model.deadZone, 8)
        model.sensitivity = 50
        model.deadZone = -50
        XCTAssertEqual(model.sensitivity, 3)
        XCTAssertEqual(model.deadZone, 2)
        XCTAssertEqual(defaults.double(forKey: "scroll.sensitivity"), 3)
        XCTAssertEqual(defaults.double(forKey: "scroll.deadZone"), 2)
    }

    @MainActor
    func testCorruptExceptionDataFallsBackButDeliberatelyEmptyListPersists() async {
        let defaults = makeDefaults()
        defaults.set(Data("not JSON".utf8), forKey: "scroll.exclusions")
        let model = ScrollModel(defaults: defaults)
        XCTAssertTrue(model.exclusions.contains { $0.bundleID == "org.blenderfoundation.blender" })
        model.exclusions = []
        XCTAssertEqual(ScrollModel(defaults: defaults).exclusions, [])
    }

    @MainActor
    func testScrollPreferencesDoNotAdoptOrChangeCallQuitsKeys() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "enabled")
        defaults.set(true, forKey: "quit.enabled")
        defaults.set(true, forKey: "forceQuitEnabled")
        defaults.set(true, forKey: "quit.forceQuitEnabled")
        let model = ScrollModel(defaults: defaults)
        XCTAssertFalse(model.enabled)
        model.enabled = true
        model.enabled = false
        XCTAssertTrue(defaults.bool(forKey: "enabled"))
        XCTAssertTrue(defaults.bool(forKey: "quit.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "forceQuitEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "quit.forceQuitEnabled"))
    }

    @MainActor
    func testSessionStatusIsNotRestoredAsConfiguration() async {
        let defaults = makeDefaults()
        let model = ScrollModel(defaults: defaults)
        model.status = "Paused"
        XCTAssertEqual(ScrollModel(defaults: defaults).status, "Off")
    }
}
