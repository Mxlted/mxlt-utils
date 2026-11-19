import XCTest
@testable import MxltUtils

final class AppExceptionTests: XCTestCase {
    func testMenuRequiresAnIdentifiableExternalAppAndRespectsQuitProtection() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherPID: pid_t = ownPID == 42 ? 43 : 42
        XCTAssertNil(MenuApplication(nil))
        XCTAssertNil(MenuApplication(bundleID: "example.editor", name: "Editor", processID: ownPID))
        XCTAssertNil(MenuApplication(bundleID: nil, name: "Unknown", processID: otherPID))
        XCTAssertNil(MenuApplication(bundleID: "   ", name: "Unknown", processID: otherPID))
        let finder = try XCTUnwrap(MenuApplication(bundleID: "com.apple.finder", name: "Finder", processID: otherPID))
        XCTAssertTrue(finder.protectedFromQuit)
        XCTAssertEqual(finder.exception.name, "Finder")
        let editor = try XCTUnwrap(MenuApplication(bundleID: "example.editor", name: nil, processID: otherPID))
        XCTAssertFalse(editor.protectedFromQuit)
        XCTAssertEqual(editor.exception.name, "example.editor")
    }

    @MainActor
    func testMenuAdditionsPersistIndependentlyAndMatchExistingPickerEntries() async {
        let suite = "MxltUtilsMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func makeQuit() -> QuitModel {
            QuitModel(defaults: defaults, readAccessibility: { false }, readLoginStatus: { .notRegistered })
        }
        let quit = makeQuit()
        let scroll = ScrollModel(defaults: defaults)
        let editor = AppException(bundleID: "com.example.Editor", name: "Editor")
        let duplicate = AppException(bundleID: "com.example.editor", name: "Renamed Editor")
        let viewer = AppException(bundleID: "com.example.Viewer", name: "Viewer")
        quit.exclusions = [viewer]
        var configurationChanges = 0
        quit.onConfigurationChange = { configurationChanges += 1 }
        quit.exclusions.addApplications([editor, duplicate])
        quit.exclusions.addApplications([duplicate])
        XCTAssertEqual(configurationChanges, 1)
        XCTAssertEqual(quit.exclusions, [editor, viewer])
        XCTAssertTrue(quit.isExcluded(duplicate.bundleID))
        XCTAssertFalse(scroll.exclusions.contains(bundleID: editor.bundleID))
        scroll.exclusions.addApplications([editor])
        quit.exclusions.removeAll { $0 == editor }
        XCTAssertEqual(makeQuit().exclusions, [viewer])
        XCTAssertTrue(ScrollModel(defaults: defaults).exclusions.contains(bundleID: duplicate.bundleID))
        XCTAssertFalse(quit.enabled)
        XCTAssertFalse(scroll.enabled)
    }
}
