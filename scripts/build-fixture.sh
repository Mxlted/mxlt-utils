#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/mxlt-utils Fixture.app"
mkdir -p "$ROOT/.build/ModuleCache" "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$ROOT/.build/ModuleCache" -framework AppKit \
  "$ROOT/scripts/fixtures/FixtureApp.swift" -o "$APP/Contents/MacOS/MxltUtilsFixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MxltUtilsFixture</string>
<key>CFBundleIdentifier</key><string>com.mxlted.mxlt-utils.fixture</string>
<key>CFBundleName</key><string>mxlt-utils Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>MxltUtilsFixtureApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
echo "Launch when ready: open \"$APP\""
