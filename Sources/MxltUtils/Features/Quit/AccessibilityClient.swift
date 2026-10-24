// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import AppKit
import ApplicationServices
#if canImport(CallQuitsCore)
import CallQuitsCore
#endif

/// Used only on CloseMonitor's serial worker queue. No Accessibility IPC runs on the UI thread.
final class AccessibilityClient {
    struct Hit {
        let application: NSRunningApplication
        let appElement: AXUIElement
        let window: AXUIElement
        let initialWindows: [AXUIElement]
        let buttonFrame: CGRect
        let allowsApplicationHide: Bool
        var trigger: CloseTrigger = .windowButton
    }

    /// AX-only proof, kept separate from application eligibility and native event identity.
    struct CloseControl {
        let appElement: AXUIElement
        let window: AXUIElement
        let initialWindows: [AXUIElement]
        let buttonFrame: CGRect
        var trigger: CloseTrigger = .windowButton
    }

    private enum ReadError: Error { case unavailable(AXError), unexpectedValue, exceededBudget }
    typealias AttributeReader = (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    typealias AttributesReader = (AXUIElement, [String]) -> (AXError, [CFTypeRef]?)
    typealias ElementFinder = (AXUIElement, CGPoint) -> (AXError, AXUIElement?)
    typealias ProcessReader = (AXUIElement) -> pid_t?
    private let readAttribute: AttributeReader
    private let readAttributes: AttributesReader
    private let findElement: ElementFinder
    private let readProcessID: ProcessReader
    private let system = AXUIElementCreateSystemWide()
    private var deadline: TimeInterval = 0

    init(readAttribute: @escaping AttributeReader = { element, attribute in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }, readAttributes: @escaping AttributesReader = { element, attributes in
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, .stopOnError, &values)
        return (error, values as? [CFTypeRef])
    }, findElement: @escaping ElementFinder = { system, point in
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        return (error, element)
    }, readProcessID: @escaping ProcessReader = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }) {
        self.readAttribute = readAttribute
        self.readAttributes = readAttributes
        self.findElement = findElement
        self.readProcessID = readProcessID
        // The system-wide element sets the default for every AX object in this process.
        AXUIElementSetMessagingTimeout(system, 0.12)
    }

    func closeButton(at point: CGPoint, eventTime: TimeInterval, targetPID: pid_t, includingTabs: Bool = false,
                     middleClick: Bool = false, includingDialogCancel: Bool = false) -> Hit? {
        guard let app = NSRunningApplication(processIdentifier: targetPID), isEligible(app),
              let control = captureCloseControl(at: point, eventTime: eventTime, targetPID: targetPID,
                                                includingTabs: includingTabs, middleClick: middleClick,
                                                includingDialogCancel: includingDialogCancel,
                                                targetBundleIdentifier: app.bundleIdentifier)
        else { return nil }
        // The monitor rechecks eligibility after release and immediately before termination.
        // Let it adjudicate a same-process Discord hide that arrives while capture finishes.
        // Only Discord's single, nonminimized window can use hide-on-close confirmation.
        // Every reported window counts here, including windows on other Spaces.
        let allowsHide = control.trigger == .windowButton && HiddenCloseIntent.supports(bundleIdentifier: app.bundleIdentifier) &&
            control.initialWindows.count == 1 && (try? bool(control.window, kAXMinimizedAttribute)) == false
        return Hit(application: app, appElement: control.appElement, window: control.window,
                   initialWindows: control.initialWindows, buttonFrame: control.buttonFrame,
                   allowsApplicationHide: allowsHide, trigger: control.trigger)
    }

    private func isEligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.isFinishedLaunching && !app.isHidden && !app.isTerminated &&
        !AppProtection.isProtected(bundleIdentifier: app.bundleIdentifier, processID: app.processIdentifier,
                                   ownProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    func captureCloseControl(at point: CGPoint, eventTime: TimeInterval, targetPID: pid_t,
                             includingTabs: Bool = false, middleClick: Bool = false,
                             includingDialogCancel: Bool = false,
                             targetBundleIdentifier: String? = nil) -> CloseControl? {
        deadline = ProcessInfo.processInfo.systemUptime + 0.55
        let now = ProcessInfo.processInfo.systemUptime
        guard targetPID > 1, eventTime.isFinite, eventTime >= 0, now >= eventTime,
              now - eventTime < 0.5, !middleClick || includingTabs else { return nil }
        do {
            let (error, result) = findElement(system, point)
            guard error == .success, var button = result else { return nil }
            if middleClick {
                return try middleTabControl(hit: button, at: point, targetPID: targetPID)
            }
            if includingDialogCancel,
               let control = try dialogCancelControl(hit: button, at: point, targetPID: targetPID,
                                                    targetBundleIdentifier: targetBundleIdentifier) { return control }
            var verifiedTabButton = false
            // Some apps expose a child of the actual button to hit testing.
            for depth in 0...4 {
                if try value(button, kAXSubroleAttribute, optional: true) as? String == kAXCloseButtonSubrole { break }
                if includingTabs, try isTabCloseButton(button) { verifiedTabButton = true; break }
                if includingTabs, depth == 0,
                   let resolved = try tabCloseButton(inHitContainer: button, at: point, targetPID: targetPID) {
                    button = resolved
                    verifiedTabButton = true
                    break
                }
                guard depth < 4, let parent = try element(button, kAXParentAttribute) else { return nil }
                button = parent
            }
            guard let window = try element(button, kAXWindowAttribute) else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, pid == targetPID else { return nil }
            let appElement = AXUIElementCreateApplication(pid)
            // Capture membership before the remaining control checks. Empty documents can
            // close immediately after the final button read; a later enumeration would discard
            // an otherwise fully verified click. Disappearance still needs normal confirmation.
            let windows = try windows(appElement)
            guard windows.contains(where: { CFEqual($0, window) }) else { return nil }
            // Group required values to reduce IPC while the button is still alive. These calls
            // are not atomic snapshots; all identity, sheet and later stability checks remain.
            let windowValues = try values(window, [kAXRoleAttribute, kAXSubroleAttribute,
                                                   kAXModalAttribute, kAXChildrenAttribute, kAXCloseButtonAttribute])
            guard windowValues[0] as? String == kAXWindowRole,
                  windowValues[1] as? String == kAXStandardWindowSubrole,
                  try boolean(windowValues[2]) == false,
                  try !hasSheet(windowValues[3]),
                  let officialButton = axElement(windowValues[4])
            else { return nil }
            if !CFEqual(button, officialButton) {
                guard includingTabs, try verifiedTabButton || isTabCloseButton(button) else { return nil }
                let attributes = try values(button, [kAXRoleAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute])
                guard attributes[0] as? String == kAXButtonRole, try boolean(attributes[1]),
                      let frame = frame(position: attributes[2], size: attributes[3]), frame.contains(point)
                else { return nil }
                return CloseControl(appElement: appElement, window: window, initialWindows: windows,
                                    buttonFrame: frame, trigger: .tabButton)
            }
            let buttonValues = try values(button, [kAXSubroleAttribute, kAXRoleAttribute, kAXEnabledAttribute,
                                                   kAXPositionAttribute, kAXSizeAttribute])
            guard buttonValues[0] as? String == kAXCloseButtonSubrole,
                  buttonValues[1] as? String == kAXButtonRole,
                  try boolean(buttonValues[2]) == true,
                  let frame = frame(position: buttonValues[3], size: buttonValues[4]), frame.contains(point)
            else { return nil }
            return CloseControl(appElement: appElement, window: window, initialWindows: windows, buttonFrame: frame)
        } catch { return nil }
    }

    /// A tab close is a button inside a tab inside a tab group. Never infer it
    /// from an X glyph, screen position, a web page button, or a tab's title.
    private func isTabCloseButton(_ button: AXUIElement) throws -> Bool {
        guard try string(button, kAXRoleAttribute) == kAXButtonRole,
              let tab = try element(button, kAXParentAttribute) else { return false }
        guard let window = try element(button, kAXWindowAttribute) else { return false }
        guard try isNativeTab(tab, in: window) else { return false }
        if let raw = try value(tab, kAXCloseButtonAttribute, optional: true) {
            guard let official = axElement(raw) else { return false }
            return CFEqual(official, button)
        }
        // Chromium exposes its localized Close action as the child button's name,
        // without an AXCloseButton attribute. Unknown/localized labels fail closed.
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let label = try value(button, attribute, optional: true) as? String,
               ["close", "close tab"].contains(label.lowercased()) { return true }
        }
        return false
    }

    private func isNativeTab(_ tab: AXUIElement, in window: AXUIElement) throws -> Bool {
        guard try string(tab, kAXRoleAttribute) == kAXRadioButtonRole,
              let group = try element(tab, kAXParentAttribute),
              try string(group, kAXRoleAttribute) == kAXTabGroupRole else { return false }
        // Web pages can expose their own tab groups. Only native window chrome qualifies.
        var ancestor = group
        var reachedWindow = false
        for _ in 0..<8 {
            guard let parent = try element(ancestor, kAXParentAttribute) else { return false }
            if CFEqual(parent, window) { reachedWindow = true; break }
            guard let role = try string(parent, kAXRoleAttribute),
                  [kAXGroupRole, kAXToolbarRole, kAXScrollAreaRole].contains(role) else { return false }
            ancestor = parent
        }
        return reachedWindow
    }

    /// Chromium can hit-test a leaf rendering group beside its accessible tab group.
    /// Resolve only that immediate sibling relationship, using the real close control's
    /// AX frame and native ancestry. Never search the window or infer a control from an X.
    private func tabCloseButton(inHitContainer hit: AXUIElement, at point: CGPoint,
                                targetPID: pid_t, middleClick: Bool = false) throws -> AXUIElement? {
        guard try string(hit, kAXRoleAttribute) == kAXGroupRole,
              let parent = try element(hit, kAXParentAttribute),
              try string(parent, kAXRoleAttribute) == kAXGroupRole,
              try children(hit).isEmpty,
              let window = try element(hit, kAXWindowAttribute),
              try controlFrame(hit).contains(point) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == targetPID,
              let parentWindow = try element(parent, kAXWindowAttribute), CFEqual(parentWindow, window)
        else { return nil }
        let siblings = try children(parent)
        guard siblings.contains(where: { CFEqual($0, hit) }) else { return nil }
        let groups = try siblings.filter {
            guard let role = try string($0, kAXRoleAttribute) else { throw ReadError.unexpectedValue }
            return role == kAXTabGroupRole
        }
        guard groups.count == 1, let group = groups.first,
              let groupParent = try element(group, kAXParentAttribute), CFEqual(groupParent, parent),
              let groupWindow = try element(group, kAXWindowAttribute), CFEqual(groupWindow, window)
        else { return nil }

        // Require one actual tab and one actual button at the point. Overlapping,
        // unreadable or unrelated controls fail closed rather than choosing the first.
        let tabs = try children(group).filter {
            guard let role = try string($0, kAXRoleAttribute) else { throw ReadError.unexpectedValue }
            return try role == kAXRadioButtonRole && controlFrame($0).contains(point)
        }
        guard tabs.count == 1, let tab = tabs.first,
              let tabParent = try element(tab, kAXParentAttribute), CFEqual(tabParent, group),
              let tabWindow = try element(tab, kAXWindowAttribute), CFEqual(tabWindow, window)
        else { return nil }
        let buttons = try children(tab).filter {
            guard let role = try string($0, kAXRoleAttribute) else { throw ReadError.unexpectedValue }
            return try role == kAXButtonRole && (middleClick || controlFrame($0).contains(point))
        }
        guard buttons.count == 1, let button = buttons.first,
              let buttonParent = try element(button, kAXParentAttribute), CFEqual(buttonParent, tab),
              let buttonWindow = try element(button, kAXWindowAttribute), CFEqual(buttonWindow, window),
              try isTabCloseButton(button) else { return nil }
        return middleClick ? tab : button
    }

    private func middleTabControl(hit: AXUIElement, at point: CGPoint, targetPID: pid_t) throws -> CloseControl? {
        var tab = hit
        if let resolved = try tabCloseButton(inHitContainer: hit, at: point, targetPID: targetPID, middleClick: true) {
            tab = resolved
        }
        for depth in 0...4 {
            if try string(tab, kAXRoleAttribute) == kAXRadioButtonRole { break }
            guard depth < 4, let parent = try element(tab, kAXParentAttribute) else { return nil }
            tab = parent
        }
        guard let window = try element(tab, kAXWindowAttribute), try isNativeTab(tab, in: window) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == targetPID else { return nil }
        let app = AXUIElementCreateApplication(targetPID)
        let initial = try windows(app)
        guard initial.contains(where: { CFEqual($0, window) }) else { return nil }
        let attributes = try values(window, [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute,
                                             kAXChildrenAttribute, kAXMinimizedAttribute])
        guard attributes[0] as? String == kAXWindowRole, attributes[1] as? String == kAXStandardWindowSubrole,
              try !boolean(attributes[2]), try !hasSheet(attributes[3]), try !boolean(attributes[4]),
              try bool(tab, kAXEnabledAttribute) == true else { return nil }
        // Require a real close control as well as native tab ancestry. Segmented controls
        // and nonclosable native tabs do not establish close intent.
        let controls = try children(tab).filter {
            guard let role = try string($0, kAXRoleAttribute) else { throw ReadError.unexpectedValue }
            return role == kAXButtonRole
        }
        let closeControls = try controls.filter { try isTabCloseButton($0) }
        guard closeControls.count == 1, let close = closeControls.first,
              let closeParent = try element(close, kAXParentAttribute), CFEqual(closeParent, tab),
              let closeWindow = try element(close, kAXWindowAttribute), CFEqual(closeWindow, window),
              try bool(close, kAXEnabledAttribute) == true else { return nil }
        let frame = try controlFrame(tab)
        guard frame.contains(point) else { return nil }
        return CloseControl(appElement: app, window: window, initialWindows: initial,
                            buttonFrame: frame, trigger: .middleClickTab)
    }

    /// A verified Cancel on the sole standalone dialog can finish an otherwise windowless
    /// app (for example TextEdit's startup chooser). Never infer this from the button label.
    private func dialogCancelControl(hit: AXUIElement, at point: CGPoint, targetPID: pid_t,
                                     targetBundleIdentifier: String?) throws -> CloseControl? {
        var button = hit
        for depth in 0...4 {
            if try string(button, kAXRoleAttribute) == kAXButtonRole { break }
            guard depth < 4, let parent = try element(button, kAXParentAttribute) else { return nil }
            button = parent
        }
        let chooserWindow = try targetBundleIdentifier == "com.apple.TextEdit"
            ? textEditOpenPanelWindow(for: button, targetPID: targetPID) : nil
        let window: AXUIElement
        if let chooserWindow {
            window = chooserWindow
        } else {
            guard let owner = try element(button, kAXWindowAttribute),
                  try value(owner, kAXSubroleAttribute, optional: true) as? String == kAXDialogSubrole else { return nil }
            window = owner
        }
        // Remote open-panel controls may have a different PID. Exact membership in the
        // native recipient's AXWindows and its official AXCancelButton establish ownership.
        let app = AXUIElementCreateApplication(targetPID)
        let initial = try windows(app)
        guard initial.count == 1, CFEqual(initial[0], window),
              try string(window, kAXRoleAttribute) == kAXWindowRole,
              try value(window, kAXDocumentAttribute, optional: true) == nil,
              try bool(window, kAXMinimizedAttribute) == false,
              try bool(window, kAXModalAttribute) != nil,
              let children = try value(window, kAXChildrenAttribute), try !hasSheet(children) else { return nil }
        if let raw = try value(window, kAXCancelButtonAttribute, optional: true) {
            guard let official = axElement(raw), CFEqual(official, button) else { return nil }
        } else if chooserWindow == nil { return nil }
        let attributes = try values(button, [kAXRoleAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute])
        guard attributes[0] as? String == kAXButtonRole, try boolean(attributes[1]),
              let frame = frame(position: attributes[2], size: attributes[3]), frame.contains(point) else { return nil }
        return CloseControl(appElement: app, window: window, initialWindows: initial,
                            buttonFrame: frame, trigger: .dialogCancel)
    }

    /// Observed TextEdit startup chooser: AXStandardWindow/open-panel, with CancelButton
    /// directly inside its AXSplitGroup. Both AXWindow on the button and AXCancelButton on
    /// the window return noValue. Scope this compatibility path to TextEdit and verify both
    /// directions of the exact native ancestry; a label or identifier alone is insufficient.
    private func textEditOpenPanelWindow(for button: AXUIElement, targetPID: pid_t) throws -> AXUIElement? {
        guard try value(button, kAXIdentifierAttribute, optional: true) as? String == "CancelButton",
              let group = try element(button, kAXParentAttribute),
              try string(group, kAXRoleAttribute) == kAXSplitGroupRole,
              let window = try element(group, kAXParentAttribute),
              try string(window, kAXRoleAttribute) == kAXWindowRole,
              try string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              try value(window, kAXIdentifierAttribute, optional: true) as? String == "open-panel",
              try bool(window, kAXModalAttribute) == false else { return nil }
        guard readProcessID(window) == targetPID, readProcessID(button) == targetPID,
              try children(window).filter({ CFEqual($0, group) }).count == 1,
              try children(group).filter({ CFEqual($0, button) }).count == 1 else { return nil }
        // Missing AXWindow is expected here; conflicting or malformed identity is not.
        for control in [button, group] {
            if let raw = try value(control, kAXWindowAttribute, optional: true) {
                guard let reportedWindow = axElement(raw), CFEqual(reportedWindow, window) else { return nil }
            }
        }
        return window
    }

    private func children(_ object: AXUIElement) throws -> [AXUIElement] {
        guard let raw = try value(object, kAXChildrenAttribute) else { throw ReadError.unexpectedValue }
        return try elements(raw)
    }

    private func controlFrame(_ object: AXUIElement) throws -> CGRect {
        let attributes = try values(object, [kAXPositionAttribute, kAXSizeAttribute])
        guard let result = frame(position: attributes[0], size: attributes[1]) else { throw ReadError.unexpectedValue }
        return result
    }

    func shortcutWindow(eventTime: TimeInterval, targetPID: pid_t) -> Hit? {
        guard let app = NSRunningApplication(processIdentifier: targetPID), isEligible(app),
              let control = captureShortcutWindow(eventTime: eventTime, targetPID: targetPID) else { return nil }
        return Hit(application: app, appElement: control.appElement, window: control.window,
                   initialWindows: control.initialWindows, buttonFrame: .zero,
                   allowsApplicationHide: false, trigger: .keyboardShortcut)
    }

    func captureShortcutWindow(eventTime: TimeInterval, targetPID: pid_t) -> CloseControl? {
        let now = ProcessInfo.processInfo.systemUptime
        deadline = now + 0.55
        guard targetPID > 1, eventTime.isFinite, eventTime >= 0, now >= eventTime, now - eventTime < 0.5 else { return nil }
        do {
            let app = AXUIElementCreateApplication(targetPID)
            let initialWindows = try windows(app)
            guard let window = try element(app, kAXFocusedWindowAttribute),
                  initialWindows.contains(where: { CFEqual($0, window) }) else { return nil }
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == targetPID else { return nil }
            let attributes = try values(window, [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute,
                                                 kAXChildrenAttribute, kAXMinimizedAttribute])
            guard attributes[0] as? String == kAXWindowRole,
                  attributes[1] as? String == kAXStandardWindowSubrole,
                  try !boolean(attributes[2]), try !hasSheet(attributes[3]), try !boolean(attributes[4])
            else { return nil }
            return CloseControl(appElement: app, window: window, initialWindows: initialWindows,
                                buttonFrame: .zero, trigger: .keyboardShortcut)
        } catch { return nil }
    }

    func snapshot(for hit: Hit) -> CloseSnapshot {
        deadline = ProcessInfo.processInfo.systemUptime + 0.45
        do {
            var current = try windows(hit.appElement)
            var blocking = false
            // All windows count, including minimized windows, panels, and other Spaces.
            // Inspect sheets/modal state only while windows exist; empty is not guessed on AX errors.
            for window in current {
                do {
                    if try hasBlockingUI(window, cancellingDialog: hit.trigger == .dialogCancel && CFEqual(window, hit.window)) {
                        blocking = true; break
                    }
                } catch ReadError.unavailable(.invalidUIElement) where CFEqual(window, hit.window) {
                    // Native close can destroy the clicked window (or a child) after AXWindows
                    // enumerates it. Confirm that exact disappearance, rather than treating a
                    // dead reference as an unreadable live window. No timeout/unsupported-value
                    // fallback, extra delay, or renewed budget is allowed here.
                    let remaining = current.filter { !CFEqual($0, hit.window) }
                    let refreshed = try windows(hit.appElement)
                    guard refreshed.count == remaining.count,
                          !refreshed.contains(where: { CFEqual($0, hit.window) }),
                          remaining.allSatisfy({ original in refreshed.contains { CFEqual($0, original) } }),
                          refreshed.allSatisfy({ survivor in remaining.contains { CFEqual($0, survivor) } })
                    else { throw ReadError.unexpectedValue }
                    // Start a complete inspection of the surviving set. A second failure is
                    // terminal; never keep retrying an app with unreliable Accessibility.
                    current = refreshed
                    for survivor in current {
                        if try hasBlockingUI(survivor) { blocking = true; break }
                    }
                    break
                }
            }
            let targetPresent = current.contains { CFEqual($0, hit.window) }
            let hidden = hit.application.isHidden
            // A hidden Discord window is retained, not destroyed. Read its minimized state
            // explicitly; unsupported metadata must never authorize the compatibility path.
            var minimized = false
            if hidden && hit.allowsApplicationHide && targetPresent {
                guard let value = try bool(hit.window, kAXMinimizedAttribute) else { throw ReadError.unexpectedValue }
                minimized = value
            }
            guard hidden == hit.application.isHidden else { throw ReadError.unexpectedValue }
            return CloseSnapshot(
                windowCount: current.count,
                targetWindowPresent: targetPresent,
                hasBlockingUI: blocking,
                isReliable: true,
                hasReplacementWindow: current.contains { candidate in
                    !hit.initialWindows.contains { CFEqual($0, candidate) }
                },
                applicationHidden: hidden,
                targetWindowMinimized: minimized
            )
        } catch {
            return CloseSnapshot(windowCount: 0, targetWindowPresent: true,
                                 hasBlockingUI: false, isReliable: false)
        }
    }

    private func value(_ element: AXUIElement, _ attribute: String, optional: Bool = false) throws -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReadError.exceededBudget }
        let (error, value) = readAttribute(element, attribute as CFString)
        if optional && (error == .attributeUnsupported || error == .noValue) { return nil }
        guard error == .success else { throw ReadError.unavailable(error) }
        return value
    }

    private func string(_ object: AXUIElement, _ attribute: String) throws -> String? {
        try value(object, attribute) as? String
    }

    private func values(_ element: AXUIElement, _ attributes: [String]) throws -> [CFTypeRef] {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReadError.exceededBudget }
        let (error, result) = readAttributes(element, attributes)
        // Some providers implement individual attributes only. Preserve that compatibility
        // within the same budget; never retry a timeout, invalid element or partial result.
        if error == .notImplemented {
            let result = try attributes.map {
                guard let result = try value(element, $0) else { throw ReadError.unexpectedValue }
                return result
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReadError.exceededBudget }
            return result
        }
        guard error == .success else { throw ReadError.unavailable(error) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReadError.exceededBudget }
        guard let result, result.count == attributes.count,
              result.allSatisfy({ raw in
                  CFGetTypeID(raw) != CFNullGetTypeID() &&
                  !(CFGetTypeID(raw) == AXValueGetTypeID() && AXValueGetType(raw as! AXValue) == .axError)
              }) else { throw ReadError.unexpectedValue }
        return result
    }

    private func bool(_ object: AXUIElement, _ attribute: String, optional: Bool = false) throws -> Bool? {
        guard let raw = try value(object, attribute, optional: optional) else { return nil }
        return try boolean(raw)
    }

    private func boolean(_ raw: CFTypeRef) throws -> Bool {
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { throw ReadError.unexpectedValue }
        return (raw as! CFBoolean) == kCFBooleanTrue
    }

    private func element(_ object: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        axElement(try value(object, attribute))
    }

    private func axElement(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func windows(_ app: AXUIElement) throws -> [AXUIElement] {
        guard let raw = try value(app, kAXWindowsAttribute) else { throw ReadError.unexpectedValue }
        return try elements(raw)
    }

    private func elements(_ raw: CFTypeRef) throws -> [AXUIElement] {
        // Swift's bridging cast alone does not validate the CF type of each array member.
        guard CFGetTypeID(raw) == CFArrayGetTypeID(), let members = raw as? [CFTypeRef],
              members.count <= 64, members.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
        else { throw ReadError.unexpectedValue }
        return members.map { $0 as! AXUIElement }
    }

    private func hasBlockingUI(_ window: AXUIElement, cancellingDialog: Bool = false) throws -> Bool {
        guard let modal = try bool(window, kAXModalAttribute) else { throw ReadError.unexpectedValue }
        if modal && !cancellingDialog { return true }
        // Sheets are direct AX children of a window; there is no public AXSheets attribute.
        guard let raw = try value(window, kAXChildrenAttribute) else { throw ReadError.unexpectedValue }
        return try hasSheet(raw)
    }

    private func hasSheet(_ raw: CFTypeRef) throws -> Bool {
        let children = try elements(raw)
        for child in children {
            guard let role = try string(child, kAXRoleAttribute) else { throw ReadError.unexpectedValue }
            if role == kAXSheetRole { return true }
        }
        return false
    }

    private func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
