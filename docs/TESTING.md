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

## 0.3.8 Faster distance scrolling

The October 25, 2026 distance update passes 214 XCTest cases, including continuity at the acceleration threshold, unchanged close-range speeds, bounded extreme inputs, symmetry, fast diagonal travel at 30–240 Hz, reversal, and clearing full-speed motion on dead-zone return, release, cancellation and reset. The signed Release preview also passes synthetic native `fast-scroll`, `scroll`, `click` and `escape` checks with OBS Display Capture active. `fast-scroll` measures delivered content-view deltas while stationary and requires a rate above the previous 8,000 pt/s ceiling, then verifies dead-zone/release stops and no leaked click. These checks establish event delivery and stopping behavior, not physical-mouse feel or equivalence to a particular Windows app.

## 0.3.8 Display Capture compatibility

On October 25, 2026, the unchanged app passed synthetic scrolling with OBS open before the Display Capture reproduction, then failed with the source present. A diagnostic build captured the cause: WindowServer's cursor-level window covered the anchor despite a successful AX hit on the original fixture. The fixed Developer ID Release preview passes six synthetic native cases with OBS 32.2.2 Display Capture active: `scroll`, `click`, `escape`, `nested-scroll`, `pin-target`, and `wheel`. These verify view-level continuous/diagonal motion, stationary continuation, dead-zone/release stops, paired short-click replay, Escape cancellation, nested routing and no redirection across windows. The ordinary-wheel case passed with the separately running Vorssaint temporarily stopped; its active wheel smoothing had inverted the fixture's vertical input and confounded the original check. Vorssaint was restored with preferences unchanged.

All 212 XCTest cases pass. Cursor regression cases require a verified owner, exact system cursor level and fresh target AX hit, and retain cancellation for covered, vanished or moved windows. A process running at the cursor level cannot establish WindowServer identity from its level alone. The fixture runner uses the same narrow system-cursor exception before posting input, retaining its original fixture identity and AX checks. Physical-mouse feel, other capture programs and older macOS runtime behavior remain unverified. These checks preceded the 0.3.8 release; final packaging and installation follow the release workflow.

## 0.3.7 Apps launcher metadata

The installed 0.3.6 bundle was missing from Apple's Apps view despite valid signatures, Spotlight indexing, and correct Launch Services resolution. System Information reported `arch_kind=arch_ios`. Adding `CFBundleSupportedPlatforms=[MacOSX]` changed the signed candidate to `arch_arm`; the corrected, notarized installed preview retained that classification, and the user confirmed it appeared in Apps. The menu-bar-only setting remains enabled; visible comparison apps also used it. Registration/index refresh and restarting the launcher interface alone had not resolved the issue.

This is a bundle metadata fix with no runtime input-policy changes. Release validation checks the platform declaration in the packaged app as well as the existing signature, ticket, version and architecture checks.

## 0.3.6 Quit on Close changes

The full suite passes 210 XCTest cases: 64 quit-policy, 37 scroll/session-policy, and 109 native-adapter/settings cases. New injected Accessibility fixtures cover direct and Chromium sibling tab-body hits, native ancestry and actual close-control proof, wrong recipients, web tabs, disabled controls, remaining windows, save sheets, and a remote dialog's official Cancel button. Dialog confirmation waits for disappearance and stable empty snapshots; staying dialogs, replacements, and unreadable state cannot quit. Red-button regression tests run with Cancel recognition enabled. Input tests construct events without posting them and check middle-button-only routing and rejection of replay tags. Both new triggers are tested against force quit and any-window policy. Existing preference keys and settings are retained.

The automated suite uses unit/adapter fixtures. A separate read-only check inspected the user-opened TextEdit startup chooser after the first preview failed: it exposes `AXStandardWindow`/`open-panel`, with `CancelButton` under a direct `AXSplitGroup`, and returns `noValue` for `AXWindow` on the button and `AXCancelButton` on the window. The original production capture rejected that live control; the patched production capture accepted it for the correct app, and read a reliable one-window/nonblocking snapshot. Window-creation notification registration also succeeded and was removed immediately. Added fixtures reproduce that observed shape and reject unverified hosted input, incorrect identifiers/ancestry/PIDs, conflicting optional attributes, documents, sheets, and additional windows. This proves live capture and observation capability, not click routing or process exit. That initial inspection did not launch or quit apps. Subsequent testing, explicitly authorized by the user, is recorded below. The old settings screenshot still depicts v0.3.5; the new Quit on Close name was inspected in the running preview.

Live follow-up found that native Cancel input targets Apple's `com.apple.appkit.xpc.openAndSavePanelService`, while the exact event-stamped WindowServer window belongs to TextEdit. Ordinary identity validation correctly rejects this mismatch. The initial exception required TextEdit's verified window owner plus the exact system service bundle/executable, pinned service PID and stamped window across down/up, and accepted only the positively verified Cancel control. The shared implementation described below retains these service and ownership checks across eligible host apps.

During dismissal, production reads returned up to two transient `AXError.cannotComplete` failures, including after an initial empty snapshot. Initially this recovery was restricted to TextEdit; the shared implementation now requires verified system-hosted Open-panel cancellation for its two fresh-read retries. Each discards elapsed confirmation time; subsequent reliable matching snapshots must cover a fresh full interval. Disappearance history, replacement/sheet observers, original deadline, and all eligibility checks remain active. Other errors, exhausted retries, reappearing windows and changed identities still cancel. The recovery helper owns both native hosted-panel proof gating and discarding elapsed confirmation, so callers cannot accidentally apply only one part. Tests cover these boundaries, rejection of unverified panels without changing their confirmation, and unchanged ordinary identity rejection.

With user authorization, a signed development preview was launched and its Accessibility registration renewed. Scoped native synthetic clicks at 150, 80, 30 and 20 ms press durations produced actual TextEdit process exit (`NSRunningApplication.isTerminated` and running-process enumeration), not merely chooser disappearance. A 10 ms stress click missed capture and safely left the app running; input arriving faster than live AX verification remains a limitation. A scoped synthetic chooser Cancel with a disposable document present left TextEdit running and the document intact. Computer-use Save-prompt cancellation preserved the unsaved test text; this is separately identified UI evidence, not a physical mouse test. Test documents were saved in ignored `build/` during cleanup. The signed preview is a local test artifact, not a notarized release. The user subsequently reported that the fix now appears to work. This is user-reported manual confirmation; instrumented physical-click coverage, minimized/other-Space survivors and browser middle-click integration remain separate live-test gaps.

Cross-app follow-up inspected Preview and QuickTime Player while neither had documents open. Both exposed the same `AXStandardWindow`/`open-panel` and direct `AXSplitGroup`/`CancelButton` ancestry, missing optional window/Cancel attributes, and host-owned AX elements as TextEdit. Baseline production capture rejected both; baseline scoped Cancel clicks dismissed the chooser but left both processes running. The shared implementation replaces the TextEdit name check with verified native system-service/host-window proof, carried through control capture and recovery. Tests now accept identified host apps without an allowlist, while rejecting false service identities, absent native proof, Save panels and unrelated service-hosted dialogs.

After restoring the new signed preview's existing Accessibility registration, scoped synthetic 150 ms Cancel clicks confirmed process exit for Preview, QuickTime Player and TextEdit. Preview stayed running with the repository's icon image open, and that document remained intact. A second attempt intended to test a minimized survivor returned a non-minimized document by the time of Cancel, so it is additional remaining-document evidence only, not minimized-window coverage. No user documents were changed. These results establish the three tested apps on this machine; other apps using the same verified system-panel structure are eligible, while custom choosers and different AX layouts are not claimed as supported. Existing save-sheet, minimized/other-Space, replacement-window and exception policy tests remain passing. Apple documents shared out-of-process Open panels since macOS 10.15; their specific Accessibility layout remains observed compatibility evidence.

Additional checks for the preview, using disposable documents and browser profiles:

- Launch TextEdit into its file chooser with no documents open, then click Cancel: the chooser should disappear and the app should quit. Repeat with another document open, including minimized/on another Space: the app must remain running. Cancel a save sheet on an unsaved disposable document: it must remain open.
- Middle-click a supported browser's last tab: quit only if the native window closes and no other windows remain. Repeat with another tab/window open, with Middle scrolling on and off, and with the browser excluded from scrolling. Apps that keep an empty window after closing their last tab stay running.
- Check that middle-click links/bookmarks still work, held scrolling never quits, and dragging away then returning, Escape, pause/disable, permission loss, or a new input cannot complete an older close attempt. Existing exceptions apply to every path.

Implementation references: Apple's [Cancel-button attribute](https://developer.apple.com/documentation/applicationservices/kaxcancelbuttonattribute), [dialog subrole](https://developer.apple.com/documentation/applicationservices/kaxdialogsubrole), [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel), and [Accessibility identifiers](https://developer.apple.com/documentation/appkit/nsaccessibilityelementprotocol/accessibilityidentifier%28%29) documentation, also queried through Context7. Remote hosting alone never supplies application identity; exact native ownership and the narrow verified system-service relationship are required. Unknown Accessibility layouts are unsupported until verified.

## Running-app checks

### 0.3.5 Accessibility revocation hardening

All 190 XCTest cases pass. Watchdog tests use injected permission checks and detach operations, including a stale positive trust flag with denied filtering capability, revocation without input, detachment while the main thread is deliberately unavailable, explicit shutdown, stale results after replacement, serialized posting/detachment, and refusing to revive a revoked watcher. Timeout recovery tests verify background probing, rejection after failed capability, and ignoring success after explicit shutdown during a pending query. No test creates a real permission-probe tap. Native event-source tests verify zero suppression interval and mouse/keyboard/system passthrough in both suppression states without posting events. Existing gesture cancellation, replay, settings and quit-policy tests remain passing. These tests do not prove that macOS detaches a real input tap correctly or that the reported mouse restriction is resolved.

The user reported that the input restriction after deleting an enabled Accessibility entry appears resolved in the development preview. This is user-reported manual confirmation, not an instrumented result or full scenario matrix. No app launches, Accessibility changes or input injection were performed by the agent for 0.3.5. Release preparation keeps the same recovery behavior, extracts timeout recovery from the input handler, and checks the final packaged app without launching it.

Remaining manual cases: delete the enabled row separately from switching its toggle off, while idle, scrolling and menu tracking; check cross-window clicks, keyboard input and normal typing overhead. Restore access and retry monitoring, then check a fresh gesture and retained choices. Retry while access is still absent must leave monitoring stopped. See the README for recovery steps on an older build.

### 0.3.5 progressive distance scrolling

The implementation-stage suite passed 179 XCTest cases. Tests cover increasing acceleration with distance, fine motion near the dead zone, continued acceleration beyond the former default speed ceiling, slowing when moving closer, monotonic and symmetric speed across slider/dead-zone settings, diagonal direction, extreme-coordinate bounds, and stationary-pointer travel with smoothing on and off. Existing stop, release, replay and cancellation checks remain passing. The separate Release bundle and strict signature verification pass. Manual app launches and mouse testing remain with the user; perceived feel and comparison with Windows have not been live-tested.

### 0.3.5 bookmark-folder click fix

The implementation-stage suite passed 176 XCTest cases. Metadata regression tests cover normal windows, popup/submenu levels and floating/modal panels, plus dismissed, replaced, moved, resized, reowned, transparent or covered menus. Changing the pinned window's level also invalidates it. The separate Release bundle build and strict signature verification pass. These checks exercise target policy and event construction without posting input. They do not establish browser menu delivery.

Manual app launches and mouse testing remain with the user. With Middle scrolling enabled, check short middle clicks on ordinary bookmarks, bookmarks in folders and nested folders, and page links. Each should open one new tab where the browser supports it. Also check held scrolling in page content and that dismissing or covering a captured popup cannot click through to the parent window. No running-app or physical-input result is claimed for this fix.

### 0.3.0 scrolling timing and icon

Automated checks cover accepted-frame timing across skipped validation ticks, capped gaps without a backlog, resets after stopping, invalid timestamps, uneven frame intervals, and motion integration through 240 Hz. Speed-control tests also cover the extended speed ceiling, bounded delayed output in both smoothing modes, persisted values, corrupt-setting repair, and ignoring the removed smooth-speed preference. The full suite passes 173 XCTest cases; the separate Release bundle build and signature verification pass. The Fold icon is generated from its committed source image in all standard and Retina sizes, with explicit pixel dimensions. Manual app launch and mouse testing were reserved to the user for this release. No new app launches, synthetic input runs, or physical mouse checks are claimed here. Display-link delivery, perceived smoothness, and mixed-display behavior remain for manual testing.

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
