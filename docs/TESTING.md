# Testing

## Routine checks

```sh
swift test
./scripts/build.sh
git diff --check
git diff --cached --check
```

The tests use isolated preferences and pure decision logic where possible. Accessibility adapter tests use controlled fixtures/self-AX data; they never terminate a user's app. The bundle script separately compiles Release and verifies the resulting signature. For Developer ID builds, use a fresh `APP_BUNDLE_PATH`; never overwrite a finalized artifact.

Coverage includes close eligibility and native identity, down/up movement, shortcut gating, force protections, sheets/save cancellation, remaining/replacement windows, Discord's narrow hidden-close policy, bounded AX recovery, settings/permission transitions, scroll velocity/transitions, click replay, synthetic tagging, pinned-window validation, and independent session suspension.

## Running-app checks

### Unreleased scrolling timing

Automated checks cover accepted-frame timing across skipped validation ticks, capped gaps without a backlog, resets after stopping, invalid timestamps, uneven frame intervals, and motion integration through 240 Hz. The full suite passes 170 XCTest cases; the separate ad hoc Release bundle build and signature verification pass. No app launches, synthetic input runs, or physical mouse checks were performed for this change. Display-link delivery, perceived smoothness, and mixed-display behavior remain for manual testing.

### 0.2.0 smoothing checks

Version 0.2.0 adds motion-policy tests for eased speed changes, diagonal travel across timer frequencies, low-speed fractional accumulation, axis stops and reversals, direct-speed mode, invalid/delayed samples, and clearing motion on dead-zone return, release, cancellation, or reset. Settings tests cover the default-on smoothing choice and its persistence when disabled and relaunched. The local suite passes 165 XCTest cases and the separate Release app build passes.

The signed 0.2.0 candidate additionally passed all 15 native fixture cases: click, wheel, scroll, nested-scroll, escape, pin-target, pause-held, disable-held, toggle-cycles, quit, cancel-close, replacement, remaining-window (minimized survivor), tab-remains, and command-remains. Both features were enabled and smoothing was on. A separate scroll case also passed with smoothing disabled, then smoothing was restored on. The Smooth scrolling control was inspected in dark appearance. These are synthetic native events and UI inspection, not physical mouse evidence. Browser checks below are historical 0.1.0 evidence and have not been rerun for 0.2.0. The 60 Hz timer is not a measured delivery guarantee.

### Fixture workflow

Build the [disposable fixture](../scripts/fixtures/README.md). Grant Accessibility to the installed mxlt-utils app, enable the relevant feature, and stop any other quit monitor during tests. Do not close or terminate real user apps as a test.

```sh
./scripts/build-fixture.sh
"build/mxlt-utils Fixture.app/Contents/MacOS/MxltUtilsFixture" \
  --state-path "$PWD/build/fixture-state.json"
# In another terminal:
swift scripts/run-native-checks.swift --state-path build/fixture-state.json --case scroll
```

The runner posts native synthetic CGEvents through WindowServer and checks fixture counters, viewport changes, window state, and graceful-quit evidence. Results are synthetic end-to-end evidence, not physical mouse evidence. See the fixture guide for case flags and cleanup. Keep the pointer/keyboard idle during each case. A refused input action is a failed or blocked test, never a pass.

Manual integration checks: repeated per-feature enable/disable, global pause/resume, denied permission and recovery, permission revocation midgesture, Escape, held-button disable, sleep/session changes, modified clicks, normal wheel/trackpad, middle-drag exclusions, target/window movement and closure, other Spaces/minimized windows, and both features together. Check the menu/settings at minimum size and both appearances; test launch-at-login registration and restore its previous choice.

## Compatibility evidence

The initial development environment is Apple silicon running macOS 27.0.1, with Xcode 27.1/Swift 6.4. The deployment target remains macOS 14. CI independently checks macOS 15/Xcode 16.4; CI architecture is not a published app architecture.

For 0.1.0, the complete automated suite passes **157 XCTest cases**: 64 retained quit-policy tests, 19 scroll/session-policy tests, and 74 native adapter/settings tests. The Developer ID Release configuration builds on the development machine. CI separately builds and tests with Xcode 16.4.

Running-app evidence uses native synthetic CGEvents through WindowServer, with both features enabled. The disposable AppKit fixture verifies:

- Short middle-click replay reaches the actual content view once, with paired tagged down/up and no orphan release.
- Vertical/diagonal scrolling, continued movement while the pointer is stationary, dead-zone stop, release stop, Escape cancellation, nested-view routing, and crossing into another window without redirecting output.
- Ordinary wheel input remains untagged and moves the native view.
- Pause/disable while held stops scrolling, consumes the eventual release, cannot revive the canceled gesture on resume, and permits a fresh click. Three disable/enable cycles alternate passthrough and replay without changing CallQuits' enabled setting.
- Graceful last-window red-button quit; native save cancellation beyond the attempt deadline; replacement windows; a minimized remaining window; native tab close and Command-W leaving a tab/window open.

Chrome **156.0.8078.47** was tested with a separate disposable profile and the local browser fixture. Native synthetic input opened exactly one new tab from a short middle click; continuous outer and nested scrolling, stationary-pointer position, dead-zone/release and Escape stops, no leaked clicks, and no unintended extra tabs passed. DOM counters and actual scroll offsets were read through CDP; CDP did not generate input. This is Chrome coverage, not a claim about every Chromium/Electron application.

The settings window was inspected at minimum size in dark appearance. Permission denial followed by a user-granted Accessibility recovery was exercised. Launch-at-login registration and unregistration both succeeded and were restored off. Light appearance uses native adaptive colors; a separate live light-appearance check remains useful.

Native receipt alone was insufficient during development: a same-position `CGEventSetLocation` call erased window-local coordinates. Tests now require content-view actions/viewport movement, and the adapter preserves the original native location. The fixture explicitly disables AppKit's predominant-axis lock so diagonal assertions measure both axes; other apps may apply their own axis locking.

Physical mouse input, actual permission revocation during a gesture, sleep/lock transitions, macOS 14/15 runtime, Intel runtime, multiple displays/mixed scaling, separate-account installation, live Discord, and broad Electron/application compatibility remain unverified. These are explicit preview limits, not inferred successes from compilation, policy tests, or notarization. Do not run another scroll remapper during isolated checks: its inversion/smoothing can alter the synthetic baseline.
