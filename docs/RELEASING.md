# Releasing

Normal CI stays independent of signing credentials. Release locally with an installed Developer ID Application identity and an existing `notarytool` Keychain profile. Never export keys or upload credentials to Actions.

1. Finish the relevant native checks and full routine checks in [TESTING.md](TESTING.md). Review input safety and ensure no reference repository, agent notes, secrets, or generated output is indexed. Confirm source provenance and license notices.
2. Update `Resources/Info.plist`, changelog, release notes, and verification evidence. Commit and push, then require CI success on that exact source commit. Use a semantic `v0.x.y` tag; never move a published tag.
3. Build once from the final clean commit into a fresh artifact directory. Keep that commit and all subsequent submission IDs in local release records. The script refuses to overwrite an existing Developer ID app.

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='YOUR_EXISTING_KEYCHAIN_PROFILE'
export APP_BUNDLE_PATH="$PWD/build/release-0.1.0/mxlt-utils.app"
./scripts/build.sh
codesign --verify --deep --strict "$APP_BUNDLE_PATH"
codesign -dv --verbose=4 "$APP_BUNDLE_PATH"
lipo -archs "$APP_BUNDLE_PATH/Contents/MacOS/MxltUtils"
```

4. Create a private ZIP solely for app notarization. Submit, wait for **Accepted**, inspect the notary log, then staple and validate the app. Resume an existing submission after a timeout instead of submitting another copy.

```sh
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE_PATH" build/app-notary-input.zip
xcrun notarytool submit build/app-notary-input.zip --keychain-profile "$NOTARY_PROFILE" --output-format json
# Save the returned ID, then:
xcrun notarytool wait APP_SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" --output-format json
xcrun notarytool log APP_SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" build/app-notary-log.json
xcrun stapler staple "$APP_BUNDLE_PATH"
xcrun stapler validate "$APP_BUNDLE_PATH"
```

5. Package the already finalized app with an Applications shortcut. The packaging script validates the source, rejects overwrites and output inside the app, and never rebuilds or modifies it. The filename includes the binary's actual architecture slices.

```sh
./scripts/package-dmg.sh
xcrun notarytool submit build/mxlt-utils-0.1.0-macos-arm64.dmg --keychain-profile "$NOTARY_PROFILE" --output-format json
xcrun notarytool wait DMG_SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" --output-format json
xcrun notarytool log DMG_SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" build/dmg-notary-log.json
xcrun stapler staple build/mxlt-utils-0.1.0-macos-arm64.dmg
xcrun stapler validate build/mxlt-utils-0.1.0-macos-arm64.dmg
codesign --verify --strict build/mxlt-utils-0.1.0-macos-arm64.dmg
hdiutil verify build/mxlt-utils-0.1.0-macos-arm64.dmg
(cd build && shasum -a 256 mxlt-utils-0.1.0-macos-arm64.dmg > SHA256SUMS.txt)
```

6. Mount the final DMG read-only. Copy its app into a fresh directory and verify strict signature, stapled ticket, executable permissions, architecture, and version. Use `syspolicy_check distribution` if available. A Gatekeeper assessment with a security-disabled override is not proof of default enforcement. Do not change system security settings. Run the packaged app for a final smoke check, without duplicate feature monitors.
7. Tag the validated source, create a draft release, and upload only the final stapled DMG plus `SHA256SUMS.txt`. Verify GitHub asset digests and independently download and compare bytes. Publish a prerelease only when the core quit/scroll interactions, click preservation, and cleanup have passed available running-app checks. Broader physical/OS coverage can remain explicitly documented.
8. If those basic live checks, signing credentials, or required manual actions remain blocked, preserve all completed artifacts and prepare a **draft** with the exact remaining blocker. Never substitute an unsigned public release. Verify the release URL/status/assets afterward and retain local submission/artifact records.

A release title, tag, bundle version, build number, source commit, and checksum must agree. Do not rebuild or edit the app after signing/stapling, or recalculate checksums before the final stapling changes. Future updates initially use the GitHub Releases link; no automatic updater is included.

The bundle must declare `CFBundleSupportedPlatforms` as an array containing `MacOSX`. Without this marker, macOS can classify an arm64-only bundle as iOS even when its executable targets macOS. Check the installed candidate's platform in System Information (or `system_profiler SPApplicationsDataType -json`); signature and notarization checks alone do not catch this metadata error.
