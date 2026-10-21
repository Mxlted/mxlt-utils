import AppKit
import ApplicationServices
import Combine
import MxltCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScrollModel: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "scroll.enabled") } }
    @Published var sensitivity: Double {
        didSet {
            let value = ScrollSettings(sensitivity: sensitivity).sensitivity
            if sensitivity != value { sensitivity = value }
            defaults.set(value, forKey: "scroll.sensitivity")
        }
    }
    @Published var deadZone: Double {
        didSet {
            let value = ScrollSettings(deadZone: deadZone).deadZone
            if deadZone != value { deadZone = value }
            defaults.set(value, forKey: "scroll.deadZone")
        }
    }
    @Published var reversed: Bool { didSet { defaults.set(reversed, forKey: "scroll.reversed") } }
    @Published var smooth: Bool { didSet { defaults.set(smooth, forKey: "scroll.smooth") } }
    @Published var exclusions: [AppException] {
        didSet { if let data = try? JSONEncoder().encode(exclusions) { defaults.set(data, forKey: "scroll.exclusions") } }
    }
    @Published var status = "Off"
    var settings: ScrollSettings {
        ScrollSettings(sensitivity: sensitivity, deadZone: deadZone, reversed: reversed,
                       smooth: smooth)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["scroll.sensitivity": 1.0, "scroll.deadZone": 8.0,
                                     "scroll.smooth": true])
        enabled = defaults.bool(forKey: "scroll.enabled")
        let savedSettings = ScrollSettings(sensitivity: defaults.double(forKey: "scroll.sensitivity"),
                                           deadZone: defaults.double(forKey: "scroll.deadZone"),
                                           reversed: defaults.bool(forKey: "scroll.reversed"))
        sensitivity = savedSettings.sensitivity
        deadZone = savedSettings.deadZone
        reversed = savedSettings.reversed
        smooth = defaults.bool(forKey: "scroll.smooth")
        defaults.set(savedSettings.sensitivity, forKey: "scroll.sensitivity")
        defaults.set(savedSettings.deadZone, forKey: "scroll.deadZone")
        exclusions = defaults.data(forKey: "scroll.exclusions").flatMap { try? JSONDecoder().decode([AppException].self, from: $0) } ?? [
            AppException(bundleID: "org.blenderfoundation.blender", name: "Blender")
        ]
    }

    func addException() {
        let panel = NSOpenPanel()
        panel.title = "Keep middle-drag unchanged"
        panel.message = "Middle scrolling will leave these apps alone."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !exclusions.contains(where: { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }) else { continue }
            exclusions.append(AppException(bundleID: id, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent))
        }
        exclusions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class UtilityModel: ObservableObject {
    static let shared = UtilityModel()
    let quit = QuitModel()
    let scroll = ScrollModel()
    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused"); reconcile() }
    }
    @Published private var suspension = SessionSuspension()
    var sessionSuspended: Bool { suspension.isSuspended }
    private lazy var quitMonitor = CloseMonitor(model: quit)
    private let scrollService = MiddleScrollService()
    private var quitStarted = false
    private var scrollConfiguration: ScrollConfiguration?
    private var permissionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var updateQueued = false
    private var started = false
    private var scrollFailed = false
    private var lastPermission = false

    private struct ScrollConfiguration: Equatable {
        let sensitivity: Double
        let deadZone: Double
        let reversed: Bool
        let smooth: Bool
        let exclusions: Set<String>
    }
    var status: String {
        if paused { return "Paused" }
        if sessionSuspended { return "Session inactive" }
        if !quit.enabled && !scroll.enabled { return "Choose a feature to begin" }
        if !quit.accessibilityGranted { return "Accessibility access needed" }
        if quit.enabled && quit.monitoringState == .unavailable || scrollFailed { return "Some features need attention" }
        return "Ready"
    }

    func start() {
        guard !started else { return }; started = true
        quit.objectWillChange.sink { [weak self] _ in self?.queueUpdate() }.store(in: &subscriptions)
        scroll.objectWillChange.sink { [weak self] _ in self?.queueUpdate() }.store(in: &subscriptions)
        scrollService.onAuxiliaryPress = { [weak self] in self?.quitMonitor.cancelForAuxiliaryInput() }
        scrollService.onFailure = { [weak self] in
            guard let self else { return }
            self.quit.refreshPermission()
            self.scrollConfiguration = nil
            self.scrollFailed = self.quit.accessibilityGranted
            self.setScrollStatus(self.scrollFailed ? "Monitoring unavailable — retry" : "Accessibility access needed")
            if self.scrollFailed { self.quit.record("Middle scrolling stopped. Retry monitoring in Settings.") }
        }
        let center = NSWorkspace.shared.notificationCenter
        let suspensionNotifications: [(Notification.Name, SessionSuspension.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ]
        for (name, reason, suspended) in suspensionNotifications {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspension.set(reason, suspended: suspended)
                    if suspended { self.reconcile() } else { self.refresh() }
                }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollService.cancel() }
        })
        refresh()
    }

    private func queueUpdate() {
        guard !updateQueued else { return }; updateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.updateQueued = false
            self.objectWillChange.send(); self.reconcile()
        }
    }

    func refresh() {
        quit.refreshPermission(); quit.refreshLoginStatus(); reconcile()
    }

    func retry() {
        scrollFailed = false
        scrollService.stop()
        scrollConfiguration = nil
        quit.retryMonitoring()
        reconcile()
    }

    private func reconcile() {
        guard started else { return }
        if (quit.enabled || scroll.enabled) && permissionTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.quit.refreshPermission(); self?.reconcile() }
            }
            timer.tolerance = 0.05
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !quit.enabled && !scroll.enabled {
            permissionTimer?.invalidate(); permissionTimer = nil
        }
        if lastPermission != quit.accessibilityGranted { scrollFailed = false; lastPermission = quit.accessibilityGranted }
        let suspended = paused || sessionSuspended
        if quit.suspended != suspended { quit.suspended = suspended }
        let runQuit = quit.effectiveEnabled && quit.accessibilityGranted
        if runQuit && !quitStarted { quitStarted = true; quitMonitor.start() }
        if !runQuit && quitStarted { quitMonitor.stop(); quitStarted = false }
        if !runQuit {
            quit.setMonitoringState(quit.effectiveEnabled && !quit.accessibilityGranted ? .permissionNeeded : .paused)
        }
        let shouldScroll = scroll.enabled && !suspended && quit.accessibilityGranted
        if shouldScroll && !scrollFailed {
            let configuration = ScrollConfiguration(sensitivity: scroll.sensitivity, deadZone: scroll.deadZone, reversed: scroll.reversed,
                                                    smooth: scroll.smooth,
                                                    exclusions: Set(scroll.exclusions.map { $0.bundleID.lowercased() }))
            if scrollConfiguration != configuration {
                scrollService.stop()
                scrollConfiguration = configuration
                scrollFailed = !scrollService.start(settings: scroll.settings, exclusions: configuration.exclusions)
            }
            setScrollStatus(scrollFailed ? "Monitoring unavailable — retry" : "Ready — hold the mouse wheel")
        } else {
            if !quit.accessibilityGranted {
                scrollService.stopImmediately()
                scrollConfiguration = nil
            } else if scrollConfiguration != nil { scrollService.stop(); scrollConfiguration = nil }
            setScrollStatus(!scroll.enabled ? "Off" : suspended ? "Paused" : !quit.accessibilityGranted ? "Accessibility access needed" : "Monitoring unavailable — retry")
        }
    }
    private func setScrollStatus(_ value: String) { if scroll.status != value { scroll.status = value } }

    func stop() {
        started = false
        quitMonitor.stop(); quitStarted = false
        scrollService.stopImmediately(); scrollConfiguration = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        subscriptions.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
    }
}
