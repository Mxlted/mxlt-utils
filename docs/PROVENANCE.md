# Source provenance and reference decisions

Reviewed October 21, 2026.

## CallQuits

The integration starts from [CallQuits commit `7572c65`](https://github.com/Mxlted/CallQuits/tree/7572c6589c776571ce1645fb55f7b2f4ae45400c). At inspection, the supplied local checkout, the separately installed development checkout, and GitHub `main` all pointed to this exact commit. Both local checkouts had no tracked changes or untracked source files. All 49 tracked file blobs matched GitHub, including source, settings, tests, documentation, resources, and build/release scripts; the two local copies also matched byte for byte. Ignored local guidance and build output were not imported.

CallQuits is [MIT licensed](https://github.com/Mxlted/CallQuits/blob/7572c6589c776571ce1645fb55f7b2f4ae45400c/LICENSE), copyright 2026 CallQuits contributors. Its copyright and permission notice must accompany reused source and distributed app copies. Its Swift package has no external dependencies. mxlt-utils uses MIT for its original code and adapted CallQuits code; attribution is retained with the project license.

The reusable pieces are the deterministic close policy, event/gesture identity checks, Accessibility adapter and monitor, settings behavior, regression tests, disposable fixtures, and useful build/packaging guardrails. mxlt-utils has its own application shell, identity, icon, preferences, permission grant, login registration, and feature lifecycle. Building it must not require a CallQuits checkout. Historical CallQuits signing and test results are evidence about that release, not verification of mxlt-utils.

| Upstream component | Integration responsibility |
| --- | --- |
| `CallQuitsCore/CloseSession.swift` | Stable close confirmation, cancellation, sheets, replacements, remaining windows, and the narrow Discord hide transition. |
| `CallQuitsCore/CloseGesture.swift` | Verified down/up and shortcut intent; tabs and Command-W always use last-window graceful quit. |
| `CallQuitsCore/EventIdentity.swift` | Original native recipient and exact event-stamped window ownership. Never substitute the frontmost app. |
| `CallQuitsCore/AppProtection.swift` | Finder/system/self and application-state eligibility checks, repeated immediately before termination. |
| `AccessibilityClient.swift` | Bounded, validated AX capture; one narrowly justified stale-element recovery; native tab semantics and Brave sibling hit resolution. |
| `CloseMonitor.swift` | Passive annotated-session capture, worker queue, observer lifetime, bounded timeout recovery, and invalidation. |
| Existing core and integration tests | Preserve the behavioral regression coverage; adapt app/model names and add cross-feature cancellation coverage. |

Important boundaries are intentional: unknown AX state means no quit; canceled attempts never revive; minimized and other-Space windows count when AX exposes them; tab closure leaving a window cannot authorize quit. Force quit remains off by default, explicitly acknowledged, and limited to a verified Shift-click on the red window button. Discord's exception applies only to its verified normal red-button close on a sole nonminimized window, with same-process hide evidence and unchanged window state. It never extends to force quit, tabs, or shortcuts.

The scroll feature must explicitly cancel pending close intent when it consumes an original auxiliary-button press. Replayed input must be marked and ignored as new close intent. Disabling either feature must remove that feature's resources without overwriting the other's callbacks or enabled setting.

## Original application and scrolling

mxlt-utils has its own application shell, visual identity, settings, feature lifecycle, and middle-button scrolling implementation. The scroll policy, velocity smoothing, and native event adapter are implemented in this repository using public macOS APIs, without importing another utility's code or assets.

The two features are independently enabled and retain their settings when disabled. CallQuits supplies the verified-close behavior described above. Middle scrolling adds held-button scrolling with target validation, short-click preservation, and immediate cancellation. Ordinary wheel and trackpad input remain unchanged.

## Accessibility entry deletion research

The October 21, 2026 follow-up distinguishes turning Accessibility off from deleting an enabled entry while the app is running. The earlier trust-only watchdog did not cover a stale `AXIsProcessTrusted()` result. These references informed an original implementation; no source or assets were imported and no dependency was added.

| Reference | Relevant behavior and limits |
| --- | --- |
| [Deskflow issue 9562](https://github.com/deskflow/deskflow/issues/9562) and [fix 9579](https://github.com/deskflow/deskflow/pull/9579) | Reports frozen local input after deleting the enabled Accessibility entry. The fix polls trust, disables interception and requests process exit on loss. Its trust check alone does not establish protection against a stale positive result. |
| [Mos Interceptor.swift](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/Mos/Utils/Interceptor.swift) | Checks trust around start/recovery, limits repeated restarts, and explicitly disables/invalidates taps on destruction. It does not supply a fresh filtering-capability probe for row deletion. |
| [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils/tree/1235843ab1746974ed5c3c74f0cdb06a4c8fb923) | The supplied read-only checkout polls trust, explicitly invalidates scroll taps, and suspends interceptors before its own permission reset. This does not establish detection of external deletion with stale trust. Its GPL source remains separate. |
| [axwatch 0.1.0 documentation](https://docs.rs/axwatch/0.1.0/axwatch/) | Reports that row deletion can leave trust true and recommends a fresh filtering-tap probe. Its permission notification names are undocumented; mxlt-utils does not depend on them. |
| [Apple CGEvent.tapCreate documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) | Unauthorized event bits are removed; an empty mask fails creation. A keyboard-only filtering probe avoids accepting a mouse-only tap after keyboard bits are stripped. Context7 and the installed Apple SDK headers were also consulted. |

mxlt-utils now checks both trust and filtering capability before starting and from its existing background watchdog. The temporary probe uses public APIs, immediately disables and invalidates its port, and installs no run-loop source or synthetic input. A failed check detaches the existing filter and prevents recovery until a new successful check. Timeout recovery also checks capability off the input callback. This is a response to the reported failure mode, not evidence that every macOS version reliably reports revocation or releases input within a guaranteed interval. Real deletion/regrant behavior and probe overhead still require manual validation.
