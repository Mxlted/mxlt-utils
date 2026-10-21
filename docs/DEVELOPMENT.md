# Development

Use Xcode 16.4 or newer with its command-line tools selected, Swift 5.9 language mode, and macOS 14 or later. The project is a dependency-free Swift package. No generated Xcode project or XcodeGen installation is needed.

```sh
swift test
./scripts/build.sh
open build/mxlt-utils.app
```

`Resources/Info.plist` owns version/build and deployment metadata. `Package.swift` owns targets and the macOS 14 deployment target. `scripts/build.sh` compiles Release by default, assembles `build/mxlt-utils.app`, includes license/provenance, and applies an ad hoc hardened signature for development. Set `CONFIGURATION=debug` for a debug app, or `APP_BUNDLE_PATH` for a separate output. It refuses to overwrite a Developer ID artifact. Debug test and Release bundle builds are separate checks.

The script places caches in `.build/` and disables SwiftPM's build sandbox for the local bundle route; it does not disable macOS application protections. Xcode/SwiftPM output, test evidence, fixtures, and release artifacts remain ignored. Never commit credentials or signing material.

Regenerate the original geometric icon with `./scripts/generate-icon.sh`. The committed `.icns` and PNG make normal builds independent of icon generation. The menu bar uses a native template symbol and supports light/dark appearance.

## Workflow

Keep main buildable. Use focused, signed commits with the existing developer identity. Short feature branches are useful for longer changes; fast-forward integration preserves meaningful commits. A PR is appropriate when review is helpful, but not required for every small change. Do not force-push main or move published tags.

Before committing: inspect the diff and staged files, run relevant tests and the app bundle build for source changes, and run `git diff --check` plus `git diff --cached --check`. Full established checks precede a release. Documentation-only changes need content/link/whitespace checks.

CI uses GitHub's `macos-15` image and explicitly selects Xcode 16.4 (Swift 6.1). The [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) documents its availability. CI runs tests and an ad hoc app build, without signing or notarization secrets. Only contents-read permission is required.
