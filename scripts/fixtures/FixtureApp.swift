// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import AppKit

private func fixtureLog(_ event: String) {
    FixtureEvidence.shared.record(event)
    fflush(stdout)
}

/// Fixture-only evidence: bounded lifecycle messages and aggregate counters, never input streams.
private final class FixtureEvidence {
    static let shared = FixtureEvidence()
    var events: [[String: Any]] = []
    var statePath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--state-path"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    func record(_ event: String) {
        let entry: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime, "event": event]
        events.append(entry)
        if events.count > 80 { events.removeFirst(events.count - 80) }
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
    func write(_ controllers: [FixtureWindowController]) {
        guard let statePath else { return }
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                   "bundleID": Bundle.main.bundleIdentifier ?? "",
                                   "uptime": ProcessInfo.processInfo.systemUptime,
                                   "windows": controllers.compactMap { $0.evidence() },
                                   "appScroll": (NSApp as? FixtureApplication)?.scrollEvidence ?? ["subclassActive": false],
                                   "events": events]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}

private func eventPoint(_ point: NSPoint) -> [String: Double] {
    // AppKit's global y axis is inverted around the main display's top edge for CGEvent.
    ["x": point.x, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - point.y]
}

private func center(of view: NSView) -> [String: Double]? {
    guard let window = view.window else { return nil }
    return eventPoint(window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)))
}

/// Aggregate receipt diagnostics distinguish WindowServer delivery from view dispatch.
@objc(MxltUtilsFixtureApplication)
final class FixtureApplication: NSApplication {
    private var received = 0
    private var tagged = 0
    private var expectedWindow = 0
    private var zeroWindow = 0
    private var otherWindow = 0
    private var insideContent = 0
    private var outsideContent = 0
    private var unresolvedWindow = 0
    private var lastScrollPoint: [String: Any] = [:]

    var scrollEvidence: [String: Any] {
        ["subclassActive": true, "events": received, "taggedEvents": tagged,
         "expectedWindow": expectedWindow, "zeroWindow": zeroWindow, "otherWindow": otherWindow,
         "insideContent": insideContent, "outsideContent": outsideContent, "unresolvedWindow": unresolvedWindow,
         "lastPoint": lastScrollPoint]
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            received += 1
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x4D584C54 { tagged += 1 }
            let fixtureWindows = (delegate as? FixtureDelegate)?.controllers.compactMap(\.window) ?? []
            let expected = fixtureWindows.first { $0.windowNumber == event.windowNumber }
            if event.windowNumber == 0 { zeroWindow += 1 }
            else if expected != nil { expectedWindow += 1 }
            else { otherWindow += 1 }
            if let window = expected, let content = window.contentView {
                let location = content.convert(event.locationInWindow, from: nil)
                let global = window.convertToScreen(content.convert(content.bounds, to: nil))
                let topLeft = eventPoint(NSPoint(x: global.minX, y: global.maxY))
                lastScrollPoint = [
                    "locationInWindow": ["x": event.locationInWindow.x, "y": event.locationInWindow.y],
                    "locationInContent": ["x": location.x, "y": location.y],
                    "cgLocation": event.cgEvent.map { ["x": $0.location.x, "y": $0.location.y] } ?? [:],
                    "contentBounds": ["x": content.bounds.minX, "y": content.bounds.minY,
                                      "width": content.bounds.width, "height": content.bounds.height],
                    "contentGlobalFrame": ["x": topLeft["x"]!, "y": topLeft["y"]!,
                                           "width": global.width, "height": global.height]
                ]
                if content.bounds.contains(location) { insideContent += 1 } else { outsideContent += 1 }
            } else { unresolvedWindow += 1 }
        }
        super.sendEvent(event)
    }
}

private final class FixtureWindow: NSWindow {
    var middleDowns = 0
    var middleUps = 0
    var middleClicks = 0
    var replayedDowns = 0
    var replayedUps = 0
    var unmatchedUps = 0
    private var middlePressed = false

    override func sendEvent(_ event: NSEvent) {
        if event.buttonNumber == 2 {
            let replayed = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x4D584C54
            if event.type == .otherMouseDown {
                middleDowns += 1
                if replayed { replayedDowns += 1 }
                middlePressed = true
            } else if event.type == .otherMouseUp {
                middleUps += 1
                if replayed { replayedUps += 1 }
                if middlePressed { middleClicks += 1 } else { unmatchedUps += 1 }
                middlePressed = false
            }
        }
        super.sendEvent(event)
    }
}

private final class FixtureScrollView: NSScrollView {
    var scrollEvents = 0
    var taggedEvents = 0
    var deltaX = 0.0
    var deltaY = 0.0

    override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x4D584C54 { taggedEvents += 1 }
        deltaX += event.scrollingDeltaX
        deltaY += event.scrollingDeltaY
        super.scrollWheel(with: event)
    }

    var evidence: [String: Any] {
        ["events": scrollEvents, "taggedEvents": taggedEvents, "deltaX": deltaX, "deltaY": deltaY,
         "offsetX": contentView.bounds.minX, "offsetY": contentView.bounds.minY,
         "middle": (documentView as? FixtureGrid)?.middleEvidence ?? [:],
         "anchor": center(of: contentView) ?? [:]]
    }
}

private final class FixtureGrid: NSView {
    private var middleDowns = 0
    private var middleUps = 0
    private var middleActions = 0
    private var unmatchedUps = 0
    private var middlePressed = false
    var middleEvidence: [String: Int] {
        ["downs": middleDowns, "ups": middleUps, "actions": middleActions, "unmatchedUps": unmatchedUps]
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        middleDowns += 1
        middlePressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        middleUps += 1
        if middlePressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            middleActions += 1
            needsDisplay = true
        } else { unmatchedUps += 1 }
        middlePressed = false
    }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        for row in 0..<30 {
            for column in 0..<16 {
                let rect = NSRect(x: column * 100 + 5, y: row * 50 + 5, width: 90, height: 40)
                guard rect.intersects(dirtyRect) else { continue }
                (row % 2 == 0 ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.separatorColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                "\(column), \(row)".draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 10),
                                        withAttributes: [.foregroundColor: NSColor.labelColor])
            }
        }
        if middleActions > 0 {
            "Middle-click actions: \(middleActions)".draw(at: NSPoint(x: 8, y: 8),
                withAttributes: [.foregroundColor: NSColor.labelColor,
                                 .backgroundColor: NSColor.textBackgroundColor])
        }
    }
}

// Browser-style hit testing can expose a rendering group beside the semantic
// tab group. Keep the real NSButton and its normal action in the tab hierarchy.
private final class FixtureTabCloseButton: NSButton {
    weak var renderingHit: NSAccessibilityElement?

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        renderingHit ?? super.accessibilityHitTest(point)
    }
}

private final class FixtureTabRenderingElement: NSAccessibilityElement {
    weak var tabGroup: NSView?

    override func accessibilityFrame() -> NSRect { tabGroup?.accessibilityFrame() ?? .zero }
    override func accessibilityWindow() -> Any? { tabGroup?.window }
    override func accessibilityTopLevelUIElement() -> Any? { tabGroup?.window }
}

private final class FixtureTabStrip: NSStackView {
    private let tabGroup: NSView
    private let renderingHit = FixtureTabRenderingElement()

    init(tabGroup: NSView, closeButton: FixtureTabCloseButton) {
        self.tabGroup = tabGroup
        super.init(frame: .zero)
        addArrangedSubview(tabGroup)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        renderingHit.tabGroup = tabGroup
        renderingHit.setAccessibilityRole(.group)
        renderingHit.setAccessibilityParent(self)
        renderingHit.setAccessibilityChildren([])
        closeButton.renderingHit = renderingHit
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? { [tabGroup, renderingHit] }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        if tabGroup.accessibilityFrame().contains(point) {
            return renderingHit
        }
        return super.accessibilityHitTest(point)
    }
}

// A disposable app that deliberately stays running after its last window closes.
// All its document state is in memory; no user documents are opened or written.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var controllers: [FixtureWindowController] = []
    var nextNumber = 1
    private var evidenceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fixtureLog("application launched")
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit mxlt-utils Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        newItem.target = self
        let newTab = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        newTab.target = self
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        closeTab.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
        let arguments = ProcessInfo.processInfo.arguments
        let count = arguments.first(where: { $0.hasPrefix("--windows=") }).flatMap { Int($0.dropFirst(10)) } ?? 1
        for _ in 0..<min(5, max(1, count)) { newWindow() }
        if arguments.contains("--minimize-first"), controllers.count > 1 { controllers.first?.window?.miniaturize(nil) }
        evidenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            FixtureEvidence.shared.write(self?.controllers ?? [])
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidHide(_ notification: Notification) { fixtureLog("application hidden") }
    func applicationDidUnhide(_ notification: Notification) { fixtureLog("application unhidden") }
    func applicationWillTerminate(_ notification: Notification) {
        evidenceTimer?.invalidate()
        fixtureLog("application will terminate")
        FixtureEvidence.shared.write(controllers)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        fixtureLog("graceful quit requested")
        let dirtyWindows = controllers.compactMap(\.window).filter(\.isDocumentEdited)
        guard let first = dirtyWindows.first else { return .terminateNow }
        guard dirtyWindows.allSatisfy({ $0.attachedSheet == nil }) else {
            fixtureLog("quit canceled: sheet present")
            return .terminateCancel
        }
        let alert = NSAlert()
        alert.messageText = "Save remaining disposable documents?"
        alert.informativeText = "There are \(dirtyWindows.count) unsaved documents. Cancel must keep the app running after a normal quit request. No actual files are written."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: first) { response in
            let shouldQuit = response != .alertSecondButtonReturn
            fixtureLog(shouldQuit ? "quit sheet accepted" : "quit sheet canceled")
            if shouldQuit { dirtyWindows.forEach { $0.isDocumentEdited = false } }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    @objc func newWindow() {
        let controller = FixtureWindowController(number: nextNumber, owner: self)
        nextNumber += 1
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        fixtureLog("window opened")
    }

    @objc func newTab() { controllers.first { $0.window === NSApp.keyWindow }?.addTab() }
    @objc func closeTab() { controllers.first { $0.window === NSApp.keyWindow }?.closeTab() }
}

final class FixtureWindowController: NSWindowController, NSWindowDelegate {
    weak var fixtureOwner: FixtureDelegate?
    var allowCloseOnce = false
    var shouldReplace = false
    var shouldHideOnClose = false
    private var tabCount = 1
    private let tabLabel = NSTextField(labelWithString: "Tabs: 1")
    private let scrollView = FixtureScrollView()
    private let nestedScrollView = FixtureScrollView()
    private var controls: [String: NSView] = [:]

    init(number: Int, owner: FixtureDelegate) {
        self.fixtureOwner = owner
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Disposable document \(number)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let leftForSettings = ProcessInfo.processInfo.arguments.contains("--left-for-settings")
        let firstOriginX = leftForSettings ? (NSScreen.screens.first?.visibleFrame.minX ?? 0) + 80 : window.frame.minX
        window.setFrameOrigin(NSPoint(x: firstOriginX + CGFloat((number - 1) % 5) * 28,
                                      y: window.frame.minY - CGFloat((number - 1) % 5) * 28))

        let title = NSTextField(labelWithString: "mxlt-utils test fixture")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "Safe to quit. Everything here is disposable and stored only in memory. This app normally stays running after its last window closes.")
        detail.textColor = .secondaryLabelColor
        let dirty = NSButton(checkboxWithTitle: "Unsaved changes — ask before closing", target: self, action: #selector(toggleDirty(_:)))
        let replace = NSButton(checkboxWithTitle: "Open a replacement window after closing", target: self, action: #selector(toggleReplacement(_:)))
        let hide = NSButton(checkboxWithTitle: "Hide application instead of closing", target: self, action: #selector(toggleHideOnClose(_:)))
        let new = NSButton(title: "New Window (⌘N)", target: owner, action: #selector(FixtureDelegate.newWindow))
        let sheet = NSButton(title: "Show Blocking Sheet", target: self, action: #selector(showSheet))
        let buttons = NSStackView(views: [new, sheet])
        buttons.spacing = 12
        // Native AX tab hierarchy with a Close child, matching a browser's tab strip.
        let tabClose = FixtureTabCloseButton(title: "Close", target: self, action: #selector(closeTab))
        controls = ["dirty": dirty, "replacement": replace, "hide": hide, "newWindow": new,
                    "blockingSheet": sheet, "tabClose": tabClose]
        let tab = NSStackView(views: [tabLabel, tabClose])
        tab.setAccessibilityElement(true)
        tab.setAccessibilityRole(.radioButton)
        let tabs = NSStackView(views: [tab])
        tabs.setAccessibilityElement(true)
        tabs.setAccessibilityRole(.tabGroup)
        let tabRow = NSStackView(views: [FixtureTabStrip(tabGroup: tabs, closeButton: tabClose), NSButton(title: "New Tab (⌘T)", target: self, action: #selector(addTab))])
        tabRow.spacing = 12
        let hint = NSTextField(wrappingLabelWithString:
            "Try multiple windows, minimize one, move one to another Space, cancel a save, drag away from the red button, or use ⌘W. The File menu still works when no window is open.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        scrollView.hasVerticalScroller = true
        scrollView.usesPredominantAxisScrolling = false
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        let grid = FixtureGrid(frame: NSRect(x: 0, y: 0, width: 1600, height: 1500))
        scrollView.documentView = grid
        nestedScrollView.frame = NSRect(x: 50, y: 55, width: 180, height: 150)
        nestedScrollView.hasHorizontalScroller = true
        nestedScrollView.usesPredominantAxisScrolling = false
        nestedScrollView.hasVerticalScroller = true
        nestedScrollView.borderType = .bezelBorder
        nestedScrollView.documentView = FixtureGrid(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
        grid.addSubview(nestedScrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let scrollHint = NSTextField(wrappingLabelWithString: "Hold the middle button over the grid and move away from the anchor. Counters are recorded in the fixture state file. A short middle click should arrive as one paired click.")
        scrollHint.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, detail, tabRow, dirty, replace, hide, buttons, hint, scrollView, scrollHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.minSize = NSSize(width: 640, height: 740)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--dirty") { window.isDocumentEdited = true; dirty.state = .on }
        if arguments.contains("--replace") { shouldReplace = true; replace.state = .on }
        let tabsArgument = arguments.first(where: { $0.hasPrefix("--tabs=") }).flatMap { Int($0.dropFirst(7)) } ?? 1
        tabCount = min(10, max(1, tabsArgument))
        tabLabel.stringValue = "Tabs: \(tabCount)"
    }

    required init?(coder: NSCoder) { nil }

    func evidence() -> [String: Any]? {
        guard let window = window as? FixtureWindow else { return nil }
        var points = controls.compactMapValues { center(of: $0) }
        points["redClose"] = window.standardWindowButton(.closeButton).flatMap { center(of: $0) }
        var sheetPoints: [String: [String: Double]] = [:]
        func inspectButtons(_ view: NSView) {
            if let button = view as? NSButton, let point = center(of: button) { sheetPoints[button.title] = point }
            view.subviews.forEach(inspectButtons)
        }
        if let sheet = window.attachedSheet, let view = sheet.contentView { inspectButtons(view) }
        let topLeft = eventPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY))
        let frame: [String: Double] = ["x": topLeft["x"]!, "y": topLeft["y"]!, "width": window.frame.width, "height": window.frame.height]
        return ["windowID": window.windowNumber, "frame": frame, "visible": window.isVisible, "minimized": window.isMiniaturized,
                "dirty": window.isDocumentEdited, "sheet": window.attachedSheet != nil, "tabs": tabCount,
                "controls": points, "sheetButtons": sheetPoints, "scroll": scrollView.evidence, "nestedScroll": nestedScrollView.evidence,
                "middleDowns": window.middleDowns, "middleUps": window.middleUps,
                "middleClicks": window.middleClicks, "replayedDowns": window.replayedDowns,
                "replayedUps": window.replayedUps, "unmatchedUps": window.unmatchedUps]
    }

    @objc func addTab() {
        tabCount += 1
        tabLabel.stringValue = "Tabs: \(tabCount)"
        fixtureLog("tab opened")
    }

    @objc func closeTab() {
        fixtureLog("tab close requested")
        if tabCount > 1 {
            tabCount -= 1
            tabLabel.stringValue = "Tabs: \(tabCount)"
            fixtureLog("tab closed; window remains")
        } else {
            window?.performClose(nil)
        }
    }

    @objc func toggleDirty(_ sender: NSButton) { window?.isDocumentEdited = sender.state == .on }
    @objc func toggleReplacement(_ sender: NSButton) { shouldReplace = sender.state == .on }
    @objc func toggleHideOnClose(_ sender: NSButton) { shouldHideOnClose = sender.state == .on }

    @objc func showSheet() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "A sheet is open"
        alert.informativeText = "mxlt-utils must leave this app running while the sheet is present."
        alert.addButton(withTitle: "Dismiss")
        alert.beginSheetModal(for: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        fixtureLog("window close requested")
        guard sender.attachedSheet == nil else {
            fixtureLog("close canceled: sheet present")
            return false
        }
        if allowCloseOnce {
            allowCloseOnce = false
            return completeCleanClose()
        }
        guard sender.isDocumentEdited else { return completeCleanClose() }
        let alert = NSAlert()
        alert.messageText = "Save this disposable document?"
        alert.informativeText = "No actual file is written. Cancel must keep this window and app open."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            fixtureLog(response == .alertSecondButtonReturn ? "close sheet canceled" : "close sheet accepted")
            guard response != .alertSecondButtonReturn, let self else { return }
            sender.isDocumentEdited = false
            self.allowCloseOnce = true
            sender.performClose(nil)
        }
        return false
    }

    private func completeCleanClose() -> Bool {
        guard shouldHideOnClose else { return true }
        fixtureLog("hiding application instead of closing window")
        NSApp.hide(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        fixtureLog("window will close")
        let replace = shouldReplace
        let owner = fixtureOwner
        owner?.controllers.removeAll { $0 === self }
        if replace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { owner?.newWindow() }
        }
    }
}

let application = FixtureApplication.shared
let delegate = FixtureDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
