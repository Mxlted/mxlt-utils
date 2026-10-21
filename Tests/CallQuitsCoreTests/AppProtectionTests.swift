// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import XCTest
@testable import CallQuitsCore

final class AppProtectionTests: XCTestCase {
    func testProtectsFinderAndSystemInterfacesCaseInsensitively() {
        let identifiers = [
            "com.apple.finder", "com.apple.dock", "com.apple.SystemUIServer",
            "com.apple.loginwindow", "com.apple.WindowManager", "com.apple.WindowServer",
            "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
            "com.apple.SecurityAgent", "com.apple.authorizationhost", "com.apple.coreservices.uiagent",
            "com.apple.universalaccesscontrol", "com.apple.VoiceOver", "com.apple.TextInputMenuAgent",
            "com.apple.screencaptureui"
        ]
        for identifier in identifiers {
            XCTAssertTrue(AppProtection.isProtected(bundleIdentifier: identifier, processID: 42, ownProcessID: 99),
                          "protected bundle identifier=\(identifier)")
            XCTAssertTrue(AppProtection.isProtected(bundleIdentifier: identifier.uppercased(), processID: 42, ownProcessID: 99),
                          "uppercase protected bundle identifier=\(identifier.uppercased())")
        }
    }

    func testProtectsSelfAndReservedProcessIDs() {
        for processID: Int32 in [-1, 0, 1, 99] {
            XCTAssertTrue(AppProtection.isProtected(bundleIdentifier: "example.app", processID: processID, ownProcessID: 99),
                          "target PID=\(processID), own PID=99")
        }
    }

    func testProtectsMxltUtilsByIdentityEvenWhenAnotherCopyIsRunning() {
        for identifier in ["com.mxlted.mxlt-utils", "COM.MXLTED.MXLT-UTILS"] {
            XCTAssertTrue(AppProtection.isProtected(bundleIdentifier: identifier,
                                                    processID: 42, ownProcessID: 99))
            XCTAssertFalse(AppProtection.isEligible(bundleIdentifier: identifier,
                                                    processID: 42, ownProcessID: 99,
                                                    isTerminated: false, isHidden: false,
                                                    isRegular: true, isFinishedLaunching: true,
                                                    isExcluded: false))
        }
    }

    func testUnknownOrMalformedIdentityFailsClosed() {
        for identifier: String? in [nil, "", " ", "\n", " com.apple.finder", "com.apple.finder ", "example. app"] {
            XCTAssertTrue(AppProtection.isProtected(bundleIdentifier: identifier, processID: 42, ownProcessID: 99),
                          "bundle identifier=\(String(reflecting: identifier))")
        }
    }

    func testAllowsRegularUserAppIdentitiesWithoutExcludingAllAppleApps() {
        for identifier in ["com.apple.TextEdit", "com.apple.Safari", "com.example.fixture", "org.mozilla.firefox"] {
            XCTAssertFalse(AppProtection.isProtected(bundleIdentifier: identifier, processID: 42, ownProcessID: 99),
                           "allowed bundle identifier=\(identifier)")
        }
    }
}
