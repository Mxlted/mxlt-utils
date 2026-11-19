// Adapted from CallQuits. Copyright (c) 2026 CallQuits contributors (MIT).
import AppKit
import CallQuitsCore
import UniformTypeIdentifiers

struct AppException: Identifiable, Codable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String

    @MainActor
    static func choose(title: String, message: String, prompt: String? = nil) -> [Self] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        if let prompt { panel.prompt = prompt }
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return Self(bundleID: id, name: name)
        }
    }
}

extension Array where Element == AppException {
    func contains(bundleID: String) -> Bool {
        contains { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    mutating func addApplications(_ applications: [AppException]) {
        let previousCount = count
        for app in applications where !contains(bundleID: app.bundleID) { append(app) }
        if count != previousCount { sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
}

/// The menu label and its action share this snapshot, even if focus changes.
struct MenuApplication: Equatable {
    let exception: AppException
    let protectedFromQuit: Bool

    init?(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular, !app.isTerminated else { return nil }
        self.init(bundleID: app.bundleIdentifier, name: app.localizedName, processID: app.processIdentifier)
    }

    init?(bundleID: String?, name: String?, processID: pid_t) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard processID > 1, processID != ownPID, let bundleID, !bundleID.isEmpty,
              !bundleID.contains(where: \.isWhitespace),
              bundleID.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "com.mxlted.mxlt-utils") != .orderedSame
        else { return nil }
        exception = AppException(bundleID: bundleID, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID)
        protectedFromQuit = AppProtection.isProtected(bundleIdentifier: bundleID, processID: processID, ownProcessID: ownPID)
    }
}
