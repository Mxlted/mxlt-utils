# Disposable native fixture

The fixture is adapted from CallQuits under MIT. It uses only in-memory documents and deliberately remains running when its last window closes. Its bundle identifier is `com.mxlted.mxlt-utils.fixture`; it never impersonates Discord or a user application.

Build and launch it from the project root:

```sh
./scripts/build-fixture.sh
"build/mxlt-utils Fixture.app/Contents/MacOS/MxltUtilsFixture" \
  --state-path "$PWD/build/fixture-state.json"
```

Keep that process running while using another terminal to drive a case:

```sh
swift scripts/run-native-checks.swift \
  --state-path build/fixture-state.json --case scroll \
  > build/native-scroll-result.json
```

Enable the relevant feature in the running mxlt-utils app first, use the default scrolling direction, grant its Accessibility permission, and ensure another quit monitor is stopped. The runner also requires Accessibility and permission to post events through its invoking terminal/app. It checks the fixture identity, native window owner, foreground app, and the owner covering a click point before injecting input. It refuses to click another application. Avoid interacting with the mouse or keyboard during a case.

The state file atomically records at most 80 lifecycle messages, window IDs, fixed fixture-control coordinates, and aggregate middle-button and scroll counters, including counts tagged as mxlt-utils replay/output. Application-level scroll counters distinguish delivery to the expected window from delivery inside its content. One last scroll coordinate sample and the fixture content frame help diagnose coordinate conversion; there is no input stream. The fixture never records document contents, window titles, or keystrokes. Results identify their evidence as synthetic CGEvents through the running app. They do not establish physical mouse behavior, browser link behavior, or general application compatibility.

| Case | Launch flags | What it checks |
| --- | --- | --- |
| `click` | none | With scrolling enabled, one short middle click produces exactly one mxlt-utils-tagged paired down/up replay and no scroll. |
| `passthrough-click` | none | With scrolling disabled or the fixture excluded, one native paired click arrives without replay. |
| `wheel` | none | Ordinary untagged wheel input reaches and moves the native view unchanged. |
| `scroll` | none | Scroll begins outside the dead zone, continues without pointer movement, stops on return and release, and produces no middle click. |
| `nested-scroll` | none | The inner scroll view receives the gesture without redirecting it to the outer grid. |
| `escape` | none | Escape stops scrolling and the eventual button release produces no click. |
| `pin-target` | `--windows=2` | Crossing into the other fixture window never redirects scroll to it. |
| `pause-held` | none | The public Pause control stops an active held gesture; resuming cannot revive it, and a fresh click works. |
| `disable-held` | none | Disabling middle scrolling stops an active gesture without leaking a button half or replaying a canceled click. |
| `toggle-cycles` | none | Three disable/enable cycles alternate native passthrough and tagged replay, without changing CallQuits' enabled setting. |
| `quit` | none | Final red-button close causes a graceful quit, witnessed by the fixture. |
| `cancel-close` | `--dirty` | Canceling the native save sheet keeps the window alive beyond the close-attempt deadline. |
| `replacement` | `--replace` | A replacement window prevents a quit request. |
| `remaining-window` | `--windows=2` | Closing one window preserves the other. Add `--minimize-first` for a minimized survivor. |
| `tab-remains` | `--tabs=2` | Clicking a native tab Close button leaves the remaining tab/window open. |
| `command-remains` | `--tabs=2` | Command-W leaves the remaining tab/window open. |

Relaunch a fresh fixture between cases, especially scrolling cases whose view offsets change. The `quit` case is expected to terminate only this disposable process. For manual checks, its controls also provide dirty documents, replacement windows, hide-on-close behavior, blocking sheets, and more windows/tabs. The hide case must remain protected because the fixture does not have Discord's identity. Move a fixture window to another Space or display for the corresponding manual checks. The grid is a real two-axis `NSScrollView`, so visible scrolling and delivered scroll events can be checked separately.

The runner releases its injected middle-button state even after a failed assertion. A failed case remains a failure. The `click` case requires the utility marker on both replayed events and one paired action in the actual content view, beyond window-level event receipt. Scrolling cases require tagged events plus actual native viewport movement; ordinary successful fixture input alone does not prove utility interception.

## Lifecycle checks

For `pause-held`, `disable-held`, and `toggle-cycles`, open mxlt-utils Settings on **General** first. Launch the fixture with `--left-for-settings` to place it near the display's left edge, then ensure Settings does not cover its center. Start with middle scrolling enabled and global pause off. The runner reads and presses the actual Accessibility controls by their exact labels. It changes no defaults directly and uses no product test hooks. It restores the initial scrolling and pause choices, reports restoration failures, and verifies that CallQuits' enabled choice stays unchanged. Keep the mouse and keyboard idle until the result prints.

The held cases first require tagged scrolling to begin. They change the setting while the pointer remains away from the anchor, check that delivery stops, resume while the button is still held, and verify that a new movement does not revive the canceled gesture. They finally release and check a new short click. These checks need the real running feature to work; they cannot pass by testing a disabled utility.

## Disposable browser fixture

`BrowserFixture.html` has an outer and nested two-axis scroll area and a link back to the local fixture. It makes no network requests, stores nothing, and does not prevent normal input. `window.fixtureEvidence()` returns aggregate DOM event counters, scroll offsets, and element rectangles in viewport coordinates. The page displays the same data. Reload the page between cases.

For Chrome, use a fresh profile under the ignored `build/` directory. Launch the browser executable directly so the flags do not get handed to an existing personal-profile instance:

```sh
mkdir -p build
CHROME_FIXTURE_PROFILE=$(mktemp -d "$PWD/build/chrome-fixture.XXXXXX")
CHROME_FIXTURE_URL=$(python3 -c 'import pathlib; print(pathlib.Path("scripts/fixtures/BrowserFixture.html").resolve().as_uri())')
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir="$CHROME_FIXTURE_PROFILE" \
  --remote-debugging-port=0 \
  --no-first-run --no-default-browser-check --disable-sync \
  --disable-background-networking --new-window "$CHROME_FIXTURE_URL"
```

This is a separate test profile; do not sign in or open personal sites in it. The random local debugging port is recorded in that profile's `DevToolsActivePort`. The optional read-only collector (Node.js 22 or newer) checks the exact fixture URL, reads `window.fixtureEvidence()`, and counts fixture tabs:

```sh
node scripts/read-browser-evidence.mjs --profile "$CHROME_FIXTURE_PROFILE" \
  > build/browser-before.json
```

Use another output name for the snapshot after a gesture. The collector accepts only `build/chrome-fixture.*` profiles and never dispatches input. Drive gestures through real native CGEvents or a physical mouse, so the mxlt-utils tap is exercised. `isTrusted` counts alone do not prove physical input or mxlt-utils interception. For cleanup, quit only the process verified to use this exact profile, then remove that disposable profile if it is no longer needed.

Use these checks with a baseline copy of the page's evidence:

- Short middle click on the link: exactly one additional tab with `openedLink: true`, one paired down/up, and one auxiliary click. Compare against scrolling disabled if needed.
- Hold and drag over the outer grid: wheel delivery and both offsets advance while the pointer stays still, then stop on dead-zone return and release. No middle-click events should leak from the consumed gesture.
- Start inside the nested area: only the nested offsets advance until the inner view reaches an edge.
- Escape, pause, or disable during a hold: scrolling stops, no delayed click opens a tab, and a fresh gesture works afterward.

DOM rectangles use CSS viewport coordinates, not macOS global event coordinates. Verify the native browser window and point before injecting events; do not guess global coordinates from a browser rectangle. Keep Chrome's own built-in behavior separate from utility behavior by comparing the disabled baseline and requiring continuous held movement plus cancellation. A passing native fixture test does not replace this browser check.

The isolated profile also follows Chrome's current debugging requirement: since Chrome 136, remote debugging flags require a nondefault user-data directory. See [Chrome's announcement](https://developer.chrome.com/blog/remote-debugging-port) and [Chromium's profile guide](https://www.chromium.org/developers/creating-and-using-profiles/).
