import AppKit
import MxltCore

/// Shared event stamping keeps paired replay and generated scroll bound to the same recipient.
enum MiddleScrollEventRouting {
    static let syntheticTag: Int64 = 0x4D584C54

    static func source() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        // Core Graphics can retain source-derived userData when a field is assigned later.
        // Set the marker on a private source before constructing every generated event.
        source.userData = syntheticTag
        // Generated scrolling/replay must never suppress real mouse or keyboard
        // input, including if permission disappears during event delivery.
        source.localEventsSuppressionInterval = 0
        let hardware: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(hardware, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(hardware, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }

    static func replayEvent(_ original: CGEvent, template: CGEvent, processID: pid_t, windowID: CGWindowID,
                            anchor: ScrollPoint) -> CGEvent? {
        guard original.type == .otherMouseDown || original.type == .otherMouseUp,
              original.getIntegerValueField(.mouseEventButtonNumber) == 2,
              template.type == .otherMouseDown,
              template.getIntegerValueField(.mouseEventButtonNumber) == 2,
              template.location == CGPoint(x: anchor.x, y: anchor.y),
              let source = source(), let event = template.copy() else { return nil }
        // Both halves use down's WindowServer context: a release near a window edge can carry
        // another window's native context even though the pointer remains inside the dead zone.
        // Preserve each half's time/modifiers/button semantics without borrowing that recipient.
        event.type = original.type
        event.setSource(source)
        event.timestamp = original.timestamp
        event.flags = original.flags
        for field in [CGEventField.mouseEventClickState, .mouseEventNumber] {
            event.setIntegerValueField(field, value: original.getIntegerValueField(field))
        }
        event.setDoubleValueField(.mouseEventPressure, value: original.getDoubleValueField(.mouseEventPressure))
        stamp(event, processID: processID, windowID: windowID, anchor: anchor)
        return event
    }

    static func scrollEvent(template: CGEvent, deltaX: Int32, deltaY: Int32, processID: pid_t,
                            windowID: CGWindowID, anchor: ScrollPoint, timestamp: CGEventTimestamp) -> CGEvent? {
        guard template.type == .otherMouseDown,
              template.location == CGPoint(x: anchor.x, y: anchor.y),
              let source = source(), let event = template.copy(),
              let values = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { return nil }
        // Retain WindowServer/AppKit routing from the original captured down. A fresh CGEvent's
        // under-pointer fields alone do not establish the recipient's native window context.
        event.type = .scrollWheel
        event.setSource(source)
        let integerFields: [CGEventField] = [
            .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
            .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
            .scrollWheelEventScrollCount, .scrollWheelEventInstantMouser
        ]
        for field in integerFields { event.setIntegerValueField(field, value: values.getIntegerValueField(field)) }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                      .scrollWheelEventFixedPtDeltaAxis3] {
            event.setDoubleValueField(field, value: values.getDoubleValueField(field))
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.timestamp = timestamp
        event.flags = []
        stamp(event, processID: processID, windowID: windowID, anchor: anchor)
        return event
    }

    static func stamp(_ event: CGEvent, processID: pid_t, windowID: CGWindowID, anchor: ScrollPoint) {
        // The template already contains the anchor in its native recipient context. Reassigning
        // global location here can rewrite local transport coordinates for a foreign NSWindow.
        event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(processID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
    }
}

/// Pins an app-owned surface, including bookmark menus, popups and floating panels.
/// Window level alone does not establish whether a native middle click is valid.
struct MiddleScrollWindowSnapshot {
    let bounds: CGRect
    let layer: Int

    init?(window: [String: Any], processID: pid_t, windowID: CGWindowID, anchor: ScrollPoint) {
        guard let number = window[kCGWindowNumber as String] as? NSNumber, number.int64Value == Int64(windowID),
              let owner = window[kCGWindowOwnerPID as String] as? NSNumber, owner.int64Value == Int64(processID),
              let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue >= 0,
              let alpha = window[kCGWindowAlpha as String] as? NSNumber,
              alpha.doubleValue.isFinite, alpha.doubleValue > 0,
              anchor.isFinite, let bounds = MiddleScrollWindowRouting.bounds(window),
              bounds.contains(CGPoint(x: anchor.x, y: anchor.y)) else { return nil }
        self.bounds = bounds
        self.layer = layer.intValue
    }
}

/// WindowServer metadata policy, exercised without capturing a screen or contacting a real app.
enum MiddleScrollWindowRouting {
    static func isValid(windows: [[String: Any]], processID: pid_t, windowID: CGWindowID,
                        initialBounds: CGRect, initialLayer: Int, anchor: ScrollPoint, ownProcessID: pid_t,
                        systemCanvases: [pid_t: Int] = [:], displayBounds: [CGRect] = [],
                        systemHitProcessID: pid_t? = nil) -> Bool {
        let point = CGPoint(x: anchor.x, y: anchor.y)
        for window in windows {
            guard let bounds = bounds(window),
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber else { return false }
            guard bounds.contains(point), alpha.doubleValue > 0 else { continue }
            // macOS 27 exposes Dock/Notification Center full-display canvases as alpha 1.
            // Only verified process/layer pairs and exact display rectangles can qualify;
            // a system-wide AX hit must prove that the anchor still belongs to the target.
            if systemCanvases[owner.int32Value] == layer.intValue, displayBounds.contains(bounds) {
                guard systemHitProcessID == processID else { return false }
                continue
            }
            // Only our floating, non-interactive indicator is ignored. A normal settings window
            // covering the anchor cancels just like any other window or menu.
            if owner.int32Value == ownProcessID && layer.intValue == Int(NSWindow.Level.floating.rawValue) { continue }
            return number.uint32Value == windowID && owner.int32Value == processID && bounds == initialBounds
                && layer.intValue == initialLayer
        }
        return false
    }

    static func isSystemCanvas(_ window: [String: Any], systemCanvases: [pid_t: Int], displayBounds: [CGRect]) -> Bool {
        guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = window[kCGWindowLayer as String] as? NSNumber,
              systemCanvases[owner.int32Value] == layer.intValue,
              let frame = bounds(window), displayBounds.contains(frame) else { return false }
        return true
    }

    static func bounds(_ window: [String: Any]) -> CGRect? {
        guard let raw = window[kCGWindowBounds as String] as? [String: Any],
              let x = raw["X"] as? NSNumber, let y = raw["Y"] as? NSNumber,
              let width = raw["Width"] as? NSNumber, let height = raw["Height"] as? NSNumber else { return nil }
        let values = [x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue]
        guard values.allSatisfy({ $0.isFinite }), width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    }

}
