// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import AppKit
import ApplicationServices
#if canImport(CallQuitsCore)
import CallQuitsCore
#endif

/// A timeout gets one automatic recovery attempt per tap. Further failures require user action.
struct TapRecovery {
    private var attempted = false

    mutating func shouldRetry(enabled: Bool, trusted: Bool) -> Bool {
        guard enabled, trusted, !attempted else { return false }
        attempted = true
        return true
    }
}

/// Keep cancellation routing and subscription in sync. Secondary and auxiliary mouse presses
/// supersede a pending close just like typing; they can never start a close-button gesture.
enum CloseMonitorInput {
    private static let interruptions: [CGEventType] = [.keyDown, .rightMouseDown, .otherMouseDown]
    static let eventMask = ([CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged] + interruptions)
        .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    static let localMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]

    static func interrupts(_ type: CGEventType) -> Bool { interruptions.contains(type) }

    // Shared with the middle-scroll integration. Replayed input is never new close intent.
    static let syntheticEventMarker: Int64 = 0x4D584C54
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }
}

/// Observes clicks; never swallows, rewrites, or synthesizes a user's input.
@MainActor
final class CloseMonitor {
    private let model: QuitModel
    private let worker = CloseWorker()
    private var eventMonitor: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var started = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0
    private var gesture: CloseGesture?
    private var pressIdentity: EventIdentity?
    private var releasePending = false
    private var applicationVisibility: CloseApplicationVisibility?
    private var attemptApplication: NSRunningApplication?
    private var verifiedCloseApplication: NSRunningApplication?
    private var awaitingHide: (() -> Void)?
    private var windowObservation: CloseWindowObservation?
    private var tapRecovery = TapRecovery()
    private var shortcutIntent: CloseShortcutIntent?
    private var shortcutHit: AccessibilityClient.Hit?
    private var shortcutReadyToCheck = false
    private var shortcutConfirmationStarted = false
    private var candidateGeneration: UInt64 = 0
    private var shortcutCandidate: (hit: AccessibilityClient.Hit, observation: CloseWindowObservation, processID: pid_t, bundleIdentifier: String?)?

    init(model: QuitModel) { self.model = model }

    func start() {
        guard !started else { return }
        started = true
        model.onConfigurationChange = { [weak self] in self?.reconfigure() }
        model.onMonitoringRetry = { [weak self] in self?.reconfigure() }
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.willSleepNotification,
                             NSWorkspace.screensDidSleepNotification,
                             NSWorkspace.sessionDidResignActiveNotification,
                             NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate(replenishShortcutCandidate: false); self?.clearShortcutCandidate() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didHideApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.applicationDidHide(notification) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self.applicationVisibility?.owns(processID: app.processIdentifier) == true else { return }
                if let verified = self.verifiedCloseApplication { self.cancelClose(verified, reason: .windowSetChanged) }
                else { self.invalidate() }
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.refreshShortcutCandidate(app)
            }
        })
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                             NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshShortcutCandidate(NSWorkspace.shared.frontmostApplication) }
            })
        }
        // Permission refresh belongs to the app coordinator; this feature owns only
        // its event tap and close-related notifications while it is started.
        model.refreshPermission()
        reconfigure()
    }

    func stop() {
        guard started else { return }
        started = false
        invalidate(replenishShortcutCandidate: false)
        removeMonitors()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        model.onConfigurationChange = nil
        model.onMonitoringRetry = nil
        model.setMonitoringState(.paused)
    }

    private func reconfigure() {
        invalidate(replenishShortcutCandidate: false)
        removeMonitors()
        tapRecovery = TapRecovery()
        guard model.effectiveEnabled, model.accessibilityGranted else {
            model.setMonitoringState(model.effectiveEnabled ? .permissionNeeded : .paused)
            return
        }
        // AppKit's reconstructed CGEvent can identify the observing app as its recipient.
        // Read the original annotated mouse event instead. A listen-only tap cannot modify input.
        eventMonitor = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                        options: .listenOnly, eventsOfInterest: CloseMonitorInput.eventMask, callback: { _, type, event, context in
            guard let context, !CloseMonitorInput.isSynthetic(event) else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<CloseMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByUserInput {
                    monitor.model.enabled = false
                    monitor.model.record("macOS paused click monitoring. Enable CallQuits to resume.")
                } else if type == .tapDisabledByTimeout {
                    monitor.resumeAfterTimeout()
                } else if type == .keyDown {
                    monitor.handleKeyDown(event)
                } else if CloseMonitorInput.interrupts(type) {
                    // Only the existence of an intervening press matters. Never inspect
                    // its contents or recipient; idle typing and secondary clicks do no work.
                    if monitor.gesture != nil || monitor.releasePending || monitor.verifiedCloseApplication != nil || monitor.shortcutIntent != nil {
                        monitor.invalidate()
                    }
                } else { monitor.handle(type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let eventMonitor {
            eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventMonitor, 0)
            if let eventSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
                CGEvent.tapEnable(tap: eventMonitor, enable: true)
            }
        }
        guard let eventMonitor, eventSource != nil, CGEvent.tapIsEnabled(tap: eventMonitor) else {
            monitoringFailed()
            return
        }
        // Local interaction also cancels pending work, including secondary/auxiliary presses.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: CloseMonitorInput.localMask) { [weak self] event in
            if event.cgEvent.map(CloseMonitorInput.isSynthetic) != true {
                MainActor.assumeIsolated { self?.invalidate() }
            }
            return event
        }
        model.setMonitoringState(.running)
        refreshShortcutCandidate(NSWorkspace.shared.frontmostApplication)
    }

    private func resumeAfterTimeout() {
        invalidate(replenishShortcutCandidate: false)
        clearShortcutCandidate()
        model.refreshPermission()
        guard model.effectiveEnabled, model.accessibilityGranted else { return }
        guard let tap = eventMonitor,
              tapRecovery.shouldRetry(enabled: model.effectiveEnabled, trusted: model.accessibilityGranted) else {
            monitoringFailed()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { monitoringFailed(); return }
        model.setMonitoringState(.running)
        refreshShortcutCandidate(NSWorkspace.shared.frontmostApplication)
    }

    private func monitoringFailed() {
        invalidate(replenishShortcutCandidate: false)
        removeMonitors()
        model.setMonitoringState(.unavailable)
    }

    private func removeMonitors() {
        clearShortcutCandidate()
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventMonitor { CFMachPortInvalidate(eventMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        eventMonitor = nil
        eventSource = nil
        localMonitor = nil
    }

    private func invalidate(replenishShortcutCandidate: Bool = true) {
        generation &+= 1
        gesture = nil
        pressIdentity = nil
        releasePending = false
        applicationVisibility = nil
        attemptApplication = nil
        verifiedCloseApplication = nil
        awaitingHide = nil
        shortcutIntent = nil
        shortcutHit = nil
        shortcutReadyToCheck = false
        shortcutConfirmationStarted = false
        windowObservation?.stop()
        windowObservation = nil
        worker.cancel(generation: generation)
        guard replenishShortcutCandidate else { return }
        // A shortcut consumes its cached window. Refill after the attempt ends so
        // repeated tab closes work without switching away and back to the app.
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation, self.shortcutCandidate == nil,
                  self.gesture == nil, !self.releasePending, self.shortcutIntent == nil,
                  self.verifiedCloseApplication == nil else { return }
            self.refreshShortcutCandidate(NSWorkspace.shared.frontmostApplication)
        }
    }

    /// Called synchronously before the scrolling tap suppresses an auxiliary press.
    /// The passive quit tap might otherwise never receive that original event.
    func cancelForAuxiliaryInput() {
        interruptPendingClose()
    }

    private func interruptPendingClose() {
        if gesture != nil || releasePending || verifiedCloseApplication != nil || shortcutIntent != nil { invalidate() }
    }

    private func clearShortcutCandidate() {
        candidateGeneration &+= 1
        shortcutCandidate?.observation.stop()
        shortcutCandidate = nil
        worker.cancelCandidate(generation: candidateGeneration)
    }

    private func refreshShortcutCandidate(_ app: NSRunningApplication?) {
        clearShortcutCandidate()
        guard model.additionalCloseMethods, let app, isEligible(app) else { return }
        let token = candidateGeneration
        worker.prepareCandidate(targetPID: app.processIdentifier, generation: token, onChange: { [weak self] _ in
            guard let self, token == self.candidateGeneration else { return }
            self.refreshShortcutCandidate(NSWorkspace.shared.frontmostApplication)
        }) { [weak self] candidate in
            guard let self, token == self.candidateGeneration else { return }
            guard let candidate, self.isEligible(app), app == candidate.hit.application,
                  NSWorkspace.shared.frontmostApplication == app else { return }
            self.shortcutCandidate = candidate
            candidate.observation.start()
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        guard model.additionalCloseMethods, event.flags.contains(.maskCommand) else { interruptPendingClose(); return }
        // Inspect text only for a Command chord; never retain or log keyboard contents.
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length,
                                       unicodeString: &characters)
        let character = length > 0 && length <= characters.count
            ? String(utf16CodeUnits: characters, count: length)
            : NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        guard CloseShortcut.matches(character: character, command: true,
                                    shift: event.flags.contains(.maskShift), option: event.flags.contains(.maskAlternate),
                                    control: event.flags.contains(.maskControl),
                                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0),
              let identity = EventIdentity(nativeProcessID: event.getIntegerValueField(.eventTargetUnixProcessID),
                                           eventWindowID: 0, windowOwnerProcessID: nil) else { interruptPendingClose(); return }
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        if let candidate = shortcutCandidate, candidate.processID == identity.processID,
           candidate.hit.application.processIdentifier == candidate.processID,
           candidate.hit.application.bundleIdentifier == candidate.bundleIdentifier,
           let currentApplication = NSRunningApplication(processIdentifier: identity.processID),
           candidate.hit.application == currentApplication, isEligible(currentApplication) {
            invalidate()
            shortcutCandidate = nil
            shortcutIntent = CloseShortcutIntent(processID: identity.processID, startedAt: timestamp)
            _ = shortcutIntent?.request(processID: identity.processID, at: timestamp)
            attemptApplication = candidate.hit.application
            applicationVisibility = CloseApplicationVisibility(identity: identity, bundleIdentifier: candidate.hit.application.bundleIdentifier)
            shortcutHit = candidate.hit
            windowObservation = candidate.observation
            let token = generation
            let application = candidate.hit.application
            candidate.observation.onChange = { [weak self] reason in
                guard let self, token == self.generation, reason != .windowSetChanged else { return }
                self.cancelClose(application, reason: reason)
            }
            observeShortcutDestruction(candidate.observation, token: token)
            completeShortcutIfReady()
        } else {
            // Activation/AX notifications may not have supplied a usable window yet.
            // Try a fresh capture, but never guess if it has already disappeared.
            beginShortcutCapture(event, requestedAt: timestamp)
        }
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timestamp + CloseSession.maximumDuration - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self, token == self.generation, self.shortcutIntent != nil else { return }
            self.invalidate() // A tab may have closed normally while its window stayed open.
        }
    }

    private func beginShortcutCapture(_ event: CGEvent, requestedAt: TimeInterval) {
        invalidate()
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        guard let identity = EventIdentity(nativeProcessID: event.getIntegerValueField(.eventTargetUnixProcessID),
                                           eventWindowID: 0, windowOwnerProcessID: nil),
              let app = NSRunningApplication(processIdentifier: identity.processID), isEligible(app) else { return }
        let token = generation
        shortcutIntent = CloseShortcutIntent(processID: identity.processID, startedAt: timestamp)
        _ = shortcutIntent?.request(processID: identity.processID, at: requestedAt)
        attemptApplication = app
        applicationVisibility = CloseApplicationVisibility(identity: identity, bundleIdentifier: app.bundleIdentifier)
        worker.shortcutWindow(eventTime: timestamp, targetPID: identity.processID, generation: token) { [weak self] hit in
            guard let self, token == self.generation else { return }
            guard let hit, self.matchesAttemptApplication(hit.application), self.isEligible(hit.application) else {
                self.invalidate(); return
            }
            self.worker.prepareObservation(hit: hit, generation: token, watchFocus: true, onChange: { [weak self] reason in
                guard let self, token == self.generation else { return }
                // Native close changes focus and destroys the target. Only sheets and
                // replacement windows invalidate a matched shortcut at this stage.
                if reason == .windowSetChanged && self.shortcutIntent?.requestedAt != nil { return }
                if let verified = self.verifiedCloseApplication { self.cancelClose(verified, reason: reason) }
                else { self.invalidate() }
            }) { [weak self] observation in
                guard let self, token == self.generation else { return }
                guard let observation else { self.invalidate(); return }
                self.windowObservation = observation
                self.observeShortcutDestruction(observation, token: token)
                observation.start()
                self.shortcutHit = hit
                self.completeShortcutIfReady()
            }
        }
    }

    private func completeShortcutIfReady() {
        guard let hit = shortcutHit, let requestedAt = shortcutIntent?.requestedAt, !shortcutConfirmationStarted else { return }
        guard matchesAttemptApplication(hit.application), isEligible(hit.application) else { invalidate(); return }
        if verifiedCloseApplication == nil {
            guard shortcutIntent?.isReady(at: ProcessInfo.processInfo.systemUptime) == true else { invalidate(); return }
            verifiedCloseApplication = hit.application
            // Some apps retain closed NSWindows and do not promptly emit destroyed.
            // Use the existing sampling cadence as a fallback, after native key handling.
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, token == self.generation else { return }
                self.shortcutReadyToCheck = true
                self.completeShortcutIfReady()
            }
        }
        guard shortcutReadyToCheck else { return }
        shortcutConfirmationStarted = true
        startConfirmation(hit: hit, token: generation, validUntil: requestedAt + CloseSession.maximumDuration)
    }

    private func observeShortcutDestruction(_ observation: CloseWindowObservation, token: UInt64) {
        observation.onWindowDestroyed = { [weak self] in
            guard let self, token == self.generation else { return }
            self.shortcutReadyToCheck = true
            self.completeShortcutIfReady()
        }
    }

    private func applicationDidHide(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switch applicationVisibility?.applicationDidHide(processID: app?.processIdentifier,
                                                         at: ProcessInfo.processInfo.systemUptime) {
        case .preserveMatchedRelease:
            // Native release has matched, but a positive AX hit is still mandatory. Keeping
            // this evidence lets a hide notification arrive before the worker's hit callback.
            let resume = awaitingHide
            awaitingHide = nil
            resume?()
        case .cancel:
            if let app = verifiedCloseApplication { cancelClose(app, reason: .applicationHidden) }
            else { invalidate() }
        case .unrelated, nil:
            break
        }
    }

    private func allowsHiddenClose(_ app: NSRunningApplication) -> Bool {
        applicationVisibility?.allowsHiddenState(processID: app.processIdentifier,
                                                  bundleIdentifier: app.bundleIdentifier,
                                                  at: ProcessInfo.processInfo.systemUptime) == true
    }

    private func handle(_ type: CGEventType, event: CGEvent) {
        // CGEvent already uses the same top-left global display coordinates as Accessibility.
        let point = event.location
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        let targetValue = event.getIntegerValueField(.eventTargetUnixProcessID)
        let handlerWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let eventWindow = handlerWindow > 0 ? handlerWindow : event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let modifiers = event.flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl])
        let intent: CloseGestureModifiers = modifiers.isEmpty ? .normal :
            (modifiers == .maskShift && model.forceQuitEnabled ? .force : .bypass)
        switch type {
        case .leftMouseDown:
            invalidate()
            guard let identity = EventIdentity(nativeProcessID: targetValue, eventWindowID: eventWindow,
                                               windowOwnerProcessID: windowOwner(eventWindow)),
                  let app = NSRunningApplication(processIdentifier: identity.processID),
                  isEligible(app) else { return }
            pressIdentity = identity
            gesture = CloseGesture(x: point.x, y: point.y, timestamp: timestamp,
                                   targetProcessID: identity.processID, modifiers: intent)
            guard gesture != nil else { return }
            applicationVisibility = CloseApplicationVisibility(identity: identity, bundleIdentifier: app.bundleIdentifier)
            attemptApplication = app
            worker.mouseDown(point: point, eventTime: timestamp, targetPID: identity.processID, generation: generation,
                             includingTabs: model.additionalCloseMethods && intent == .normal)
        case .leftMouseDragged:
            if let gesture, !gesture.allowsDrag(toX: point.x, y: point.y) { invalidate() }
        case .leftMouseUp:
            guard let identity = pressIdentity,
                  identity.matchesRelease(nativeProcessID: targetValue, eventWindowID: eventWindow,
                                          windowOwnerProcessID: windowOwner(eventWindow)),
                  let action = gesture?.actionOnRelease(x: point.x, y: point.y, timestamp: timestamp,
                                                       targetProcessID: identity.processID, modifiers: intent)
            else { invalidate(); return }
            gesture = nil
            pressIdentity = nil
            let force = action == .force
            applicationVisibility?.recordMatchedRelease(at: timestamp, permitsHiddenClose: !force)
            let token = generation
            let validUntil = timestamp + (force ? 0.8 : CloseSession.maximumDuration)
            releasePending = true
            worker.mouseUp(point: point, eventTime: timestamp, generation: token) { [weak self] hit in
                guard let self, token == self.generation else { return }
                guard self.matchesAttemptApplication(hit.application) else { self.invalidate(); return }
                self.releasePending = false
                self.verifiedCloseApplication = hit.application
                // macOS can update isHidden before delivering didHide. Wait for that exact
                // transition without doing more AX work or granting permission to quit.
                if !force && hit.allowsApplicationHide && hit.application.isHidden && !self.allowsHiddenClose(hit.application) {
                    self.awaitingHide = { [weak self] in
                        self?.confirmVerifiedClose(hit: hit, force: false, token: token, validUntil: validUntil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, validUntil - ProcessInfo.processInfo.systemUptime)) { [weak self] in
                        guard let self, token == self.generation, self.awaitingHide != nil else { return }
                        self.cancelClose(hit.application, reason: .expired)
                    }
                    return
                }
                self.confirmVerifiedClose(hit: hit, force: force, token: token, validUntil: validUntil)
            }
        default: break
        }
    }

    private func confirmVerifiedClose(hit: AccessibilityClient.Hit, force: Bool, token: UInt64, validUntil: TimeInterval) {
        guard token == generation else { return }
        guard matchesAttemptApplication(hit.application) else { invalidate(); return }
        guard ProcessInfo.processInfo.systemUptime < validUntil else {
            cancelClose(hit.application, reason: .expired)
            return
        }
        let allowHidden = !force && hit.allowsApplicationHide && self.allowsHiddenClose(hit.application)
        guard self.isEligible(hit.application, allowsVerifiedHiddenClose: allowHidden) else {
            if hit.application.isHidden { self.cancelClose(hit.application, reason: .applicationHidden) }
            else { self.invalidate() }
            return
        }
        if force {
            guard hit.trigger.allowsForceQuit else { invalidate(); return }
            self.requestQuit(hit.application, force: true, generation: token, validUntil: validUntil)
        } else {
            self.worker.prepareObservation(hit: hit, generation: token, onChange: { [weak self] reason in
                guard let self, self.generation == token else { return }
                self.cancelClose(hit.application, reason: reason)
            }) { [weak self] observation in
                guard let self, self.generation == token else { return }
                guard ProcessInfo.processInfo.systemUptime < validUntil else {
                    self.cancelClose(hit.application, reason: .expired)
                    return
                }
                guard let observation else {
                    self.model.record("Skipped quit for \(hit.application.localizedName ?? "the app"): window observation is unavailable.")
                    self.invalidate()
                    return
                }
                self.windowObservation = observation
                observation.start()
                self.startConfirmation(hit: hit, token: token, validUntil: validUntil)
            }
        }
    }

    private func startConfirmation(hit: AccessibilityClient.Hit, token: UInt64, validUntil: TimeInterval) {
        worker.confirm(hit: hit, behavior: hit.trigger.behavior(configured: model.behavior), generation: token) { [weak self] decision, checkedAt, confirmedHidden in
            guard let self, self.generation == token else { return }
            switch decision {
            case .quit:
                self.requestQuit(hit.application, force: false, generation: token,
                                 validUntil: min(validUntil, checkedAt + 0.25), confirmedHidden: confirmedHidden)
            case .cancel(let reason): self.cancelClose(hit.application, reason: reason)
            case .wait: break
            }
        }
    }

    private func windowOwner(_ eventWindow: Int64) -> Int64? {
        // Only an event-stamped WindowServer ID is accepted. NSEvent.windowNumber is not a CGWindowID.
        // Exact-ID lookup reads owner metadata, never a screen image, title, or guessed frontmost app.
        guard eventWindow > 0, eventWindow <= Int64(UInt32.max),
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(eventWindow)) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.int64Value == eventWindow })
        else { return nil }
        return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int64Value
    }

    private func isEligible(_ app: NSRunningApplication, allowsVerifiedHiddenClose: Bool = false) -> Bool {
        model.effectiveEnabled && model.accessibilityGranted && AXIsProcessTrusted() && model.monitorRunning &&
        AppProtection.isEligible(bundleIdentifier: app.bundleIdentifier,
                                 processID: app.processIdentifier,
                                 ownProcessID: ProcessInfo.processInfo.processIdentifier,
                                 isTerminated: app.isTerminated, isHidden: app.isHidden,
                                 isRegular: app.activationPolicy == .regular,
                                 isFinishedLaunching: app.isFinishedLaunching,
                                 isExcluded: app.bundleIdentifier.map { model.isExcluded($0) } ?? true,
                                 allowsVerifiedHiddenClose: allowsVerifiedHiddenClose)
    }

    private func matchesAttemptApplication(_ app: NSRunningApplication) -> Bool {
        // AppKit recommends object equality for process identity. Also pin the native PID:
        // automatic termination can change the PID represented by a retained application.
        guard let attemptApplication, app == attemptApplication else { return false }
        return applicationVisibility?.matchesApplication(processID: app.processIdentifier,
                                                          bundleIdentifier: app.bundleIdentifier) == true
    }

    private func cancelClose(_ app: NSRunningApplication, reason: CloseCancellationReason) {
        model.record("Skipped quit for \(app.localizedName ?? "the app"): \(reason.activityExplanation).")
        invalidate()
    }

    private func requestQuit(_ app: NSRunningApplication, force: Bool, generation token: UInt64,
                             validUntil: TimeInterval, confirmedHidden: Bool = false) {
        guard token == generation else { return }
        guard matchesAttemptApplication(app) else { invalidate(); return }
        guard ProcessInfo.processInfo.systemUptime < validUntil else {
            cancelClose(app, reason: .expired)
            return
        }
        // Recheck the confirmed state and transition evidence immediately before graceful quit.
        // Force quit never receives the hidden-app exception.
        if !force && app.isHidden != confirmedHidden { cancelClose(app, reason: .windowSetChanged); return }
        let allowHidden = !force && confirmedHidden && allowsHiddenClose(app)
        guard isEligible(app, allowsVerifiedHiddenClose: allowHidden), !force || model.forceQuitEnabled
        else { invalidate(); return }
        invalidate() // One request per click. A rejected/canceled graceful quit is never retried.
        let name = app.localizedName ?? "Application"
        let sent = force ? app.forceTerminate() : app.terminate()
        model.record(sent ? (force ? "Requested force quit for \(name)." : "Asked \(name) to quit.")
                          : "\(name) did not accept the quit request.")
    }
}

extension CloseCancellationReason {
    var activityExplanation: String {
        switch self {
        case .remainingWindows: "other windows remain"
        case .blockingUI: "a sheet or modal dialog was observed"
        case .replacementWindow: "a new or replacement window was observed"
        case .unreliableSnapshot: "Accessibility could not reliably confirm the window state"
        case .windowSetChanged: "the window set changed during confirmation"
        case .expired: "the close attempt expired before it could be confirmed"
        case .invalidTiming: "the close timing could not be verified"
        case .alreadyFinished: "the close attempt had already finished"
        case .applicationHidden: "an application was hidden without a verified hide-on-close confirmation"
        }
    }
}

/// Queue-confined state keeps slow or unresponsive AX servers away from the main run loop.
private final class CloseWorker {
    private let queue = DispatchQueue(label: "com.mxlted.mxlt-utils.quit.accessibility", qos: .userInitiated)
    private lazy var client = AccessibilityClient()
    private var generation: UInt64 = 0
    private var down: AccessibilityClient.Hit?
    private var downTime: TimeInterval = 0
    private var candidateGeneration: UInt64 = 0

    func cancelCandidate(generation: UInt64) {
        queue.async { self.candidateGeneration = generation }
    }

    func prepareCandidate(targetPID: pid_t, generation: UInt64,
                          onChange: @escaping @MainActor (CloseCancellationReason) -> Void,
                          completion: @escaping @MainActor ((hit: AccessibilityClient.Hit, observation: CloseWindowObservation, processID: pid_t, bundleIdentifier: String?)?) -> Void) {
        queue.async {
            guard self.candidateGeneration == generation else { return }
            guard let hit = self.client.shortcutWindow(eventTime: ProcessInfo.processInfo.systemUptime, targetPID: targetPID),
                  let observation = CloseWindowObservation(hit: hit, watchFocus: true, onChange: onChange) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion((hit, observation, targetPID, hit.application.bundleIdentifier)) }
        }
    }

    func cancel(generation: UInt64) {
        queue.async { self.generation = generation; self.down = nil }
    }

    func mouseDown(point: CGPoint, eventTime: TimeInterval, targetPID: pid_t, generation: UInt64, includingTabs: Bool) {
        queue.async {
            guard self.generation == generation else { return }
            self.downTime = eventTime
            self.down = self.client.closeButton(at: point, eventTime: eventTime, targetPID: targetPID, includingTabs: includingTabs)
        }
    }

    func shortcutWindow(eventTime: TimeInterval, targetPID: pid_t, generation: UInt64,
                        completion: @escaping @MainActor (AccessibilityClient.Hit?) -> Void) {
        queue.async {
            guard self.generation == generation else { return }
            let hit = self.client.shortcutWindow(eventTime: eventTime, targetPID: targetPID)
            DispatchQueue.main.async { completion(hit) }
        }
    }

    func mouseUp(point: CGPoint, eventTime: TimeInterval, generation: UInt64,
                 completion: @escaping @MainActor (AccessibilityClient.Hit) -> Void) {
        queue.async {
            defer { self.down = nil }
            guard self.generation == generation, let hit = self.down,
                  eventTime >= self.downTime, eventTime - self.downTime <= 3,
                  ProcessInfo.processInfo.systemUptime - eventTime <= 0.8,
                  hit.buttonFrame.contains(point) else { return }
            DispatchQueue.main.async { completion(hit) }
        }
    }

    func confirm(hit: AccessibilityClient.Hit, behavior: CloseBehavior, generation: UInt64,
                 completion: @escaping @MainActor (CloseDecision, TimeInterval, Bool) -> Void) {
        queue.async {
            guard self.generation == generation else { return }
            let session = CloseSession(behavior: behavior, startedAt: ProcessInfo.processInfo.systemUptime,
                                       allowsApplicationHide: hit.allowsApplicationHide)
            self.poll(hit: hit, session: session, generation: generation, completion: completion)
        }
    }

    func prepareObservation(hit: AccessibilityClient.Hit, generation: UInt64, watchFocus: Bool = false,
                            onChange: @escaping @MainActor (CloseCancellationReason) -> Void,
                            completion: @escaping @MainActor (CloseWindowObservation?) -> Void) {
        queue.async {
            guard self.generation == generation else { return }
            let observation = CloseWindowObservation(hit: hit, watchFocus: watchFocus, onChange: onChange)
            DispatchQueue.main.async { completion(observation) }
        }
    }

    private func poll(hit: AccessibilityClient.Hit, session: CloseSession, generation: UInt64,
                      completion: @escaping @MainActor (CloseDecision, TimeInterval, Bool) -> Void) {
        guard self.generation == generation else { return }
        var session = session
        let snapshot = client.snapshot(for: hit)
        let checkedAt = ProcessInfo.processInfo.systemUptime
        let decision = session.evaluate(snapshot: snapshot, now: checkedAt)
        switch decision {
        case .quit, .cancel:
            DispatchQueue.main.async { completion(decision, checkedAt, snapshot.applicationHidden) }
        case .wait:
            // Schedule from completion, so slow AX reads never build up a backlog of overdue polls.
            queue.asyncAfter(deadline: .now() + 0.1) {
                self.poll(hit: hit, session: session, generation: generation, completion: completion)
            }
        }
    }
}

/// Once registered, creation notifications also catch replacements between snapshots.
/// Registration is worker-only; source activation and removal are main-thread-only.
private final class CloseWindowObservation {
    private final class Relay {
        var onChange: @MainActor (CloseCancellationReason) -> Void
        var onWindowDestroyed: (@MainActor () -> Void)?
        init(_ onChange: @escaping @MainActor (CloseCancellationReason) -> Void) { self.onChange = onChange }
    }
    private let observer: AXObserver
    private let relay: Relay
    @MainActor var onChange: @MainActor (CloseCancellationReason) -> Void {
        get { relay.onChange }
        set { relay.onChange = newValue }
    }
    @MainActor var onWindowDestroyed: (@MainActor () -> Void)? {
        get { relay.onWindowDestroyed }
        set { relay.onWindowDestroyed = newValue }
    }

    init?(hit: AccessibilityClient.Hit, watchFocus: Bool = false, onChange: @escaping @MainActor (CloseCancellationReason) -> Void) {
        relay = Relay(onChange)
        var result: AXObserver?
        let error = AXObserverCreate(hit.application.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
            if notification as String == kAXUIElementDestroyedNotification {
                MainActor.assumeIsolated {
                    if let onWindowDestroyed = relay.onWindowDestroyed { onWindowDestroyed() }
                    else { relay.onChange(.windowSetChanged) }
                }
                return
            }
            let reason: CloseCancellationReason
            switch notification as String {
            case kAXSheetCreatedNotification: reason = .blockingUI
            case kAXFocusedWindowChangedNotification: reason = .windowSetChanged
            default: reason = .replacementWindow
            }
            MainActor.assumeIsolated { relay.onChange(reason) }
        }, &result)
        guard error == .success, let result else { return nil }
        observer = result
        let context = Unmanaged.passUnretained(relay).toOpaque()
        guard AXObserverAddNotification(observer, hit.appElement, kAXWindowCreatedNotification as CFString, context) == .success
        else { return nil }
        // Window creation support is mandatory. Sheet support varies; snapshots also detect sheets.
        AXObserverAddNotification(observer, hit.appElement, kAXSheetCreatedNotification as CFString, context)
        if watchFocus {
            guard AXObserverAddNotification(observer, hit.appElement, kAXFocusedWindowChangedNotification as CFString, context) == .success
            else { return nil }
            guard AXObserverAddNotification(observer, hit.window, kAXUIElementDestroyedNotification as CFString, context) == .success
            else { return nil }
        }
    }

    @MainActor func start() {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @MainActor func stop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
