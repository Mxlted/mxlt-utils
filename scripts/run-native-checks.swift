#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Drives only the disposable fixture through the real WindowServer/event-tap path.
// These are synthetic-input checks, never evidence of physical mouse behavior.
struct CheckFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}
let arguments = ProcessInfo.processInfo.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
func number(_ dictionary: [String: Any], _ key: String) -> Double { (dictionary[key] as? NSNumber)?.doubleValue ?? 0 }
func point(_ dictionary: [String: Any]) -> CGPoint { CGPoint(x: number(dictionary, "x"), y: number(dictionary, "y")) }
// Pump the main run loop so NSRunningApplication termination/activation state stays current.
func pause(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
let statePath = argument("--state-path") ?? ""
let scenario = argument("--case") ?? ""
let supported = ["click", "passthrough-click", "wheel", "scroll", "nested-scroll", "escape", "quit", "cancel-close", "replacement", "remaining-window", "tab-remains", "command-remains", "pin-target", "pause-held", "disable-held", "toggle-cycles"]
var restorationErrors: [String] = []
var middleHeld = false
var lastPoint = CGPoint.zero
func mouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
        throw CheckFailure(description: "Could not construct a native mouse event")
    }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    event.post(tap: .cghidEventTap)
    lastPoint = location
    if type == .otherMouseDown { middleHeld = true }
    if type == .otherMouseUp { middleHeld = false }
}
func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
    // Each test chord owns its synthetic modifiers and releases them even on failure.
    defer {
        if !flags.isEmpty, let release = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false) {
            release.type = .flagsChanged
            release.flags = []
            release.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            release.post(tap: .cghidEventTap)
            pause(0.04)
        }
    }
    for pressed in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: pressed) else {
            throw CheckFailure(description: "Could not construct a native key event")
        }
        event.flags = flags
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        event.post(tap: .cghidEventTap)
        pause(0.04)
    }
}
func readState() throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
    guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure(description: "Invalid fixture state")
    }
    return state
}
func windows(_ state: [String: Any]) -> [[String: Any]] { state["windows"] as? [[String: Any]] ?? [] }
func events(_ state: [String: Any]) -> [String] { (state["events"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String } }
func scroll(_ window: [String: Any]) -> [String: Any] { window[scenario == "nested-scroll" ? "nestedScroll" : "scroll"] as? [String: Any] ?? [:] }

/// Uses the app's real public Settings controls, without synthetic clicks/keys or test hooks.
/// The Settings window must already be open on General and must not cover the fixture anchor.
final class UtilityControls {
    private let application: NSRunningApplication
    private let root: AXUIElement
    let initialScroll: Bool
    let initialPaused: Bool
    let initialQuit: Bool

    init() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mxlted.mxlt-utils")
            .filter { !$0.isTerminated }
        guard running.count == 1 else { throw CheckFailure(description: "Lifecycle checks need exactly one running mxlt-utils app") }
        application = running[0]
        root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        initialScroll = try Self.checkbox("Middle scrolling", root: root)
        initialQuit = try Self.checkbox("CallQuits", root: root)
        initialPaused = try Self.paused(root: root)
    }
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func find(_ label: String, role: String, root: AXUIElement) throws -> AXUIElement? {
        guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            throw CheckFailure(description: "Open mxlt-utils Settings → General before lifecycle checks")
        }
        var queue = windows
        var visited: [AXUIElement] = []
        var matches: [AXUIElement] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !queue.isEmpty {
            try require(visited.count < 400 && ProcessInfo.processInfo.systemUptime < deadline, "mxlt-utils Settings AX traversal exceeded its bound")
            let element = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            if value(element, kAXRoleAttribute) as? String == role,
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { value(element, $0) as? String == label }) {
                matches.append(element)
            }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        try require(matches.count <= 1, "Ambiguous mxlt-utils control: \(label)")
        return matches.first
    }
    private static func checkbox(_ label: String, root: AXUIElement) throws -> Bool {
        guard let element = try find(label, role: kAXCheckBoxRole, root: root),
              let state = value(element, kAXValueAttribute) as? NSNumber else {
            throw CheckFailure(description: "Cannot read the \(label) checkbox; open Settings → General")
        }
        return state.boolValue
    }
    private static func paused(root: AXUIElement) throws -> Bool {
        if try find("Resume features", role: kAXButtonRole, root: root) != nil { return true }
        if try find("Pause all features", role: kAXButtonRole, root: root) != nil { return false }
        throw CheckFailure(description: "Cannot read the public Pause/Resume control")
    }
    private func validate() throws {
        try require(!application.isTerminated && NSRunningApplication(processIdentifier: application.processIdentifier) == application,
                    "The original mxlt-utils process changed; refusing to change controls")
    }
    private func press(_ label: String, role: String) throws {
        try validate()
        guard let element = try Self.find(label, role: role, root: root) else {
            throw CheckFailure(description: "Missing mxlt-utils control \(label)")
        }
        try require(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success,
                    "Could not press mxlt-utils control \(label)")
    }
    func setScroll(_ enabled: Bool) throws {
        if try Self.checkbox("Middle scrolling", root: root) != enabled { try press("Middle scrolling", role: kAXCheckBoxRole) }
        pause(0.2)
        try require(try Self.checkbox("Middle scrolling", root: root) == enabled, "Middle scrolling control did not reach the requested state")
    }
    func setPaused(_ paused: Bool) throws {
        if try Self.paused(root: root) != paused { try press(paused ? "Pause all features" : "Resume features", role: kAXButtonRole) }
        pause(0.2)
        try require(try Self.paused(root: root) == paused, "Pause control did not reach the requested state")
    }
    func assertQuitUnchanged() throws {
        try require(try Self.checkbox("CallQuits", root: root) == initialQuit, "The scrolling lifecycle changed CallQuits' enabled setting")
    }
    func restore() throws {
        try setScroll(initialScroll)
        try setPaused(initialPaused)
        try assertQuitUnchanged()
    }
}

func run() throws -> [String: Any] {
    try require(!statePath.isEmpty && supported.contains(scenario), "Usage: swift scripts/run-native-checks.swift --state-path build/fixture-state.json --case \(supported.joined(separator: "|"))")
    try require(CGPreflightPostEventAccess(), "The runner host needs permission to post events. Grant Accessibility to the invoking terminal/app before running.")
    let initial = try readState()
    let pid = pid_t(number(initial, "pid"))
    try require(initial["bundleID"] as? String == "com.mxlted.mxlt-utils.fixture", "Refusing a non-fixture state file")
    guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.mxlted.mxlt-utils.fixture",
          !app.isTerminated else { throw CheckFailure(description: "The disposable fixture is not running") }
    try require(ProcessInfo.processInfo.systemUptime - number(initial, "uptime") < 2, "Fixture state is stale")
    guard let target = windows(initial).last(where: { $0["minimized"] as? Bool == false }) else {
        throw CheckFailure(description: "No visible disposable window")
    }
    let windowID = CGWindowID(number(target, "windowID"))
    func validate() throws {
        try require(!app.isTerminated && NSRunningApplication(processIdentifier: pid) == app,
                    "The original fixture process ended; refusing to redirect input")
        let metadata = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
        try require(metadata.contains { number($0, kCGWindowNumber as String) == Double(windowID) && number($0, kCGWindowOwnerPID as String) == Double(pid) },
                    "The original fixture window is invalid; refusing to redirect input")
    }
    func validatePoint(_ location: CGPoint) throws {
        let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let displays = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: mainTop - $0.frame.maxY,
                                                    width: $0.frame.width, height: $0.frame.height) }
        var canvasLayersByPID: [pid_t: Double] = [:]
        for (bundleID, layer) in [("com.apple.dock", 20.0), ("com.apple.notificationcenterui", 21.0)] {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            if applications.count == 1 { canvasLayersByPID[applications[0].processIdentifier] = layer }
        }
        var checkedSystemHit = false
        var systemHitPID: pid_t?
        func fixtureOwnsSystemHit() -> Bool {
            if !checkedSystemHit {
                checkedSystemHit = true
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, 0.12)
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &hit) == .success,
                   let hit {
                    var hitPID: pid_t = 0
                    if AXUIElementGetPid(hit, &hitPID) == .success { systemHitPID = hitPID }
                }
            }
            return systemHitPID == pid
        }
        let hit = metadata.first { item in
            guard number(item, kCGWindowAlpha as String) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            // Newer macOS exposes full-screen system canvases above normal windows.
            // Skip only known unique process/layer pairs, exact display geometry AND a
            // positive AX hit owned by the fixture. Active system UI and unknown AX block.
            if let expectedLayer = canvasLayersByPID[pid_t(number(item, kCGWindowOwnerPID as String))],
               number(item, kCGWindowLayer as String) == expectedLayer,
               displays.contains(rectangle), fixtureOwnsSystemHit() { return false }
            return rectangle.contains(location)
        }
        if hit.map({ number($0, kCGWindowOwnerPID as String) == Double(pid) }) != true {
            _ = fixtureOwnsSystemHit()
            let nativePID = hit.map { Int(number($0, kCGWindowOwnerPID as String)) }
            let nativeWindow = hit.map { Int(number($0, kCGWindowNumber as String)) }
            let nativeLayer = hit.map { Int(number($0, kCGWindowLayer as String)) }
            throw CheckFailure(description: "Another application covers the test point; refusing to inject a click " +
                "(expectedPID=\(pid), nativePID=\(nativePID.map(String.init) ?? "none"), " +
                "nativeWindow=\(nativeWindow.map(String.init) ?? "none"), nativeLayer=\(nativeLayer.map(String.init) ?? "none"), " +
                "systemAXHitPID=\(systemHitPID.map(String.init) ?? "unavailable"))")
        }
    }
    func currentWindow() throws -> [String: Any] {
        guard let window = windows(try readState()).first(where: { number($0, "windowID") == Double(windowID) }) else {
            throw CheckFailure(description: "The original fixture window disappeared")
        }
        return window
    }
    func click(_ location: CGPoint) throws {
        try validate()
        try mouse(.mouseMoved, at: location, button: .left); pause(0.12)
        try validatePoint(location)
        try mouse(.leftMouseDown, at: location, button: .left); pause(0.09)
        try mouse(.leftMouseUp, at: location, button: .left)
    }
    func control(_ name: String) throws -> CGPoint {
        let state = try currentWindow()
        guard let points = state["controls"] as? [String: [String: Any]], let value = points[name] else {
            throw CheckFailure(description: "Missing fixture control \(name)")
        }
        return point(value)
    }
    func waitFor(_ description: String, timeout: Double = 3, _ predicate: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat { if try predicate() { return }; pause(0.05) } while ProcessInfo.processInfo.systemUptime < deadline
        throw CheckFailure(description: description)
    }
    app.activate(options: [.activateAllWindows]); pause(0.4)
    try validate()
    let originalScroll = scroll(try currentWindow())
    guard let anchorValue = originalScroll["anchor"] as? [String: Any] else { throw CheckFailure(description: "Missing scroll anchor") }
    let anchor = point(anchorValue)
    try validatePoint(anchor)
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                "The fixture is not frontmost; refusing to inject keyboard or button input")
    defer {
        // Release the injected physical button state even when a check fails mid-gesture.
        if middleHeld { try? mouse(.otherMouseUp, at: lastPoint, button: .center) }
    }
    let start = ProcessInfo.processInfo.systemUptime
    switch scenario {
    case "click", "passthrough-click":
        try mouse(.mouseMoved, at: anchor, button: .center); pause(0.1)
        try mouse(.otherMouseDown, at: anchor, button: .center); pause(0.07)
        try mouse(.otherMouseUp, at: anchor, button: .center); pause(0.4)
        let after = try currentWindow()
        for counter in ["middleDowns", "middleUps", "middleClicks"] {
            try require(number(after, counter) - number(target, counter) == 1, "Short middle click must deliver exactly one \(counter)")
        }
        let expectedReplays = scenario == "click" ? 1.0 : 0.0
        for counter in ["replayedDowns", "replayedUps"] {
            try require(number(after, counter) - number(target, counter) == expectedReplays,
                        scenario == "click" ? "The click was not replayed by mxlt-utils; interception is unproven" : "Disabled/excluded scrolling unexpectedly replayed the click")
        }
        try require(number(after, "unmatchedUps") == number(target, "unmatchedUps"), "Middle-up arrived without its down")
        let viewBefore = originalScroll["middle"] as? [String: Any] ?? [:]
        let viewAfter = scroll(after)["middle"] as? [String: Any] ?? [:]
        for counter in ["downs", "ups", "actions"] {
            try require(number(viewAfter, counter) - number(viewBefore, counter) == 1,
                        "Short middle click did not deliver one paired action to the actual content view")
        }
        try require(number(viewAfter, "unmatchedUps") == number(viewBefore, "unmatchedUps"), "Content view received an unmatched middle-up")
        try require(number(scroll(after), "events") == number(originalScroll, "events"), "Short middle click unexpectedly scrolled")
    case "wheel":
        try mouse(.mouseMoved, at: anchor, button: .center); pause(0.1)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -48, wheel2: -48, wheel3: 0) else {
            throw CheckFailure(description: "Could not construct a native wheel event")
        }
        event.location = anchor
        event.flags = []
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        event.post(tap: .cghidEventTap)
        pause(0.3)
        let after = scroll(try currentWindow())
        try require(number(after, "events") > number(originalScroll, "events"), "Ordinary wheel input did not reach the fixture")
        try require(number(after, "taggedEvents") == number(originalScroll, "taggedEvents"), "Ordinary wheel input was rewritten by mxlt-utils")
        try require(number(after, "offsetX") > number(originalScroll, "offsetX") && number(after, "offsetY") > number(originalScroll, "offsetY"), "Ordinary wheel input did not scroll the native view")
    case "scroll", "nested-scroll", "escape", "pin-target":
        try mouse(.mouseMoved, at: anchor, button: .center); pause(0.1)
        try mouse(.otherMouseDown, at: anchor, button: .center); pause(0.1)
        var displaced = CGPoint(x: anchor.x + 65, y: anchor.y + 65)
        if scenario == "pin-target" {
            guard let other = windows(initial).first(where: { number($0, "windowID") != Double(windowID) }),
                  let frame = other["frame"] as? [String: Any] else { throw CheckFailure(description: "pin-target needs --windows=2") }
            displaced = CGPoint(x: number(frame, "x") + 10, y: number(frame, "y") + 100)
        }
        try mouse(.otherMouseDragged, at: displaced, button: .center); pause(0.4)
        let moving = scroll(try currentWindow())
        try require(number(moving, "events") > number(originalScroll, "events"), "Holding outside the dead zone did not scroll through the running app")
        try require(number(moving, "taggedEvents") > number(originalScroll, "taggedEvents"), "No scroll event was identified as mxlt-utils output")
        if scenario != "pin-target" {
            try require(number(moving, "offsetX") > number(originalScroll, "offsetX") && number(moving, "offsetY") > number(originalScroll, "offsetY"),
                        "Down/right movement did not advance both native scroll axes; use default direction and a fresh fixture")
        }
        pause(0.35)
        let stationary = scroll(try currentWindow())
        try require(number(stationary, "taggedEvents") > number(moving, "taggedEvents"), "Scrolling did not continue while the pointer was stationary")
        if scenario == "escape" {
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "Fixture lost keyboard focus")
            try key(53)
        }
        else { try mouse(.otherMouseDragged, at: anchor, button: .center) }
        pause(0.25)
        let stopped = scroll(try currentWindow())
        pause(0.3)
        try require(number(scroll(try currentWindow()), "events") == number(stopped, "events"), "Scrolling continued after returning to the dead zone or Escape")
        try mouse(.otherMouseUp, at: lastPoint, button: .center); pause(0.25)
        let released = try currentWindow()
        pause(0.3)
        try require(number(scroll(try currentWindow()), "events") == number(scroll(released), "events"), "Scrolling continued after middle release")
        try require(number(released, "middleClicks") == number(target, "middleClicks"), "A scroll gesture also activated a middle click")
        try require(number(released, "middleDowns") == number(target, "middleDowns") && number(released, "middleUps") == number(target, "middleUps"), "A consumed scroll gesture leaked button events")
        if scenario == "nested-scroll" {
            let outerBefore = target["scroll"] as? [String: Any] ?? [:]
            let outerAfter = released["scroll"] as? [String: Any] ?? [:]
            try require(number(outerBefore, "events") == number(outerAfter, "events"), "Nested scrolling unexpectedly reached the outer scroll view")
        }
        if scenario == "pin-target" {
            for other in windows(try readState()) where number(other, "windowID") != Double(windowID) {
                let baseline = windows(initial).first { number($0, "windowID") == number(other, "windowID") } ?? [:]
                try require(number(scroll(other), "events") == number(scroll(baseline), "events"), "Crossing a window edge redirected scroll to another window")
            }
        }
    case "pause-held", "disable-held", "toggle-cycles":
        let controls = try UtilityControls()
        try require(controls.initialScroll && !controls.initialPaused, "Start lifecycle cases with middle scrolling on and global pause off")
        defer {
            if middleHeld { try? mouse(.otherMouseUp, at: lastPoint, button: .center) }
            do { try controls.restore() } catch { restorationErrors.append(String(describing: error)) }
        }
        func shortClick(expectingReplay: Bool) throws {
            try validate(); try validatePoint(anchor)
            let before = try currentWindow()
            try mouse(.mouseMoved, at: anchor, button: .center); pause(0.08)
            try mouse(.otherMouseDown, at: anchor, button: .center); pause(0.07)
            try mouse(.otherMouseUp, at: anchor, button: .center); pause(0.35)
            let after = try currentWindow()
            for counter in ["middleDowns", "middleUps", "middleClicks"] {
                try require(number(after, counter) - number(before, counter) == 1, "Lifecycle transition broke paired click delivery")
            }
            for counter in ["replayedDowns", "replayedUps"] {
                try require(number(after, counter) - number(before, counter) == (expectingReplay ? 1 : 0),
                            "Lifecycle transition did not produce the expected interception state")
            }
            try require(number(after, "unmatchedUps") == number(before, "unmatchedUps"), "Lifecycle transition leaked an unmatched up")
            let viewBefore = scroll(before)["middle"] as? [String: Any] ?? [:]
            let viewAfter = scroll(after)["middle"] as? [String: Any] ?? [:]
            for counter in ["downs", "ups", "actions"] {
                try require(number(viewAfter, counter) - number(viewBefore, counter) == 1,
                            "Lifecycle transition failed to deliver the click to the actual content view")
            }
            try require(number(viewAfter, "unmatchedUps") == number(viewBefore, "unmatchedUps"), "Lifecycle transition leaked an unmatched view-level up")
            try controls.assertQuitUnchanged()
        }
        if scenario == "toggle-cycles" {
            for _ in 0..<3 {
                try controls.setScroll(false)
                try shortClick(expectingReplay: false)
                try controls.setScroll(true)
                try shortClick(expectingReplay: true)
            }
        } else {
            try mouse(.mouseMoved, at: anchor, button: .center); pause(0.1)
            try mouse(.otherMouseDown, at: anchor, button: .center); pause(0.1)
            let displaced = CGPoint(x: anchor.x + 65, y: anchor.y + 65)
            try mouse(.otherMouseDragged, at: displaced, button: .center); pause(0.35)
            try require(number(scroll(try currentWindow()), "taggedEvents") > number(originalScroll, "taggedEvents"),
                        "Lifecycle cancellation is unproven because tagged scrolling never started")
            if scenario == "pause-held" { try controls.setPaused(true) } else { try controls.setScroll(false) }
            try validatePoint(anchor) // An obscuring Settings window must not masquerade as pause cleanup.
            let stopped = scroll(try currentWindow())
            pause(0.3)
            try require(number(scroll(try currentWindow()), "events") == number(stopped, "events"), "Scrolling continued while paused or disabled")
            if scenario == "pause-held" { try controls.setPaused(false) } else { try controls.setScroll(true) }
            try mouse(.otherMouseDragged, at: CGPoint(x: displaced.x + 10, y: displaced.y + 10), button: .center)
            pause(0.3)
            try require(number(scroll(try currentWindow()), "events") == number(stopped, "events"), "Resuming revived the canceled held gesture")
            try mouse(.otherMouseUp, at: lastPoint, button: .center); pause(0.25)
            let released = try currentWindow()
            try require(number(released, "middleDowns") == number(target, "middleDowns") && number(released, "middleUps") == number(target, "middleUps"),
                        "Pause/disable leaked a suppressed button half")
            try require(number(released, "middleClicks") == number(target, "middleClicks"), "Pause/disable replayed a canceled click")
            try shortClick(expectingReplay: true)
        }
    case "quit":
        try click(control("redClose"))
        try waitFor("A clean final red-button close did not request graceful quit", timeout: 5) { app.isTerminated }
        let final = try readState()
        try require(events(final).contains("graceful quit requested") && events(final).contains("application will terminate"), "Fixture exited without evidence of graceful quit")
    case "cancel-close":
        try require(target["dirty"] as? Bool == true, "cancel-close needs a fixture launched with --dirty")
        try click(control("redClose"))
        try waitFor("Expected the native save sheet") { try currentWindow()["sheet"] as? Bool == true }
        guard let buttons = try currentWindow()["sheetButtons"] as? [String: [String: Any]], let cancel = buttons["Cancel"] else {
            throw CheckFailure(description: "The native Cancel button was not exposed")
        }
        try click(point(cancel)); pause(3.4)
        let canceled = try currentWindow()
        try require(!app.isTerminated && canceled["dirty"] as? Bool == true && canceled["sheet"] as? Bool == false,
                    "Cancel did not dismiss the sheet and preserve the dirty window")
        let cancelEvents = events(try readState())
        try require(cancelEvents.contains("close sheet canceled"), "The fixture did not observe native sheet cancellation")
        try require(!cancelEvents.contains("graceful quit requested"), "A canceled close later requested quit")
    case "replacement", "remaining-window":
        if scenario == "remaining-window" { try require(windows(initial).count > 1, "remaining-window needs --windows=2") }
        try click(control("redClose")); pause(3.4)
        let final = try readState()
        try require(!app.isTerminated && !windows(final).isEmpty, "A remaining or replacement window did not protect the fixture")
        try require(!events(final).contains("graceful quit requested"), "A remaining or replacement window received a quit request")
        try require(windows(final).allSatisfy { number($0, "windowID") != Double(windowID) }, "The target window did not actually close")
        if scenario == "remaining-window" {
            try require(windows(final).count == windows(initial).count - 1, "The remaining-window count was unexpected")
        }
    case "tab-remains", "command-remains":
        try require(number(target, "tabs") > 1, "This case needs --tabs=2")
        if scenario == "tab-remains" { try click(control("tabClose")) } else {
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "Fixture lost keyboard focus")
            try key(13, flags: .maskCommand)
        }
        pause(0.6)
        try require(!app.isTerminated && number(try currentWindow(), "tabs") == number(target, "tabs") - 1, "Closing one tab must keep its window and application")
    default: break
    }
    return ["case": scenario, "passed": true, "evidence": "synthetic CGEvent through the running app", "fixturePID": pid,
            "duration": ProcessInfo.processInfo.systemUptime - start, "finalState": try readState()]
}
do {
    let result = try run()
    try require(restorationErrors.isEmpty, "Could not restore settings: \(restorationErrors.joined(separator: "; "))")
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    if middleHeld { try? mouse(.otherMouseUp, at: lastPoint, button: .center) }
    let result: [String: Any] = ["case": scenario, "passed": false, "error": String(describing: error), "restorationErrors": restorationErrors]
    let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
    exit(1)
}
