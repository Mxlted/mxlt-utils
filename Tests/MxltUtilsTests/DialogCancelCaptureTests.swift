import AppKit
import ApplicationServices
import CallQuitsCore
import XCTest
@testable import MxltUtils

final class DialogCancelCaptureTests: XCTestCase {
    private final class Fixture {
        let pid: pid_t = 730_001
        let app = AXUIElementCreateApplication(730_001)
        // Model a remote panel as well as a button owned by its UI service. Ownership
        // comes from the original recipient's complete AXWindows list, not these PIDs.
        let dialog = AXUIElementCreateApplication(730_002)
        let cancel = AXUIElementCreateApplication(730_003)
        let other = AXUIElementCreateApplication(730_004)
        let sheet = AXUIElementCreateApplication(730_005)
        let child = AXUIElementCreateApplication(730_006)
        let splitGroup = AXUIElementCreateApplication(730_007)
        var attributes: [(AXUIElement, String, AXError, CFTypeRef?)] = []
        var hit: AXUIElement
        var readNames: [String] = []
        var beforeButtonRead: (() -> Void)?
        var windowOwner: pid_t? = 730_001
        var buttonOwner: pid_t? = 730_001
        let point = CGPoint(x: 110, y: 110)

        init() {
            hit = cancel
            set(app, kAXWindowsAttribute, [dialog] as NSArray)
            set(dialog, kAXRoleAttribute, kAXWindowRole as CFString)
            set(dialog, kAXSubroleAttribute, kAXDialogSubrole as CFString)
            set(dialog, kAXModalAttribute, kCFBooleanTrue)
            set(dialog, kAXMinimizedAttribute, kCFBooleanFalse)
            set(dialog, kAXChildrenAttribute, [] as NSArray)
            set(dialog, kAXCancelButtonAttribute, cancel)
            set(cancel, kAXRoleAttribute, kAXButtonRole as CFString)
            set(cancel, kAXEnabledAttribute, kCFBooleanTrue)
            set(cancel, kAXWindowAttribute, dialog)
            var origin = CGPoint(x: 100, y: 100)
            var size = CGSize(width: 80, height: 24)
            set(cancel, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)!)
            set(cancel, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
            set(sheet, kAXRoleAttribute, kAXSheetRole as CFString)
            set(child, kAXRoleAttribute, kAXStaticTextRole as CFString)
            set(child, kAXParentAttribute, cancel)
        }

        func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef?, error: AXError = .success) {
            attributes.removeAll { CFEqual($0.0, element) && $0.1 == name }
            attributes.append((element, name, error, value))
        }

        func read(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
            readNames.append(name)
            guard let entry = attributes.first(where: { CFEqual($0.0, element) && $0.1 == name })
            else { return (.attributeUnsupported, nil) }
            return (entry.2, entry.3)
        }

        func client() -> AccessibilityClient {
            AccessibilityClient(readAttribute: { [self] in read($0, $1 as String) }, readAttributes: { [self] element, names in
                if CFEqual(element, cancel) { beforeButtonRead?() }
                var values: [CFTypeRef] = []
                for name in names {
                    let (error, value) = read(element, name)
                    guard error == .success, let value else { return (error, nil) }
                    values.append(value)
                }
                return (.success, values)
            }, findElement: { [self] _, _ in (.success, hit) }, readProcessID: { [self] element in
                if CFEqual(element, dialog) { return windowOwner }
                if CFEqual(element, cancel) { return buttonOwner }
                return nil
            })
        }

        func capture(enabled: Bool = true, targetPID: pid_t? = nil, eventTime: TimeInterval? = nil,
                     at point: CGPoint? = nil, bundleIdentifier: String? = nil) -> AccessibilityClient.CloseControl? {
            client().captureCloseControl(at: point ?? self.point, eventTime: eventTime ?? ProcessInfo.processInfo.systemUptime,
                                         targetPID: targetPID ?? pid, includingDialogCancel: enabled,
                                         targetBundleIdentifier: bundleIdentifier)
        }

        func useTextEditChooser() {
            set(dialog, kAXSubroleAttribute, kAXStandardWindowSubrole as CFString)
            set(dialog, kAXIdentifierAttribute, "open-panel" as CFString)
            set(dialog, kAXModalAttribute, kCFBooleanFalse)
            set(dialog, kAXDocumentAttribute, nil, error: .noValue)
            set(dialog, kAXCancelButtonAttribute, nil, error: .noValue)
            set(dialog, kAXChildrenAttribute, [splitGroup] as NSArray)
            set(splitGroup, kAXRoleAttribute, kAXSplitGroupRole as CFString)
            set(splitGroup, kAXParentAttribute, dialog)
            set(splitGroup, kAXChildrenAttribute, [cancel] as NSArray)
            set(splitGroup, kAXWindowAttribute, nil, error: .noValue)
            set(cancel, kAXIdentifierAttribute, "CancelButton" as CFString)
            set(cancel, kAXWindowAttribute, nil, error: .noValue)
            set(cancel, kAXParentAttribute, splitGroup)
        }

        func snapshot() -> CloseSnapshot {
            client().snapshot(for: AccessibilityClient.Hit(application: .current, appElement: app, window: dialog,
                                                          initialWindows: [dialog], buttonFrame: .zero,
                                                          allowsApplicationHide: false, trigger: .dialogCancel))
        }
    }

    func testOfficialCancelCapturesRemoteOwnedLoneDialogAndChildHitWithoutLabels() throws {
        for childHit in [false, true] {
            let fixture = Fixture()
            if childHit { fixture.hit = fixture.child }
            let control = try XCTUnwrap(fixture.capture())
            XCTAssertEqual(control.trigger, .dialogCancel)
            XCTAssertTrue(CFEqual(control.appElement, fixture.app))
            XCTAssertTrue(CFEqual(control.window, fixture.dialog))
            XCTAssertEqual(control.initialWindows.count, 1)
            XCTAssertFalse(fixture.readNames.contains(kAXTitleAttribute))
            XCTAssertFalse(fixture.readNames.contains(kAXDescriptionAttribute))
        }
    }

    func testObservedTextEditChooserResolvesCancelThroughNativeAncestryWithoutOfficialAttributes() throws {
        for childHit in [false, true] {
            let fixture = Fixture()
            fixture.useTextEditChooser()
            if childHit { fixture.hit = fixture.child }
            let control = try XCTUnwrap(fixture.capture(bundleIdentifier: "com.apple.TextEdit"))
            XCTAssertEqual(control.trigger, .dialogCancel)
            XCTAssertTrue(CFEqual(control.window, fixture.dialog))
            XCTAssertEqual(control.initialWindows.count, 1)
            XCTAssertFalse(fixture.readNames.contains(kAXTitleAttribute))
            XCTAssertFalse(fixture.readNames.contains(kAXDescriptionAttribute))
            var session = CloseSession(behavior: control.trigger.behavior(configured: .everyWindow), startedAt: 0)
            XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0), .wait)
            fixture.set(fixture.app, kAXWindowsAttribute, [] as NSArray)
            XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0.1), .wait)
            XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0.3), .quit)
        }
    }

    func testTextEditChooserIdentifiersCannotAuthorizeOtherAppsOrUnsupportedAncestry() {
        let fixture = Fixture()
        fixture.useTextEditChooser()
        for bundleID: String? in [nil, "com.apple.Preview", "com.example.fixture"] {
            XCTAssertNil(fixture.capture(bundleIdentifier: bundleID))
        }
        let cases: [(String, (Fixture) -> Void)] = [
            ("wrong window identifier", { $0.set($0.dialog, kAXIdentifierAttribute, "save-panel" as CFString) }),
            ("wrong button identifier", { $0.set($0.cancel, kAXIdentifierAttribute, "OKButton" as CFString) }),
            ("unreadable identifier", { $0.set($0.cancel, kAXIdentifierAttribute, nil, error: .cannotComplete) }),
            ("web ancestry", { $0.set($0.splitGroup, kAXRoleAttribute, "AXWebArea" as CFString) }),
            ("unlisted group", { $0.set($0.dialog, kAXChildrenAttribute, [] as NSArray) }),
            ("unlisted button", { $0.set($0.splitGroup, kAXChildrenAttribute, [] as NSArray) }),
            ("duplicate button", { $0.set($0.splitGroup, kAXChildrenAttribute, [$0.cancel, $0.cancel] as NSArray) }),
            ("conflicting button window", { $0.set($0.cancel, kAXWindowAttribute, $0.other) }),
            ("malformed group window", { $0.set($0.splitGroup, kAXWindowAttribute, "invalid" as CFString) }),
            ("conflicting official cancel", { $0.set($0.dialog, kAXCancelButtonAttribute, $0.other) }),
            ("wrong window owner", { $0.windowOwner = 730_010 }),
            ("unknown button owner", { $0.buttonOwner = nil }),
            ("wrong button owner", { $0.buttonOwner = 730_010 }),
            ("another document window", { $0.set($0.app, kAXWindowsAttribute, [$0.dialog, $0.other] as NSArray) }),
            ("unreadable windows", { $0.set($0.app, kAXWindowsAttribute, nil, error: .cannotComplete) }),
            ("sheet", { $0.set($0.dialog, kAXChildrenAttribute, [$0.splitGroup, $0.sheet] as NSArray) }),
            ("document present", { $0.set($0.dialog, kAXDocumentAttribute, "fixture-document" as CFString) }),
            ("modal window", { $0.set($0.dialog, kAXModalAttribute, kCFBooleanTrue) }),
            ("minimized", { $0.set($0.dialog, kAXMinimizedAttribute, kCFBooleanTrue) }),
            ("disabled cancel", { $0.set($0.cancel, kAXEnabledAttribute, kCFBooleanFalse) })
        ]
        for (reason, mutate) in cases {
            let invalid = Fixture()
            invalid.useTextEditChooser()
            mutate(invalid)
            XCTAssertNil(invalid.capture(bundleIdentifier: "com.apple.TextEdit"), reason)
        }
    }

    func testCancelPreservesInitialMembershipWhenDialogDisappearsDuringFinalRead() throws {
        let fixture = Fixture()
        fixture.beforeButtonRead = { fixture.set(fixture.app, kAXWindowsAttribute, [] as NSArray) }
        XCTAssertEqual(try XCTUnwrap(fixture.capture()).initialWindows.count, 1)
    }

    func testCancelRejectsRemainingWindowsSheetsDocumentsUnrelatedControlsAndUnknownState() {
        let cases: [(String, (Fixture) -> Void)] = [
            ("another window, including minimized or off-Space", { $0.set($0.app, kAXWindowsAttribute, [$0.dialog, $0.other] as NSArray) }),
            ("no initial window", { $0.set($0.app, kAXWindowsAttribute, [] as NSArray) }),
            ("window outside recipient membership", { $0.set($0.app, kAXWindowsAttribute, [$0.other] as NSArray) }),
            ("malformed list", { $0.set($0.app, kAXWindowsAttribute, ["invalid"] as NSArray) }),
            ("save sheet", { $0.set($0.dialog, kAXChildrenAttribute, [$0.sheet] as NSArray) }),
            ("sheet instead of window", { $0.set($0.dialog, kAXRoleAttribute, kAXSheetRole as CFString) }),
            ("document window", { $0.set($0.dialog, kAXSubroleAttribute, kAXStandardWindowSubrole as CFString) }),
            ("document-bearing dialog", { $0.set($0.dialog, kAXDocumentAttribute, "fixture-document" as CFString) }),
            ("minimized dialog", { $0.set($0.dialog, kAXMinimizedAttribute, kCFBooleanTrue) }),
            ("nonofficial cancel", { $0.set($0.dialog, kAXCancelButtonAttribute, $0.other) }),
            ("malformed cancel", { $0.set($0.dialog, kAXCancelButtonAttribute, "Cancel" as CFString) }),
            ("disabled cancel", { $0.set($0.cancel, kAXEnabledAttribute, kCFBooleanFalse) }),
            ("unreadable windows", { $0.set($0.app, kAXWindowsAttribute, nil, error: .cannotComplete) }),
            ("unknown modal state", { $0.set($0.dialog, kAXModalAttribute, nil, error: .attributeUnsupported) }),
            ("malformed children", { $0.set($0.dialog, kAXChildrenAttribute, "invalid" as CFString) }),
            ("invalid frame", { $0.set($0.cancel, kAXPositionAttribute, "invalid" as CFString) })
        ]
        for (reason, mutate) in cases {
            let fixture = Fixture()
            mutate(fixture)
            XCTAssertNil(fixture.capture(), reason)
        }
        let fixture = Fixture()
        XCTAssertNil(fixture.capture(enabled: false))
        XCTAssertNil(fixture.capture(targetPID: 730_007))
        XCTAssertNil(fixture.capture(eventTime: ProcessInfo.processInfo.systemUptime - 1))
        XCTAssertNil(fixture.capture(at: CGPoint(x: 200, y: 200)))
    }

    func testModalCancelWaitsForDisappearanceAndStableEmptyConfirmation() {
        let fixture = Fixture()
        var session = CloseSession(behavior: CloseTrigger.dialogCancel.behavior(configured: .everyWindow), startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0), .wait)
        fixture.set(fixture.app, kAXWindowsAttribute, [] as NSArray)
        XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0.1), .wait)
        XCTAssertEqual(session.evaluate(snapshot: fixture.snapshot(), now: 0.3), .quit)
    }

    func testCancelNeverQuitsIfDialogStaysOrSheetReplacementOrUnreadableStateAppears() {
        let staying = Fixture()
        var session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: staying.snapshot(), now: 0), .wait)
        XCTAssertEqual(session.evaluate(snapshot: staying.snapshot(), now: 3), .cancel(.expired))

        let sheet = Fixture()
        sheet.set(sheet.dialog, kAXChildrenAttribute, [sheet.sheet] as NSArray)
        XCTAssertTrue(sheet.snapshot().hasBlockingUI)

        let replacement = Fixture()
        replacement.set(replacement.app, kAXWindowsAttribute, [replacement.other] as NSArray)
        replacement.set(replacement.other, kAXModalAttribute, kCFBooleanFalse)
        replacement.set(replacement.other, kAXChildrenAttribute, [] as NSArray)
        session = CloseSession(behavior: .lastWindow, startedAt: 0)
        XCTAssertEqual(session.evaluate(snapshot: replacement.snapshot(), now: 0), .cancel(.replacementWindow))

        let unreadable = Fixture()
        unreadable.set(unreadable.app, kAXWindowsAttribute, nil, error: .cannotComplete)
        XCTAssertFalse(unreadable.snapshot().isReliable)
    }
}
