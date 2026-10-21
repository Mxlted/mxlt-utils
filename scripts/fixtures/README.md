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

The state file atomically records at most 80 lifecycle messages, window IDs, fixed fixture-control coordinates, and aggregate middle-button and scroll counters, including counts tagged as mxlt-utils replay/output. It does not record document contents, window titles, keystrokes, or input streams. Results identify their evidence as synthetic CGEvents through the running app. They do not establish physical mouse behavior, browser link behavior, or general application compatibility.

| Case | Launch flags | What it checks |
| --- | --- | --- |
| `click` | none | With scrolling enabled, one short middle click produces exactly one mxlt-utils-tagged paired down/up replay and no scroll. |
| `passthrough-click` | none | With scrolling disabled or the fixture excluded, one native paired click arrives without replay. |
| `wheel` | none | Ordinary untagged wheel input reaches and moves the native view unchanged. |
| `scroll` | none | Scroll begins outside the dead zone, continues without pointer movement, stops on return and release, and produces no middle click. |
| `nested-scroll` | none | The inner scroll view receives the gesture without redirecting it to the outer grid. |
| `escape` | none | Escape stops scrolling and the eventual button release produces no click. |
| `pin-target` | `--windows=2` | Crossing into the other fixture window never redirects scroll to it. |
| `quit` | none | Final red-button close causes a graceful quit, witnessed by the fixture. |
| `cancel-close` | `--dirty` | Canceling the native save sheet keeps the window alive beyond the close-attempt deadline. |
| `replacement` | `--replace` | A replacement window prevents a quit request. |
| `remaining-window` | `--windows=2` | Closing one window preserves the other. Add `--minimize-first` for a minimized survivor. |
| `tab-remains` | `--tabs=2` | Clicking a native tab Close button leaves the remaining tab/window open. |
| `command-remains` | `--tabs=2` | Command-W leaves the remaining tab/window open. |

Relaunch a fresh fixture between cases, especially scrolling cases whose view offsets change. The `quit` case is expected to terminate only this disposable process. For manual checks, its controls also provide dirty documents, replacement windows, hide-on-close behavior, blocking sheets, and more windows/tabs. The hide case must remain protected because the fixture does not have Discord's identity. Move a fixture window to another Space or display for the corresponding manual checks. The grid is a real two-axis `NSScrollView`, so visible scrolling and delivered scroll events can be checked separately.

The runner releases its injected middle-button state even after a failed assertion. A failed case remains a failure. The `click` case requires the utility marker on both replayed events, and scrolling cases require tagged events plus actual native viewport movement; ordinary successful fixture input alone does not prove utility interception.
