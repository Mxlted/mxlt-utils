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
        return source
    }

    static func replayEvent(_ original: CGEvent, processID: pid_t, windowID: CGWindowID,
                            anchor: ScrollPoint) -> CGEvent? {
        guard original.type == .otherMouseDown || original.type == .otherMouseUp,
              original.getIntegerValueField(.mouseEventButtonNumber) == 2,
              let source = source(),
              let event = CGEvent(mouseEventSource: source, mouseType: original.type,
                                  mouseCursorPosition: CGPoint(x: anchor.x, y: anchor.y), mouseButton: .center) else { return nil }
        event.flags = original.flags
        event.timestamp = original.timestamp
        event.setIntegerValueField(.mouseEventClickState, value: original.getIntegerValueField(.mouseEventClickState))
        event.setDoubleValueField(.mouseEventPressure, value: original.getDoubleValueField(.mouseEventPressure))
        stamp(event, processID: processID, windowID: windowID, anchor: anchor)
        return event
    }

    static func stamp(_ event: CGEvent, processID: pid_t, windowID: CGWindowID, anchor: ScrollPoint) {
        event.location = CGPoint(x: anchor.x, y: anchor.y)
        event.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(processID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
    }
}

/// WindowServer metadata policy, exercised without capturing a screen or contacting a real app.
enum MiddleScrollWindowRouting {
    static func isValid(windows: [[String: Any]], processID: pid_t, windowID: CGWindowID,
                        initialBounds: CGRect, anchor: ScrollPoint, ownProcessID: pid_t,
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
