import Darwin
import Foundation

/// Resolve cursor owners off the input callback. A window name or level alone
/// cannot authorize bypassing coverage checks for a foreign process.
enum MiddleScrollCursorOwner {
    static func isWindowServer(_ owner: pid_t) -> Bool {
        guard owner > 1 else { return false }
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; Swift cannot import its macro.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(owner, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path == "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
            || path == "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    }
}
