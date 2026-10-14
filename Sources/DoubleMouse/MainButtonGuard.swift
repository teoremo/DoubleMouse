import CoreGraphics

/// Tag stamped on every event DoubleMouse posts, so the guard can tell blue-pointer
/// events from the main device's real ones.
let syntheticEventMarker: Int64 = 0x444D4F55 // "DMOU"

/// macOS has one global mouse-button state, so the two pointers can corrupt each other's
/// clicks. This watches the main device's real buttons (to hold off blue clicks while one
/// is down) and can swallow them while a blue drag is in progress.
final class MainButtonGuard {
    /// While true, real button events from the main device are dropped.
    var blocksMainButtons = false

    private(set) var downButtons = Set<CGMouseButton>()
    private var droppedButtons = Set<CGMouseButton>()
    private var tap: CFMachPort?

    var isMainButtonDown: Bool { !downButtons.isEmpty }

    func start() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let guardian = Unmanaged<MainButtonGuard>.fromOpaque(context).takeUnretainedValue()
                return guardian.handle(type: type, event: event)
            },
            userInfo: context
        ) else {
            debugLog("main button guard: event tap unavailable (needs Accessibility)")
            return
        }

        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let button: CGMouseButton = (type == .leftMouseDown || type == .leftMouseUp) ? .left : .right
        let isDown = type == .leftMouseDown || type == .rightMouseDown

        if isDown {
            if blocksMainButtons {
                droppedButtons.insert(button)
                return nil
            }
            downButtons.insert(button)
        } else {
            // Drop the release of a press we dropped; pass the release of one we let through.
            if droppedButtons.remove(button) != nil {
                return nil
            }
            downButtons.remove(button)
        }
        return Unmanaged.passUnretained(event)
    }
}
