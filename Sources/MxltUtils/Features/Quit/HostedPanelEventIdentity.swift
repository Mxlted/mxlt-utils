import Foundation
import CallQuitsCore

/// AppKit sends open-panel input to its system XPC service while WindowServer retains
/// the host application's window ownership. This exception only admits a candidate;
/// a verified TextEdit Cancel control and the normal graceful confirmation remain mandatory.
struct HostedPanelEventIdentity {
    static let serviceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"
    static let serviceExecutable = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/" +
        serviceBundleID + ".xpc/Contents/MacOS/" + serviceBundleID

    let host: EventIdentity
    private let recipientProcessID: Int64

    init?(nativeProcessID: Int64, eventWindowID: Int64, windowOwnerProcessID: Int64?,
          ownerBundleIdentifier: String?, recipientBundleIdentifier: String?, recipientExecutable: String?) {
        guard nativeProcessID > 1, nativeProcessID <= Int64(Int32.max), eventWindowID > 0,
              ownerBundleIdentifier == "com.apple.TextEdit",
              recipientBundleIdentifier == Self.serviceBundleID,
              recipientExecutable == Self.serviceExecutable,
              let owner = windowOwnerProcessID, owner != nativeProcessID,
              let host = EventIdentity(nativeProcessID: 0, eventWindowID: eventWindowID, windowOwnerProcessID: owner)
        else { return nil }
        self.host = host
        recipientProcessID = nativeProcessID
    }

    func matchesRelease(nativeProcessID: Int64, eventWindowID: Int64, windowOwnerProcessID: Int64?) -> Bool {
        // Require both the same service process and the same stamped window, even if
        // dismissal has already removed the window from WindowServer's owner lookup.
        nativeProcessID == recipientProcessID && host.windowID.map { Int64($0) == eventWindowID } == true &&
        host.matchesRelease(nativeProcessID: 0, eventWindowID: eventWindowID, windowOwnerProcessID: windowOwnerProcessID)
    }
}
