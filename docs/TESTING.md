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

Verification is still in progress for 0.1.0. Release notes record completed checks and any publication blocker. Wider macOS 14/15 runtime, Intel runtime, multiple displays/mixed scaling, separate-account installation, physical mouse input, and general application compatibility must not be inferred from compilation or notarization. Browser/Electron results must be recorded for the specific app tested, and never generalized to every browser.
