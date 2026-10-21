// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import XCTest
@testable import CallQuitsCore

final class AppEligibilityTests: XCTestCase {
    func testEachApplicationStateCanIndependentlyPreventAXWorkAndQuit() {
        let cases: [(name: String, terminated: Bool, hidden: Bool, regular: Bool, launched: Bool, excluded: Bool, expected: Bool)] = [
            ("eligible", false, false, true, true, false, true),
            ("terminated", true, false, true, true, false, false),
            ("hidden", false, true, true, true, false, false),
            ("nonregular", false, false, false, true, false, false),
            ("unfinished launch", false, false, true, false, false, false),
            ("excluded", false, false, true, true, true, false)
        ]
        for item in cases {
            XCTAssertEqual(AppProtection.isEligible(
                bundleIdentifier: "example.fixture", processID: 42, ownProcessID: 99,
                isTerminated: item.terminated, isHidden: item.hidden, isRegular: item.regular,
                isFinishedLaunching: item.launched, isExcluded: item.excluded
            ), item.expected, "application state=\(item.name)")
        }
    }

    func testOtherwiseEligibleApplicationStillRequiresUnprotectedIdentity() {
        let cases: [(name: String, bundleID: String?, pid: Int32)] = [
            ("Finder", "com.apple.finder", 42),
            ("self", "example.fixture", 99),
            ("reserved PID", "example.fixture", 1),
            ("unknown bundle", nil, 42)
        ]
        for item in cases {
            XCTAssertFalse(AppProtection.isEligible(
                bundleIdentifier: item.bundleID, processID: item.pid, ownProcessID: 99,
                isTerminated: false, isHidden: false, isRegular: true,
                isFinishedLaunching: true, isExcluded: false
            ), "identity boundary=\(item.name), pid=\(item.pid), bundle=\(String(describing: item.bundleID))")
        }
    }

    func testHiddenDiscordRequiresExplicitVerifiedCloseAllowance() {
        for allowed in [false, true] {
            XCTAssertEqual(AppProtection.isEligible(
                bundleIdentifier: "com.hnc.Discord", processID: 42, ownProcessID: 99,
                isTerminated: false, isHidden: true, isRegular: true,
                isFinishedLaunching: true, isExcluded: false,
                allowsVerifiedHiddenClose: allowed
            ), allowed)
        }
    }

    func testHiddenAllowanceKeepsAllOtherApplicationGuards() {
        let cases: [(String, Bool, Bool, Bool, Bool)] = [
            ("terminated", true, true, true, false),
            ("nonregular", false, false, true, false),
            ("unfinished launch", false, true, false, false),
            ("excluded", false, true, true, true)
        ]
        for (name, terminated, regular, launched, excluded) in cases {
            XCTAssertFalse(AppProtection.isEligible(
                bundleIdentifier: "com.hnc.Discord", processID: 42, ownProcessID: 99,
                isTerminated: terminated, isHidden: true, isRegular: regular,
                isFinishedLaunching: launched, isExcluded: excluded,
                allowsVerifiedHiddenClose: true
            ), "hidden close must preserve the \(name) guard")
        }
    }

    func testHiddenAllowanceCannotBypassIdentityOrBroadenSupportedApps() {
        let cases: [(String?, Int32)] = [
            ("com.hnc.Discord", 99),
            ("com.hnc.Discord", 1),
            ("com.hnc.Discord", 0),
            ("com.hnc.Discord", -1),
            ("com.apple.finder", 42),
            ("example.fixture", 42),
            ("com.hnc.DiscordCanary", 42),
            ("COM.HNC.DISCORD", 42),
            (" com.hnc.Discord", 42),
            (nil, 42),
            ("", 42)
        ]
        for (bundle, pid) in cases {
            XCTAssertFalse(AppProtection.isEligible(
                bundleIdentifier: bundle, processID: pid, ownProcessID: 99,
                isTerminated: false, isHidden: true, isRegular: true,
                isFinishedLaunching: true, isExcluded: false,
                allowsVerifiedHiddenClose: true
            ), "bundle=\(String(describing: bundle)), pid=\(pid)")
        }
    }
}
