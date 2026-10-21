// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import Foundation

/// Baseline protection shared by graceful and force quit.
///
/// The integration must additionally require a regular, running user application and apply the
/// user's exclusions. Unknown identities fail closed instead of guessing that an app is safe.
public enum AppProtection {
    /// Apply the same application-state gate before AX work and immediately before either quit path.
    public static func isEligible(
        bundleIdentifier: String?, processID: Int32, ownProcessID: Int32,
        isTerminated: Bool, isHidden: Bool, isRegular: Bool,
        isFinishedLaunching: Bool, isExcluded: Bool,
        allowsVerifiedHiddenClose: Bool = false
    ) -> Bool {
        let allowsHidden = allowsVerifiedHiddenClose && HiddenCloseIntent.supports(bundleIdentifier: bundleIdentifier)
        return !isTerminated && (!isHidden || allowsHidden) && isRegular && isFinishedLaunching && !isExcluded &&
        !isProtected(bundleIdentifier: bundleIdentifier, processID: processID, ownProcessID: ownProcessID)
    }

    private static let protectedBundleIdentifiers: Set<String> = [
        "com.mxlted.mxlt-utils",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.windowmanager",
        "com.apple.windowserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.spotlight",
        "com.apple.securityagent",
        "com.apple.authorizationhost",
        "com.apple.coreservices.uiagent",
        "com.apple.universalaccesscontrol",
        "com.apple.voiceover",
        "com.apple.textinputmenuagent",
        "com.apple.screencaptureui"
    ]

    public static func isProtected(
        bundleIdentifier: String?,
        processID: Int32,
        ownProcessID: Int32
    ) -> Bool {
        guard processID > 1, processID != ownProcessID,
              let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return true
        }
        // Bundle identifiers are case-insensitive. Reject malformed whitespace rather than
        // accidentally treating a malformed system identifier as an ordinary application.
        guard bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.contains(where: { $0.isWhitespace })
        else {
            return true
        }
        return protectedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }
}
