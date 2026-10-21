# Architecture

The Swift package has three production targets:

- `CallQuitsCore`: dependency-free close, identity, eligibility, and confirmation decisions retained from CallQuits.
- `MxltCore`: deterministic middle-scroll transitions/speed and session suspension policy.
- `MxltUtils`: SwiftUI/AppKit shell, saved settings, public macOS adapters, and feature lifecycle.

`MxltUtilsApp` owns the menu bar scene and one settings window. `UtilityModel` coordinates the current feature switches, global pause, independent sleep/display/session suspension, and permission refresh. It starts only enabled, trusted features. Settings changes are observed outside input callbacks; the quit adapter retains its own narrow configuration invalidation. A central half-second trust check runs in common run-loop modes only when at least one feature is enabled, including during menu tracking. Login status refreshes on app activation/settings use, separately from this timer.

`QuitModel` retains the tested CallQuits preference and bounded Activity behavior. Its `quit.*` keys live in mxlt-utils' own defaults domain. `ScrollModel` stores validated `scroll.*` settings and exclusions. `Shared/SystemServices.swift` contains native permission and login-item operations. Accessibility access is shared by both features; enabled choices remain independent of temporary suspension.

`CloseMonitor` retains the passive annotated-session tap and bounded worker-queue Accessibility implementation. It pins native event/application/window identities and validates again before graceful or force termination. Disabling removes its tap, local monitor, observers, and pending work. The original close-state safeguards and timing remain intact.

`MiddleScrollService` uses a filtering annotated-session tap for middle-button gestures. Its callback copies native routing evidence and updates the small gesture state; app/window validation and synthetic dispatch happen after the callback. Scroll output uses the original anchor and process. Window bounds/ownership/visibility are revalidated, and ambiguous targets fail closed. A short-click replay sends a complete tagged down/up pair after validation. No synthetic down remains held while waiting for input. A canceled held gesture temporarily retains a cleanup-only tap to consume its matching release; it accepts no new gestures while disabled and releases the tap after the physical button is up. Permission loss may prevent consuming that up; the app never intentionally holds a synthetic button while waiting for physical input.

The scrolling tap calls `CloseMonitor.cancelForAuxiliaryInput()` before suppressing an auxiliary press. Both adapters ignore the shared synthetic marker, so replay cannot create new close intent. Ordinary wheel and trackpad events never enter the scrolling tap. See [scroll design](SCROLL-DESIGN.md) for target and event decisions.

The filtering tap also owns `InputTapPermissionWatchdog`, which checks trust on a separate serial queue every 250 ms while the tap exists, including idle and cleanup-only periods. On observed revocation it disables and invalidates the Mach port before asking the main thread to clear gesture/UI state. Callbacks fail open after watchdog invalidation. Re-enable and posting operations serialize with detachment; an invalidated watchdog cannot resume or affect a replacement. Permission loss and app termination bypass the ordinary button-release drain entirely. Generated event sources explicitly permit mouse, keyboard and system events with a zero suppression interval. Polling intervals are requested cadences, not measured or guaranteed revocation-response latency.

## Adding a feature

Add a small settings model and a native service with explicit, idempotent start/stop/cancel. Put deterministic decisions in `MxltCore` only when they need independent testing. Give the feature a settings section and menu switch, then add its lifecycle to `UtilityModel`. Reuse permission/login helpers where applicable. Test cleanup, permission loss, and interaction with existing features. A third feature does not need a registry, dynamic loading, or a plugin protocol.

Public API references: [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [Accessibility](https://developer.apple.com/documentation/applicationservices/axuielement), and [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). SMAppService keeps launch-at-login tied to the installed app identity without a bundled helper or user launch-agent edits.
