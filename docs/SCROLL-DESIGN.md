# Middle-button scrolling

The scroll engine is original implementation. It uses public Core Graphics input APIs and has no runtime dependency on another mouse utility.

## Gesture decisions

`ScrollGesture` is a value type in `MxltCore`. It stores only an anchor, captured settings, start time, phase, target velocity, and motion integration state. The native service owns events, target identity, timers, and the indicator.

A middle press starts pending. A circular dead zone (8 logical points by default) avoids accidental scrolling. Crossing it permanently consumes that click, even if the pointer returns to the anchor. Speed is proportional to distance outside the dead zone, multiplied by sensitivity, and capped at 2,400 points/second in total, including diagonal movement. Returning inside the zone sets velocity to zero and clears the smoothing state and fractional travel. A timer continues integrating the target velocity while the pointer rests. Optional smoothing, enabled by default, eases speed changes with an exponential response; each axis stops immediately at zero and resets on reversal. Exact integration preserves distance across tick rates, and accepted elapsed time is capped to prevent catch-up jumps. There is no momentum or delayed stop after release or cancellation.

A pending press lasting at most half a second may become a click on release, provided the original target is still verified. A longer stationary hold is consumed. The release position is checked again so a missing movement event cannot turn a drag into a click. Escape and other cancellation paths retain a cancelled phase until the intercepted release has been handled; they never replay a click. Settings are captured at press so changes cannot reverse an active gesture. Invalid coordinates/timestamps fail closed; malformed persisted settings fall back to bounded values.

## Native integration constraints

Capture original event PID and window identity. Validate that identity instead of substituting the frontmost app. Revalidate before emitting scroll or click replay; cancel if the original window/app becomes unavailable. Send scroll at the original anchor to the original process. Crossing window edges must not retarget the gesture. Coordinates remain global Quartz logical points; do not multiply them by display backing scale. Native delivery still needs live tests across multiple displays and nested scroll views.

Hold the original down until release or scroll activation. Replay a complete down/up pair only for an eligible short click, with the original position, button, flags, and verified target. Tag synthesized events and ignore that tag at both feature boundaries. Intercepted middle-down must explicitly cancel CallQuits' pending close intent. Cancellation drops output immediately and must consume any remaining button-up where possible; disable/permission loss must release native resources without emitting a replacement click.

Ordinary wheel and trackpad events are untouched. Middle-drag applications need exclusions. Native injection cannot promise compatibility with every event framework or secure-input context.

## Research and rationale

Reviewed October 21, 2026:

- Apple's [CGEvent overview](https://developer.apple.com/documentation/coregraphics/cgevent) describes native event annotation and dispatch. Use an annotated-session tap for original recipient identity.
- Apple exposes [eventTargetUnixProcessID](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventtargetunixprocessid), [mouseEventWindowUnderMousePointer](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventwindowundermousepointer), and [postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)). These support pinning delivery to the initial recipient, but do not establish view-level compatibility by themselves.
- [eventSourceUserData](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceuserdata) supplies a 64-bit marker for rejecting the app's own synthesized events. [Pixel scroll event creation](https://developer.apple.com/documentation/coregraphics/cgevent/init(scrollwheelevent2source:units:wheelcount:wheel1:wheel2:wheel3:)) avoids modifying system scroll preferences.
- [LinearMouse](https://github.com/linearmouse/linearmouse) is an active, MIT-licensed native mouse utility, reviewed as an implementation/compatibility reference. Its [issue 1367](https://github.com/linearmouse/linearmouse/issues/1367) reports apparent pointer freezing during held autoscroll across browsers and Electron applications. This is a reason to verify pointer movement in the running app, not just scroll deltas. No LinearMouse code or assets were copied.

Pure tests cover transitions, dead-zone boundary, speed and diagonal cap, settings sanitation, release/cancel cleanup, replay eligibility, stale/invalid input, and repeated starts/stops. Those tests do not establish physical mouse or app compatibility; record native/synthetic/physical results separately in the testing documentation.
