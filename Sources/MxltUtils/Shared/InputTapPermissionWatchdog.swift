import Foundation

/// Owns the emergency detach path independently of the main run loop. The injected
/// detach operation must only disable/invalidate the native tap, never call AppKit.
final class InputTapPermissionWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mxlted.mxlt-utils.input-permission", qos: .userInteractive)
    private let readPermission: () -> Bool
    private let detach: () -> Void
    private let onRevoked: () -> Void
    private var active = true
    private var revoked = false
    private var timer: DispatchSourceTimer?

    init(readPermission: @escaping () -> Bool, detach: @escaping () -> Void,
         onRevoked: @escaping () -> Void) {
        self.readPermission = readPermission
        self.detach = detach
        self.onRevoked = onRevoked
    }

    var allowsInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var wasRevoked: Bool {
        lock.lock(); defer { lock.unlock() }
        return revoked
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard active, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.checkPermission() }
        self.timer = timer
        timer.resume()
    }

    /// Permission queries happen off the input callback and outside the lock.
    /// A late query cannot revive an invalidated tap.
    func checkPermission() {
        guard allowsInput, !readPermission() else { return }
        if finish(revoked: true) { onRevoked() }
    }

    /// Timeout recovery needs fresh capability evidence, without doing permission
    /// IPC inside an input callback. Use the same serial queue as periodic checks.
    func checkBeforeRecovery(_ completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            checkPermission()
            completion(allowsInput)
        }
    }

    /// Serialize enabling/posting with revocation. Keep this operation short; never
    /// query permission or call AppKit while holding the lock.
    @discardableResult
    func performIfAllowed(_ operation: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && operation()
    }

    @discardableResult
    func invalidate() -> Bool {
        finish(revoked: false)
    }

    private func finish(revoked: Bool) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        active = false
        self.revoked = revoked
        let previousTimer = timer
        timer = nil
        lock.unlock()
        // Close the gate first, but never hold it while invalidating a native port:
        // an already queued callback must be free to observe false and pass through.
        previousTimer?.cancel()
        detach()
        return true
    }

    deinit { invalidate() }
}
