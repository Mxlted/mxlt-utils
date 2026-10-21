import AppKit
import SwiftUI

@main
struct MxltUtilsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = UtilityModel.shared
    var body: some Scene {
        MenuBarExtra {
            Text("mxlt-utils").font(.headline)
            Text(model.status)
            Divider()
            Toggle("CallQuits", isOn: Binding(get: { model.quit.enabled }, set: { model.quit.enabled = $0 }))
            Toggle("Middle scrolling", isOn: Binding(get: { model.scroll.enabled }, set: { model.scroll.enabled = $0 }))
            Divider()
            Toggle("Pause all features", isOn: $model.paused)
            if !model.quit.accessibilityGranted && (model.quit.enabled || model.scroll.enabled) {
                Button("Allow Accessibility…") { model.quit.requestAccessibility() }
            }
            Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit mxlt-utils") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.paused ? "pause.circle" : "slider.horizontal.3")
                .accessibilityLabel("mxlt-utils: \(model.status)")
        }.menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UtilityModel.shared.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched"); showSettings()
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { UtilityModel.shared.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { UtilityModel.shared.stop() }
    func showSettings() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "mxlt-utils"
            panel.minSize = NSSize(width: 640, height: 530)
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: SettingsView(model: UtilityModel.shared))
            panel.setFrameAutosaveName("MxltUtilsSettings")
            panel.center(); window = panel
        }
        UtilityModel.shared.refresh()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
