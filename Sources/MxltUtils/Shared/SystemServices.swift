import AppKit
import ApplicationServices
import ServiceManagement

/// Native permission operations are separate from saved feature preferences.
@MainActor
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum LoginItemService {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
