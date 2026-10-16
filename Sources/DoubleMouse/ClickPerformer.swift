import AppKit
import ApplicationServices

/// Roles where an Accessibility press is equivalent to a real click. Anything else — text
/// fields, tables, web areas, canvases — needs a real event, because AXPress does not place
/// a caret, select a row, or start a selection.
private let pressableRoles: Set<String> = [
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXPopUpButton",
    "AXMenuButton",
    "AXMenuItem",
    "AXDisclosureTriangle"
]

final class ClickPerformer {
    private let source = CGEventSource(stateID: .privateState)
    var mainGuard: MainButtonGuard?

    init() {
        source?.localEventsSuppressionInterval = 0
        // Every cursor warp otherwise makes macOS ignore the main device for ~0.25 s, which
        // freezes the main pointer for as long as the blue one is clicking or dragging.
        for state in [CGEventSourceStateID.combinedSessionState, .hidSystemState] {
            CGEventSource(stateID: state)?.localEventsSuppressionInterval = 0
        }
    }

    /// macOS keeps one global mouse-button state, so a blue click has to be emitted at the
    /// blue pointer and the system cursor put back where the user left it. The Accessibility
    /// path avoids that round trip entirely when the target is a plain control.
    func performClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        if performAccessibilityPress(at: point) {
            return
        }
        postMouseEvent(.leftMouseDown, button: .left, at: point)
        postMouseEvent(.leftMouseUp, button: .left, at: point, returningTo: returnPoint)
    }

    func performRightClick(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        // No Accessibility equivalent: AXPress cannot raise a context menu.
        postMouseEvent(.rightMouseDown, button: .right, at: point)
        postMouseEvent(.rightMouseUp, button: .right, at: point, returningTo: returnPoint)
    }

    func beginDrag(at point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDown, button: .left, at: point, returningTo: returnPoint)
    }

    func drag(to point: CGPoint, returningTo returnPoint: CGPoint) {
        postMouseEvent(.leftMouseDragged, button: .left, at: point, returningTo: returnPoint)
    }

    func endDrag(at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        postMouseEvent(.leftMouseUp, button: .left, at: point, returningTo: returnPoint)
    }

    func scroll(at point: CGPoint, delta: CGPoint, pixels: Bool = false) {
        let returnPoint = currentCursor()
        guard delta != .zero,
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: pixels ? .pixel : .line,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(delta.y)),
                wheel2: Int32(clamping: Int(delta.x)),
                wheel3: 0
              ) else {
            return
        }

        event.location = quartzPoint(fromAppKitPoint: point)
        mainGuard?.noteBlueActivity()
        event.post(tap: .cghidEventTap)
        restoreMainCursor(fallback: returnPoint)
    }

    /// The real cursor in AppKit coordinates. NSEvent.mouseLocation lags behind the window
    /// server, so restoring to it can park the cursor at a stale spot after a blue click.
    func currentCursor() -> CGPoint {
        guard let quartz = CGEvent(source: nil)?.location else {
            return NSEvent.mouseLocation
        }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            if bounds.contains(quartz) {
                return CGPoint(x: screen.frame.minX + (quartz.x - bounds.minX),
                               y: screen.frame.minY + (bounds.maxY - quartz.y))
            }
        }
        return NSEvent.mouseLocation
    }

    /// Posted events reach the window server after this returns, and each one drags the
    /// cursor to the blue pointer. Warp now, then again once they have landed.
    private func restoreMainCursor(fallback: CGPoint) {
        func warp() {
            if let target = mainGuard?.mainLocation {
                CGWarpMouseCursorPosition(target)
                CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            } else {
                moveSystemCursor(to: fallback)
            }
        }
        warp()
        for delay in [0.015, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { warp() }
        }
    }

    func moveSystemCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitPoint: point))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    private func performAccessibilityPress(at point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        let quartzPoint = quartzPoint(fromAppKitPoint: point)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(quartzPoint.x), Float(quartzPoint.y), &element) == .success,
              let element else {
            return false
        }

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String,
              pressableRoles.contains(role) else {
            return false
        }

        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func postMouseEvent(_ type: CGEventType, button: CGMouseButton, at point: CGPoint, returningTo returnPoint: CGPoint? = nil) {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: quartzPoint(fromAppKitPoint: point),
            mouseButton: button
        )
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        mainGuard?.noteBlueActivity()
        event?.post(tap: .cghidEventTap)

        if let returnPoint {
            restoreMainCursor(fallback: returnPoint)
        }
    }

    func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            return CGPoint(
                x: displayBounds.minX + (point.x - screen.frame.minX),
                y: displayBounds.maxY - (point.y - screen.frame.minY)
            )
        }

        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: point.x, y: mainBounds.maxY - point.y)
    }
}
