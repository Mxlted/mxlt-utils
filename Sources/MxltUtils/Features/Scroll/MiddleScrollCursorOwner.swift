import CoreGraphics
import Darwin
import Foundation

/// Resolve cursor owners off the input callback. A window name or level alone
/// cannot authorize bypassing coverage checks for a foreign process.
enum MiddleScrollCursorOwner {
    static func verifiedProcessID(in windows: [[String: Any]]) -> pid_t? {
        let owners = Set(windows.compactMap { window -> pid_t? in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.int64Value == Int64(CGWindowLevelForKey(.cursorWindow)),
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int64Value > 1, owner.int64Value <= Int64(Int32.max) else { return nil }
            return owner.int32Value
        })
        for owner in owners {
            // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; Swift cannot import its macro.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(owner, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            // Both spellings identify Apple's protected system executable. This
            // inspects its path through public libproc; no private API is called.
            if path == "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
                || path == "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer" {
                return owner
            }
        }
        return nil
    }
}
