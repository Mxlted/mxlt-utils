import AppKit
import ApplicationServices
import MxltCore

/// Filters only a held middle-button sequence. Wheel and trackpad events never enter this tap.
@MainActor
final class MiddleScrollService {
    static let syntheticEventTag = MiddleScrollEventRouting.syntheticTag
    var onAuxiliaryPress: (() -> Void)?
    var onFailure: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var settings = ScrollSettings()
    private var exclusions: Set<String> = []
    private var enabled = false
    private var eligibleProcesses: Set<pid_t> = []
    private var retryUsed = false
    private var gesture = ScrollGesture()
    private var sequence: MiddleScrollSequence?
    private var target: MiddleScrollTarget?
    private var generation: UInt64 = 0
    private var validationWork: DispatchWorkItem?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var missingReleaseSince: TimeInterval?
    private let worker = DispatchQueue(label: "com.mxlted.mxlt-utils.scroll-target", qos: .userInteractive)
    private var indicator: MiddleScrollIndicator?
    private var indicatorVisible = false
#if DEBUG
    private static var debugMessageCount = 0
    private var debugEmissionReported = false
    private var debugStaleValidationReported = false
#endif

    private func debugLog(_ message: String) {
#if DEBUG
        guard Self.debugMessageCount < 30 else { return }
        Self.debugMessageCount += 1
        NSLog("mxlt-scroll: %@", message)
#endif
    }

    /// A restart never reinterprets a button that was already held as a new gesture.
    @discardableResult
    func start(settings: ScrollSettings, exclusions: Set<String>) -> Bool {
        debugLog("start requested")
        self.settings = settings
        self.exclusions = Set(exclusions.map { $0.lowercased() })
        refreshEligibleProcesses()
        cancel(reason: "restart")
        enabled = true
        retryUsed = false
        guard AXIsProcessTrusted() else { debugLog("start denied trust"); enabled = false; removeTapIfIdle(); return false }
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            installObservers()
            return true
        }
        removeTap()
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
                                    .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<MiddleScrollService>.fromOpaque(context).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { service.handle(type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        guard let tap, source != nil, CGEvent.tapIsEnabled(tap: tap) else {
            enabled = false
            removeTap()
            return false
        }
        installObservers()
        debugLog("tap ready")
        return true
    }

    func stop() {
        enabled = false
        cancel(reason: "stop")
        removeObservers()
        // If down was suppressed, consume its matching up before releasing the tap.
        // No synthetic down has been sent, so permission loss cannot leave a held synthetic button.
        removeTapIfIdle()
    }

    func cancel() {
        cancel(reason: "lifecycle")
    }

    private func cancel(reason: String) {
        if sequence != nil, gesture.phase != .cancelled { debugLog("cancel: \(reason)") }
        generation &+= 1
        cancelValidationWork()
        target = nil
        hideIndicator()
        if sequence != nil {
            gesture.cancel()
            ensureTimer()
        } else {
            gesture.reset()
            stopTimer()
        }
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel(reason: "tap disabled")
            if type == .tapDisabledByTimeout, !retryUsed, AXIsProcessTrusted(), let tap {
                retryUsed = true
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) { return false }
            }
            enabled = false
            removeObservers()
            removeTap()
            finishSequence()
            onFailure?()
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventTag else { return false }
        if type == .flagsChanged {
            cancel(reason: "modifier changed")
            return false
        }
        if type == .keyDown {
            // Inspect only Escape's virtual key while a gesture is held; never retain keyboard data.
            if sequence != nil, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                // A cancelled held middle sequence can coexist with a later close gesture.
                // Its swallowed Escape must still cancel CallQuits' newer pending intent.
                onAuxiliaryPress?()
                cancel(reason: "Escape")
                return true
            }
            cancel(reason: "key press") // Also invalidates a short click queued for replay.
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            cancel(reason: "other mouse press")
            return false
        }
        if type == .otherMouseDown {
            onAuxiliaryPress?() // Must run before suppression, independently of target validation.
            // Even an excluded or otherwise uncaptured press supersedes an older queued click.
            if sequence == nil { generation &+= 1; cancelValidationWork() }
        }
        let middle = event.getIntegerValueField(.mouseEventButtonNumber) == 2
        if type == .otherMouseDown, !middle { cancel(reason: "auxiliary press"); return false }
        if type == .otherMouseDown, middle {
            guard sequence == nil else { cancel(reason: "duplicate middle down"); return true }
            guard enabled else { debugLog("down bypass: disabled"); return false }
            guard event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
            else { debugLog("down bypass: modifiers"); return false }
            guard let sequence = MiddleScrollSequence(event: event)
            else { debugLog("down bypass: native identity unavailable"); return false }
            guard eligibleProcesses.contains(sequence.processID)
            else { debugLog("down bypass: ineligible process"); return false }
            guard gesture.begin(at: sequence.anchor, timestamp: sequence.timestamp, settings: settings)
            else { debugLog("down bypass: invalid gesture"); return false }
            debugLog("down captured")
#if DEBUG
            debugEmissionReported = false
            debugStaleValidationReported = false
#endif
            self.sequence = sequence
            missingReleaseSince = nil
            target = nil
            generation &+= 1
            let token = generation
            ensureTimer()
            // Native metadata is copied in the callback. App/window lookups happen afterwards.
            DispatchQueue.main.async { [weak self] in self?.prepareTarget(sequence, generation: token) }
            return true
        }
        if type == .otherMouseDragged, middle, sequence != nil {
            updatePointer(event.location)
            return true
        }
        if type == .mouseMoved, sequence != nil {
            updatePointer(event.location)
            return false // Pointer movement remains native, including at display edges.
        }
        if type == .otherMouseUp, middle, let sequence {
            stopTimer() // Stop continuously generated scroll before any deferred validation.
            hideIndicator()
            let release = event.copy()
            let point = ScrollPoint(x: event.location.x, y: event.location.y)
            let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
            let disposition = gesture.release(at: point, timestamp: timestamp, targetIsValid: enabled)
            debugLog("release: \(disposition)")
            let pinnedTarget = target
            generation &+= 1
            let token = generation
            self.sequence = nil
            target = nil
            cancelValidationWork()
            gesture.reset()
            if disposition == .replayClick, let release {
                // Revalidate at replay time. Never post a delayed click into a changed target.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard token == self.generation, self.enabled else { self.debugLog("replay cancelled before validation"); return }
                    let resolved = pinnedTarget ?? MiddleScrollTarget(sequence: sequence, exclusions: self.exclusions)
                    guard let resolved, resolved.applicationIsValid else { self.debugLog("replay target unavailable"); return }
                    let work = DispatchWorkItem { [weak self] in
                        let valid = resolved.windowIsValid()
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard token == self.generation, self.enabled else { self.debugLog("replay superseded"); return }
                            self.validationWork = nil
                            guard valid else { self.debugLog("replay window validation failed"); return }
                            guard ProcessInfo.processInfo.systemUptime - timestamp <= 0.25 else { self.debugLog("replay expired"); return }
                            guard resolved.applicationIsValid else { self.debugLog("replay app invalid"); return }
                            self.debugLog("replay validated")
                            self.replay(down: sequence.down, up: release, target: resolved)
                        }
                    }
                    self.validationWork = work
                    self.worker.async(execute: work)
                }
            }
            removeTapIfIdle()
            return true
        }
        return false
    }

    private func updatePointer(_ point: CGPoint) {
        guard gesture.move(to: ScrollPoint(x: point.x, y: point.y)), let sequence else { return }
        debugLog("gesture activated")
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation, self.gesture.phase == .scrolling else { return }
            self.showIndicator(at: sequence.anchor)
        }
    }

    private func prepareTarget(_ sequence: MiddleScrollSequence, generation token: UInt64) {
        guard token == generation, self.sequence != nil, enabled else { return }
        guard let target = MiddleScrollTarget(sequence: sequence, exclusions: exclusions) else {
            // A vanished/ambiguous target cannot safely receive either half of the gesture.
            debugLog("target preparation failed")
            cancel(reason: "target unavailable")
            return
        }
        debugLog("target prepared")
        self.target = target
        validateAndScroll(generation: token, elapsed: 0)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard sequence != nil else { stopTimer(); return }
        guard AXIsProcessTrusted() else {
            enabled = false
            cancel(reason: "permission lost")
            removeObservers()
            removeTap()
            finishSequence()
            onFailure?()
            return
        }
        // Recovers from a lost native up, including session transitions. The tap normally handles
        // up synchronously; this check never creates a replay or synthetic button release.
        let now = ProcessInfo.processInfo.systemUptime
        guard CGEventSource.buttonState(.combinedSessionState, button: .center) else {
            // HID state can change before the queued up reaches this run loop. Stop scrolling
            // immediately, but give that matching up a short drain interval before teardown.
            if let since = missingReleaseSince, now - since >= 0.2 {
                debugLog("missing button state: drain finished")
                finishSequence()
            } else if missingReleaseSince == nil {
                debugLog("missing button state: drain started")
                missingReleaseSince = now
            }
            return
        }
        missingReleaseSince = nil
        let elapsed = min(1.0 / 30, max(0, now - lastTick))
        lastTick = now
        guard enabled, gesture.phase == .scrolling else { return }
        validateAndScroll(generation: generation, elapsed: elapsed)
    }

    private func validateAndScroll(generation token: UInt64, elapsed: TimeInterval) {
        guard validationWork == nil, let target, target.applicationIsValid else {
            if target != nil, !target!.applicationIsValid { cancel(reason: "target app invalid") }
            return
        }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let work = DispatchWorkItem { [weak self] in
            let valid = target.windowIsValid()
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.validationWork = nil
                guard valid, target.applicationIsValid else { self.debugLog("active window validation failed"); self.cancel(reason: "target window invalid"); return }
                guard self.enabled, self.gesture.phase == .scrolling, elapsed > 0,
                      self.missingReleaseSince == nil,
                      CGEventSource.buttonState(.combinedSessionState, button: .center),
                      AXIsProcessTrusted() else { return }
                guard ProcessInfo.processInfo.systemUptime - requestedAt < 0.1 else {
#if DEBUG
                    if !self.debugStaleValidationReported {
                        self.debugStaleValidationReported = true
                        self.debugLog("scroll skipped: stale validation")
                    }
#endif
                    return
                }
                // Re-read current intent after validation; dead-zone return and cancellation
                // clear both smoothing and fractional travel before any event can be posted.
                let delta = self.gesture.scrollDelta(elapsed: elapsed)
                self.postScroll(delta: delta, target: target)
            }
        }
        validationWork = work
        worker.async(execute: work)
    }

    private func cancelValidationWork() {
        // Cancelled queued jobs never begin AX work. A job already executing keeps its timeout,
        // and generation checks reject its result. Rapid gestures cannot accumulate stale probes.
        validationWork?.cancel()
        validationWork = nil
    }

    private func postScroll(delta: ScrollDelta, target: MiddleScrollTarget) {
        let dx = -delta.x
        let dy = -delta.y
        guard dx != 0 || dy != 0 else { return }
        guard let template = sequence?.down,
              let event = MiddleScrollEventRouting.scrollEvent(template: template, deltaX: dx, deltaY: dy,
                                                               processID: target.processID, windowID: target.windowID,
                                                               anchor: target.anchor,
                                                               timestamp: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)) else {
#if DEBUG
            if !debugEmissionReported { debugEmissionReported = true; debugLog("scroll construction failed") }
#endif
            return
        }
        event.postToPid(target.processID)
#if DEBUG
        if !debugEmissionReported { debugEmissionReported = true; debugLog("scroll posted") }
#endif
    }

    private func replay(down: CGEvent, up: CGEvent, target: MiddleScrollTarget) {
        guard let replayedDown = MiddleScrollEventRouting.replayEvent(down, template: down, processID: target.processID,
                                                            windowID: target.windowID, anchor: target.anchor),
              let replayedUp = MiddleScrollEventRouting.replayEvent(up, template: down, processID: target.processID,
                                                          windowID: target.windowID, anchor: target.anchor) else { return }
        // Posting both in the same run-loop turn preserves pairing; never send down while waiting.
        replayedDown.postToPid(target.processID)
        replayedUp.postToPid(target.processID)
        debugLog("replay pair posted")
    }

    private func finishSequence() {
        generation &+= 1
        sequence = nil
        missingReleaseSince = nil
        target = nil
        cancelValidationWork()
        gesture.reset()
        hideIndicator()
        stopTimer()
        removeTapIfIdle()
    }

    private func removeTapIfIdle() { if !enabled && sequence == nil { removeTap() } }
    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func refreshEligibleProcesses() {
        eligibleProcesses = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular, !app.isTerminated,
                  let bundleID = app.bundleIdentifier, !exclusions.contains(bundleID.lowercased()) else { return nil }
            return app.processIdentifier
        })
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(reason: "display change") }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEligibleProcesses() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(reason: "session change") }
            })
        }
    }
    private func removeObservers() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func hideIndicator() {
        guard indicatorVisible else { return }
        indicatorVisible = false
        indicator?.hide()
    }

    private func showIndicator(at point: ScrollPoint) {
        if indicator == nil { indicator = MiddleScrollIndicator() }
        indicatorVisible = true
        indicator?.show(at: point)
    }
}

/// Captures only original native routing evidence. Missing metadata leaves input untouched.
private struct MiddleScrollSequence {
    let down: CGEvent
    let processID: pid_t
    let windowID: CGWindowID
    let anchor: ScrollPoint
    let timestamp: TimeInterval

    init?(event: CGEvent) {
        let pid = event.getIntegerValueField(.eventTargetUnixProcessID)
        let handler = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let window = handler > 0 ? handler : event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        guard pid > 1, pid <= Int64(Int32.max), pid != Int64(ProcessInfo.processInfo.processIdentifier),
              window > 0, window <= Int64(UInt32.max), let copy = event.copy() else { return nil }
        down = copy
        processID = pid_t(pid)
        windowID = CGWindowID(window)
        anchor = ScrollPoint(x: event.location.x, y: event.location.y)
        timestamp = TimeInterval(event.timestamp) / 1_000_000_000
    }
}

private final class MiddleScrollTarget: @unchecked Sendable {
    let application: NSRunningApplication
    let bundleID: String
    let processID: pid_t
    let windowID: CGWindowID
    let anchor: ScrollPoint
    private let initialBounds: CGRect
    private let systemCanvases: [pid_t: Int]
    private let displayBounds: [CGRect]

    @MainActor
    init?(sequence: MiddleScrollSequence, exclusions: Set<String>) {
        guard let app = NSRunningApplication(processIdentifier: sequence.processID),
              let bundle = app.bundleIdentifier, !exclusions.contains(bundle.lowercased()),
              !app.isTerminated, !app.isHidden, app.isFinishedLaunching, app.activationPolicy == .regular,
              let window = Self.window(sequence.windowID),
              let owner = window[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == sequence.processID,
              let bounds = Self.bounds(window), bounds.contains(CGPoint(x: sequence.anchor.x, y: sequence.anchor.y)),
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        application = app
        bundleID = bundle
        processID = sequence.processID
        windowID = sequence.windowID
        anchor = sequence.anchor
        initialBounds = bounds
        var canvases: [pid_t: Int] = [:]
        for (bundleID, layer) in ["com.apple.dock": 20, "com.apple.notificationcenterui": 21] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            if running.count == 1 { canvases[running[0].processIdentifier] = layer }
        }
        systemCanvases = canvases
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        displayBounds = screens.map { screen in
            CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
    }

    @MainActor var applicationIsValid: Bool {
        !application.isTerminated && !application.isHidden && application.processIdentifier == processID &&
        application.bundleIdentifier == bundleID && application.isFinishedLaunching &&
        NSRunningApplication(processIdentifier: processID) == application
    }

    func windowIsValid() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        var systemHitProcessID: pid_t?
        if windows.contains(where: { MiddleScrollWindowRouting.isSystemCanvas($0, systemCanvases: systemCanvases,
                                                                            displayBounds: displayBounds) }) {
            let system = AXUIElementCreateSystemWide()
            // This is the same process-default bound used by CallQuits. One system-wide hit is
            // required to distinguish invisible system canvases from interactive system UI.
            guard AXUIElementSetMessagingTimeout(system, 0.12) == .success else { return false }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(anchor.x), Float(anchor.y), &hit) == .success,
                  let hit else { return false }
            var owner: pid_t = 0
            guard AXUIElementGetPid(hit, &owner) == .success else { return false }
            systemHitProcessID = owner
        }
        return MiddleScrollWindowRouting.isValid(windows: windows, processID: processID,
                                                windowID: windowID, initialBounds: initialBounds,
                                                anchor: anchor, ownProcessID: ProcessInfo.processInfo.processIdentifier,
                                                systemCanvases: systemCanvases, displayBounds: displayBounds,
                                                systemHitProcessID: systemHitProcessID)
    }

    private static func window(_ id: CGWindowID) -> [String: Any]? {
        (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first
    }
    private static func bounds(_ window: [String: Any]) -> CGRect? {
        MiddleScrollWindowRouting.bounds(window)
    }
}

@MainActor
private final class MiddleScrollIndicator {
    private let panel: NSPanel
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = IndicatorView(frame: panel.contentRect(forFrameRect: panel.frame))
    }
    func show(at point: ScrollPoint) {
        guard let main = NSScreen.screens.first else { return }
        panel.setFrameOrigin(NSPoint(x: point.x - 14, y: main.frame.maxY - point.y - 14))
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }

    private final class IndicatorView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            NSColor.labelColor.withAlphaComponent(0.7).setStroke()
            let cross = NSBezierPath()
            cross.lineWidth = 1.5
            cross.move(to: NSPoint(x: 14, y: 7)); cross.line(to: NSPoint(x: 14, y: 21))
            cross.move(to: NSPoint(x: 7, y: 14)); cross.line(to: NSPoint(x: 21, y: 14))
            cross.stroke()
        }
    }
}
