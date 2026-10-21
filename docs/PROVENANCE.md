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

## Vorssaint

[Vorssaint](https://github.com/vorssaint/vorssaint-utils/tree/7c7b6d56679f04ebe53256c5817f10d0a04f7e86) was inspected at commit `7c7b6d5`. Its [README](https://github.com/vorssaint/vorssaint-utils/blob/7c7b6d56679f04ebe53256c5817f10d0a04f7e86/README.md) identifies the project as GPL-3.0-or-later; its [license](https://github.com/vorssaint/vorssaint-utils/blob/7c7b6d56679f04ebe53256c5817f10d0a04f7e86/LICENSE) contains GPLv3, and source headers identify the later-version option.

Vorssaint is a product and UX reference only. No Vorssaint implementation, assets, branding, or layouts are copied. The useful ideas are one menu bar entry, separately enabled features that stop work when disabled and retain settings, compact controls, and permissions explained at the point of use. mxlt-utils implements these ideas independently for two focused features. It does not import Vorssaint's feature-installation platform, broad module catalog, or private system integrations.

Vorssaint's quit-on-close behavior is not the specification for this project. The explicit verified-close safeguards and current functionality come from CallQuits. Ordinary wheel smoothing, acceleration, and trackpad emulation in the reference are also separate from mxlt-utils' required middle-button hold-and-drag scrolling.
