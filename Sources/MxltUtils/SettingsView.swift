import AppKit
import CallQuitsCore
import MxltCore
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", quit = "Quit on Close", scroll = "Middle scrolling", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self { case .general: "slider.horizontal.3"; case .quit: "xmark.circle"; case .scroll: "computermouse"; case .activity: "clock" }
    }
}

struct SettingsView: View {
    @ObservedObject var model: UtilityModel
    @State private var selection: SettingsSection = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("mxlt-utils").font(.headline)
                        Text("Small tools. Your way.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
                ForEach(SettingsSection.allCases) { section in
                    Button { selection = section } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 9)
                            .background(selection == section ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                Spacer(minLength: 12)
                Label(model.status, systemImage: model.paused ? "pause.circle" : "circle.fill")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(model.paused ? "Resume features" : "Pause all features") { model.paused.toggle() }
                    .frame(maxWidth: .infinity)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(16).frame(width: 190).background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(selection.rawValue).font(.title2.weight(.semibold))
                    switch selection {
                    case .general: GeneralPane(model: model)
                    case .quit: QuitPane(model: model.quit)
                    case .scroll: ScrollPane(model: model.scroll)
                    case .activity: ActivityPane(model: model.quit)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.tint(Color.accentColor)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: UtilityModel
    @ObservedObject private var quit: QuitModel
    @ObservedObject private var scroll: ScrollModel
    init(model: UtilityModel) { self.model = model; quit = model.quit; scroll = model.scroll }
    var body: some View {
        Text("A few useful changes to how your Mac feels. Enable each one when you need it.").foregroundStyle(.secondary)
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Quit on Close", isOn: $quit.enabled)
                Text("Quit an app after its last window closes.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Middle scrolling", isOn: $scroll.enabled)
                Text("Hold the mouse wheel and move to scroll.").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label(quit.accessibilityGranted && !model.inputAccessNeedsRetry ? "Accessibility allowed" : "Accessibility access",
                      systemImage: quit.accessibilityGranted && !model.inputAccessNeedsRetry ? "checkmark.shield" : "hand.raised")
                    .font(.headline)
                Text("Quit on Close checks close controls and windows. Middle scrolling turns a held mouse button into scrolling. Your input stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.inputAccessNeedsRetry {
                    Text("Input access is unavailable. Restore Accessibility access in System Settings, then retry monitoring.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !quit.accessibilityGranted && (quit.enabled || scroll.enabled) {
                        Button("Allow access…") { quit.requestAccessibility() }
                    }
                    Button("Open System Settings") { quit.openAccessibilitySettings() }
                    Button("Check again") { model.refresh() }
                }.controlSize(.small)
                if quit.accessibilityGranted && (quit.enabled || scroll.enabled) {
                    Button("Retry monitoring") { model.retry() }.controlSize(.small)
                }
            }.padding(6)
        }
        Toggle("Launch at login", isOn: $quit.launchAtLogin)
        if let message = quit.loginMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        HStack {
            Link("Releases & updates", destination: URL(string: "https://github.com/Mxlted/mxlt-utils/releases")!)
            Spacer()
            Text("Local. No account or telemetry.").font(.caption).foregroundStyle(.secondary)
        }.font(.caption)
    }
}

private struct QuitPane: View {
    @ObservedObject var model: QuitModel
    @State private var confirmForce = false
    var body: some View {
        Toggle("Enable Quit on Close", isOn: $model.enabled).font(.headline)
        Text(model.enabled ? (model.suspended ? "Paused" : model.statusMessage) : "Off").font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
            Text("After clicking the red close button")
            Picker("Close behavior", selection: $model.behavior) {
                Text("Quit after the last window").tag(CloseBehavior.lastWindow)
                Text("Quit after any window").tag(CloseBehavior.everyWindow)
            }.pickerStyle(.menu).labelsHidden()
        }
        Toggle("Include ⌘W and tab closing", isOn: $model.additionalCloseMethods)
        Text("Close a supported tab with its × button or a middle click. These methods quit only after the last window closes; remaining tabs or windows keep the app open.").font(.caption).foregroundStyle(.secondary)
        Text("Clicking Cancel in an app’s last standalone dialog, such as TextEdit’s opening file chooser, also quits the app after the dialog closes.").font(.caption).foregroundStyle(.secondary)
        Toggle("Allow Shift-click to force quit", isOn: Binding(get: { model.forceQuitEnabled }, set: { if $0 { confirmForce = true } else { model.forceQuitEnabled = false } }))
            .alert("Allow force quit?", isPresented: $confirmForce) {
                Button("Cancel", role: .cancel) {}
                Button("Allow force quit", role: .destructive) { model.forceQuitEnabled = true }
            } message: { Text("Shift-clicking a red close button can discard unsaved work. Exceptions and protected apps still apply. Normal closes always request a graceful quit.") }
        if model.forceQuitEnabled { Text("Shift-click can discard unsaved work.").font(.caption).foregroundStyle(.orange) }
        Divider()
        ExceptionList(title: "Keep these apps running", exceptions: $model.exclusions, add: model.addException)
        Text("Finder, system processes, and mxlt-utils are always protected. Uncertain window state, save prompts, and replacement windows prevent automatic quitting.").font(.caption).foregroundStyle(.secondary)
    }
}

private struct ScrollPane: View {
    @ObservedObject var model: ScrollModel
    var body: some View {
        Toggle("Enable middle scrolling", isOn: $model.enabled).font(.headline)
        Text(model.status).font(.caption).foregroundStyle(.secondary)
        Text("Hold the wheel, then move away from where you pressed. Move farther to scroll faster. Return to the center to stop; release or press Escape to finish.").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("Scroll speed"); Spacer(); Text("\(model.sensitivity, specifier: "%.1f")×").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $model.sensitivity, in: ScrollSettings.sensitivityRange).accessibilityLabel("Scroll speed")
        }
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("Dead zone"); Spacer(); Text("\(Int(model.deadZone)) pt").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $model.deadZone, in: ScrollSettings.deadZoneRange, step: 1).accessibilityLabel("Dead zone")
        }
        Toggle("Reverse scroll direction", isOn: $model.reversed)
        Toggle("Smooth scrolling", isOn: $model.smooth)
        Text("Ease into speed changes. Returning to the center or releasing still stops immediately.").font(.caption).foregroundStyle(.secondary)
        Text("Short middle clicks still work. Apps with their own middle-drag tools can be excluded below. Scrolling stays with the window where the press began.").font(.caption).foregroundStyle(.secondary)
        Divider()
        ExceptionList(title: "Leave middle-drag unchanged", exceptions: $model.exclusions, add: model.addException)
    }
}

private struct ExceptionList: View {
    let title: String
    @Binding var exceptions: [AppException]
    let add: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Button("Add…", action: add).controlSize(.small) }
            if exceptions.isEmpty { Text("No exceptions").font(.caption).foregroundStyle(.secondary) }
            ForEach(exceptions) { item in
                HStack {
                    Text(item.name).lineLimit(1).help(item.bundleID)
                    Spacer()
                    Button { exceptions.removeAll { $0.bundleID == item.bundleID } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(item.name)").accessibilityLabel("Remove \(item.name)")
                }.font(.callout)
            }
        }
    }
}

private struct ActivityPane: View {
    @ObservedObject var model: QuitModel
    var body: some View {
        Text("Recent state changes and verified close attempts. Kept only for this session, up to 80 entries. No document names or input history.").font(.caption).foregroundStyle(.secondary)
        if model.activity.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
        ForEach(model.activity) { entry in
            HStack(alignment: .top, spacing: 10) {
                Text(entry.date, style: .time).monospacedDigit().foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
        }
        if !model.activity.isEmpty { Button("Clear activity") { model.activity.removeAll() }.controlSize(.small) }
    }
}
