<p align="center"><img src="Resources/AppIcon.png" width="112" alt="mxlt-utils icon"></p>
<h1 align="center">mxlt-utils</h1>
<p align="center">A small native macOS menu bar app with useful features you choose.</p>

## Features

**CallQuits** requests a normal quit after a verified close action closes an app's last eligible window. It supports the red close button, Command-W, and supported native tab-close buttons. Optional any-window behavior applies only to the red button. Save prompts, remaining or replacement windows, exclusions, and uncertain Accessibility results prevent quitting. Shift-click force quit is separately opt-in, off by default, and warns about unsaved work.

**Middle scrolling** lets you hold the mouse wheel and move away from the press point to scroll vertically, horizontally, or diagonally. Distance controls speed, including while the pointer rests. Return to the dead zone to stop; release or press Escape to cancel. Short middle clicks are preserved when the original target can still be verified. Sensitivity, dead zone, direction, and per-app exceptions are adjustable.

Each feature has its own switch and keeps its settings while disabled. Pause all features from the menu bar. Launch at login is optional. There are no accounts, telemetry, third-party runtime dependencies, or automatic downloads.

## Install

Get the DMG from [GitHub Releases](https://github.com/Mxlted/mxlt-utils/releases), open it, and drag **mxlt-utils** into **Applications**. Launch that copy and enable the features you want. Both start disabled. Public release assets are a Developer ID signed, notarized DMG and `SHA256SUMS.txt`; a draft is not a published release.

Requires macOS 14 or later. Initial downloadable builds target Apple silicon (`arm64`). The deployment target is not a claim of runtime testing on every macOS version. See [testing and compatibility](docs/TESTING.md) for the actual evidence and remaining checks.

## Permissions and privacy

Enable Accessibility in **System Settings → Privacy & Security → Accessibility** when a feature asks for it. CallQuits inspects close controls and window state; middle scrolling observes the held button and generates scroll events. The Settings window shows permission and feature status and links directly to the correct page. Existing CallQuits permission, preferences, and login settings do not transfer.

Diagnostics are bounded, session-only state changes and verified close results. They do not store document names or contents, keystrokes, or raw input streams. The app makes no application network requests; the Releases link opens your browser only when clicked.

## Behavior and limits

- CallQuits requires explicit, verified close intent. It never quits an app merely because its window count reaches zero. Tabs and Command-W always use last-window graceful behavior.
- Minimized and other-Space windows are counted when Accessibility exposes them. Unreadable state fails closed. Apps with incomplete or unusual Accessibility trees may not support every close method.
- Finder, system processes, and mxlt-utils are always protected. Music, Spotify, Mail, Messages, FaceTime, Terminal, and iTerm start as editable quit exceptions. Discord retains the narrow verified hide-on-close handling from CallQuits.
- Middle scrolling stays bound to the original app, window, and press location. A moved, covered, hidden, closed, or otherwise unverifiable target cancels the gesture. The anchor chooses the nested scroll view; moving across windows does not retarget it.
- A short stationary middle press (up to half a second) is replayed as a paired click only after target validation. Longer stationary holds and canceled gestures are consumed. Middle-drag tools should be added to scrolling exceptions; Blender is excluded by default.
- Ordinary wheel and trackpad input are unchanged. Secure input, unusual event frameworks, remote desktops, and other input remappers can limit compatibility. Physical mouse and multi-display coverage are listed separately in the testing guide.

## Troubleshooting

If a feature is inactive, check its switch, global pause, and Accessibility status. After granting access, use **Check again**; if permission is granted but monitoring failed, use **Retry monitoring**. A timeout gets one automatic recovery attempt, followed by an explicit retry if needed. After replacing a development build, macOS may require removing a stale Accessibility entry, adding the Applications copy again, and relaunching.

Avoid running the standalone CallQuits monitor at the same time as mxlt-utils' CallQuits feature. You can keep standalone CallQuits installed and use only middle scrolling here. No migration changes the original app's settings.

If an app uses middle-drag for its own tools, add it to **Middle scrolling → Leave middle-drag unchanged**. For close behavior, add an app under **CallQuits → Keep these apps running**.

## Development

```sh
swift test
./scripts/build.sh
open build/mxlt-utils.app
```

The Swift package is the project source of truth. Xcode can open `Package.swift`; the bundle script produces the menu bar application. See [development](docs/DEVELOPMENT.md), [architecture](docs/ARCHITECTURE.md), [testing](docs/TESTING.md), and [releasing](docs/RELEASING.md).

MIT licensed. The CallQuits core and native close integration are adapted from [CallQuits](https://github.com/Mxlted/CallQuits), with its notice retained. [Vorssaint](https://github.com/vorssaint/vorssaint-utils) inspired the independently enabled utility concept; no GPL code or assets are included. See [provenance](docs/PROVENANCE.md).
