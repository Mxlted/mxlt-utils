#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Native HID input only; CDP is used only to read the disposable page's counters.
struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
func number(_ object: [String: Any], _ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func pause(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fixtureURL = root.appendingPathComponent("scripts/fixtures/BrowserFixture.html").absoluteString
let scenario = argument("--case") ?? ""
var held = false
var lastPoint = CGPoint.zero

func process(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process(), output = Pipe(), errors = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = output; task.standardError = errors
    try task.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { pause(0.02) }
    if task.isRunning { task.terminate(); throw Failure(description: "Read-only evidence process timed out") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    try require(task.terminationStatus == 0, "Read-only evidence process failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
    return String(decoding: data, as: UTF8.self)
}
func mouse(_ type: CGEventType, _ location: CGPoint) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center) else {
        throw Failure(description: "Could not construct a native mouse event")
    }
    event.flags = []
    event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
    lastPoint = location
    if type == .otherMouseDown { held = true }
    if type == .otherMouseUp { held = false }
}
func escape() throws {
    for pressed in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: pressed) else { throw Failure(description: "Could not construct Escape") }
        event.flags = []
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        event.post(tap: .cghidEventTap); pause(0.04)
    }
}
func ax(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = ax(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = ax(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}
func dictionary(_ rect: CGRect) -> [String: Double] { ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }

func run() throws -> [String: Any] {
    try require(["click", "scroll", "nested-scroll", "escape"].contains(scenario), "Use --pid <Chrome PID> --profile build/chrome-fixture.* --case click|scroll|nested-scroll|escape [--inspect]")
    guard let rawPID = argument("--pid"), let pid = pid_t(rawPID),
          let rawProfile = argument("--profile") else { throw Failure(description: "Exact disposable Chrome PID and profile are required") }
    let profile = URL(fileURLWithPath: rawProfile).resolvingSymlinksInPath().standardizedFileURL
    try require(profile.deletingLastPathComponent() == root.appendingPathComponent("build", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL && profile.lastPathComponent.hasPrefix("chrome-fixture."), "Refusing a profile outside build/chrome-fixture.*")
    if let requested = argument("--fixture-url") { try require(requested == fixtureURL, "Refusing a different fixture URL") }
    guard let application = NSRunningApplication(processIdentifier: pid), application.bundleIdentifier == "com.google.Chrome", !application.isTerminated else {
        throw Failure(description: "The supplied PID is not the running Chrome application")
    }
    let command = try process("/bin/ps", ["-p", String(pid), "-o", "args="])
    let profileArgument = "--user-data-dir=" + profile.path
    try require(command.contains(profileArgument + " ") && command.contains("--remote-debugging-port=0"), "Chrome process arguments do not match this exact disposable profile")
    try require(AXIsProcessTrusted(), "The invoking host needs Accessibility permission")
    func collect() throws -> [String: Any] {
        let output = try process("/usr/bin/env", ["node", root.appendingPathComponent("scripts/read-browser-evidence.mjs").path, "--profile", profile.path])
        guard let data = output.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(description: "Invalid browser evidence") }
        return result
    }
    let before = try collect()
    let originalTabs = (before["tabs"] as? [[String: Any]] ?? []).filter { object($0["evidence"])["openedLink"] as? Bool == false }
    try require(originalTabs.count == 1, "Keep exactly one original fixture tab open")
    let targetID = originalTabs[0]["targetID"] as? String ?? ""
    func evidence(_ snapshot: [String: Any]) throws -> [String: Any] {
        guard let tab = (snapshot["tabs"] as? [[String: Any]])?.first(where: { $0["targetID"] as? String == targetID }) else { throw Failure(description: "The original browser fixture tab disappeared") }
        return object(tab["evidence"])
    }
    let initial = try evidence(before)
    let appAX = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appAX, 0.12)
    guard let windows = ax(appAX, kAXWindowsAttribute) as? [AXUIElement] else { throw Failure(description: "Chrome's Accessibility windows are unavailable") }
    var queue = windows.map { ($0, $0) }, visited: [AXUIElement] = []
    var matches: [(AXUIElement, AXUIElement)] = []
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !queue.isEmpty {
        try require(visited.count < 800 && ProcessInfo.processInfo.systemUptime < deadline, "Chrome AX traversal exceeded its bound")
        let (element, window) = queue.removeFirst()
        if visited.contains(where: { CFEqual($0, element) }) { continue }
        visited.append(element)
        if ax(element, kAXRoleAttribute) as? String == "AXWebArea" {
            let urlValue = ax(element, kAXURLAttribute)
            let url = (urlValue as? URL)?.absoluteString ?? (urlValue as? String)
            if url == fixtureURL && ax(element, kAXTitleAttribute) as? String == "mxlt-utils browser fixture" { matches.append((element, window)) }
            continue
        }
        if let children = ax(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.map { ($0, window) }) }
    }
    try require(matches.count == 1, "Expected one visible AXWebArea with the exact fixture URL and title")
    guard let webFrame = frame(matches[0].0), let windowFrame = frame(matches[0].1) else { throw Failure(description: "Fixture AX frames are unavailable") }
    let viewport = object(initial["viewport"])
    let scaleX = webFrame.width / number(viewport, "width"), scaleY = webFrame.height / number(viewport, "height")
    try require(scaleX.isFinite && scaleY.isFinite && scaleX > 0.5 && scaleX < 3 && abs(scaleX - scaleY) < 0.01, "AX frame does not map consistently to the fixture viewport")
    let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let nativeWindows = metadata.filter { item in
        guard number(item, kCGWindowOwnerPID as String) == Double(pid), number(item, kCGWindowLayer as String) == 0,
              let bounds = item[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return abs(rect.minX - windowFrame.minX) < 1 && abs(rect.minY - windowFrame.minY) < 1 && abs(rect.width - windowFrame.width) < 1 && abs(rect.height - windowFrame.height) < 1
    }
    try require(nativeWindows.count == 1, "The AX fixture window does not match one native Chrome window")
    let windowID = CGWindowID(number(nativeWindows[0], kCGWindowNumber as String))
    let regionName = scenario == "nested-scroll" ? "nested" : "outer"
    let region = object(initial[regionName])
    let rect = object(scenario == "click" ? initial["link"] : region["rect"])
    let x = number(rect, "x") + (scenario == "scroll" || scenario == "escape" ? 120 : number(rect, "width") / 2)
    let y = number(rect, "y") + number(rect, "height") / 2
    let anchor = CGPoint(x: webFrame.minX + x * scaleX, y: webFrame.minY + y * scaleY)
    try require(webFrame.contains(anchor), "The fixture anchor is outside the verified web area")
    func validatePoint(_ point: CGPoint) throws {
        try require(!application.isTerminated && NSRunningApplication(processIdentifier: pid) == application, "The original Chrome process changed")
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?, hitPID: pid_t = 0
        try require(AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success && hit != nil, "The browser test point has no verified AX owner")
        try require(AXUIElementGetPid(hit!, &hitPID) == .success && hitPID == pid, "The browser test point belongs to another AX process")
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let displays = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: mainTop - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        var canvases: [pid_t: Double] = [:]
        for (bundle, layer) in [("com.apple.dock", 20.0), ("com.apple.notificationcenterui", 21.0)] {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }
            if apps.count == 1 { canvases[apps[0].processIdentifier] = layer }
        }
        let current = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = current.first { item in
            guard number(item, kCGWindowAlpha as String) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any], let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary), rectangle.contains(point) else { return false }
            if canvases[pid_t(number(item, kCGWindowOwnerPID as String))] == number(item, kCGWindowLayer as String), displays.contains(rectangle) { return false }
            return true
        }
        try require(top.map { number($0, kCGWindowOwnerPID as String) == Double(pid) && number($0, kCGWindowNumber as String) == Double(windowID) } == true, "Another native window covers the browser fixture point")
    }
    if !arguments.contains("--inspect") {
        application.activate(options: [.activateAllWindows])
        pause(0.4)
    }
    try validatePoint(anchor)
    if arguments.contains("--inspect") {
        return ["passed": true, "inputPosted": false, "case": scenario, "pid": pid, "windowID": windowID,
                "webFrame": dictionary(webFrame), "windowFrame": dictionary(windowFrame),
                "anchor": ["x": anchor.x, "y": anchor.y], "before": before]
    }
    try require(CGPreflightPostEventAccess(), "The invoking host needs permission to post events")
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "Bring the disposable Chrome fixture forward before running")
    defer { if held { try? mouse(.otherMouseUp, lastPoint) } }
    var snapshots: [String: Any] = ["before": before]
    try mouse(.mouseMoved, anchor); pause(0.1)
    try validatePoint(anchor)
    try mouse(.otherMouseDown, anchor); pause(0.08)
    if scenario == "click" {
        try mouse(.otherMouseUp, anchor); pause(0.5)
        let after = try collect(), final = try evidence(after)
        try require(number(after, "fixtureTabCount") == number(before, "fixtureTabCount") + 1 && number(after, "openedLinkTabCount") == number(before, "openedLinkTabCount") + 1, "A short middle click did not open exactly one disposable link tab")
        for key in ["middleDowns", "middleUps", "middleAuxClicks", "linkAuxClicks"] {
            try require(number(object(final["counters"]), key) - number(object(initial["counters"]), key) == 1, "Browser link did not receive exactly one paired auxiliary click")
        }
        try require(number(object(final["counters"]), "wheelEvents") == number(object(initial["counters"]), "wheelEvents"), "Short middle click unexpectedly scrolled")
        snapshots["after"] = after
    } else {
        try require(number(region, "offsetX") == 0 && number(region, "offsetY") == 0, "Reload the fixture before scrolling checks")
        let displaced = CGPoint(x: anchor.x + 65, y: anchor.y + 65)
        try validatePoint(displaced)
        try mouse(.otherMouseDragged, displaced); pause(0.35)
        let moving = try collect(), movingEvidence = try evidence(moving), movingRegion = object(movingEvidence[regionName])
        try require(number(movingRegion, "wheelEvents") > number(region, "wheelEvents") && number(movingRegion, "offsetX") > 0 && number(movingRegion, "offsetY") > 0, "Held movement did not scroll both browser axes")
        pause(0.3)
        let stationary = try collect(), stationaryEvidence = try evidence(stationary), stationaryRegion = object(stationaryEvidence[regionName])
        try require(number(stationaryRegion, "wheelEvents") > number(movingRegion, "wheelEvents") && number(stationaryRegion, "offsetY") > number(movingRegion, "offsetY"), "Browser scrolling did not continue with the pointer stationary")
        guard let cursor = CGEvent(source: nil)?.location else { throw Failure(description: "Could not read the synthetic pointer position") }
        try require(hypot(cursor.x - displaced.x, cursor.y - displaced.y) < 4, "Synthetic scrolling snapped the pointer away from the held position")
        if scenario == "escape" {
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "Chrome lost keyboard focus before Escape")
            try escape()
        } else { try mouse(.otherMouseDragged, anchor) }
        pause(0.25)
        let stopped = try collect(), stoppedEvidence = try evidence(stopped)
        pause(0.3)
        let still = try collect()
        try require(number(object(try evidence(still)["counters"]), "wheelEvents") == number(object(stoppedEvidence["counters"]), "wheelEvents"), "Browser scroll continued after dead-zone return or Escape")
        for key in ["offsetX", "offsetY"] {
            try require(abs(number(object(try evidence(still)[regionName]), key) - number(object(stoppedEvidence[regionName]), key)) < 1,
                        "The browser viewport kept moving after cancellation settled")
        }
        try mouse(.otherMouseUp, lastPoint); pause(0.3)
        let after = try collect(), final = try evidence(after)
        try require(number(object(final["counters"]), "wheelEvents") == number(object(stoppedEvidence["counters"]), "wheelEvents"), "Browser scrolling continued after release")
        for key in ["offsetX", "offsetY"] {
            try require(abs(number(object(final[regionName]), key) - number(object(stoppedEvidence[regionName]), key)) < 1,
                        "The browser viewport moved after release")
        }
        for key in ["middleDowns", "middleUps", "middleAuxClicks", "linkAuxClicks"] {
            try require(number(object(final["counters"]), key) == number(object(initial["counters"]), key), "A consumed browser gesture leaked a middle-button event")
        }
        try require(number(after, "fixtureTabCount") == number(before, "fixtureTabCount"), "A scroll gesture opened an extra fixture tab")
        if scenario == "nested-scroll" {
            for key in ["offsetX", "offsetY"] { try require(number(object(final["outer"]), key) == number(object(initial["outer"]), key), "Nested browser scrolling moved the outer grid") }
        }
        snapshots.merge(["moving": moving, "stationary": stationary, "stopped": stopped, "after": after]) { _, latest in latest }
    }
    return ["case": scenario, "passed": true, "pid": pid, "windowID": windowID,
            "evidence": "Native synthetic HID events through the running utility; read-only DOM and tab snapshots", "snapshots": snapshots]
}
do {
    let result = try run()
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch {
    if held { try? mouse(.otherMouseUp, lastPoint) }
    let result: [String: Any] = ["case": scenario, "passed": false, "error": String(describing: error)]
    print(String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self))
    exit(1)
}
