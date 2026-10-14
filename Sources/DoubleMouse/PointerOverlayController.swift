import AppKit

/// Raw HID counts are not screen pixels: a 1600 DPI mouse moves far more counts per
/// centimetre than the macOS cursor moves points, and macOS applies its own acceleration
/// curve that we never see. Both knobs are here so the blue pointer can be matched to the
/// hardware by feel.
///
/// ponytail: linear ramp to 2x at 40 counts per report. Swap for a lookup table if it
/// still drifts from the system cursor at the extremes.
func scaledDelta(_ delta: CGPoint, sensitivity: Double, acceleration: Bool) -> CGPoint {
    var gain = sensitivity
    if acceleration {
        gain *= 1 + min(hypot(delta.x, delta.y), 40) / 40
    }
    return CGPoint(x: delta.x * gain, y: delta.y * gain)
}

final class PointerOverlayController {
    /// One window per display. With "Displays have separate Spaces" a single window cannot
    /// span monitors, so a union-sized window is only drawn on one of them.
    private var overlays: [(window: NSWindow, view: PointerView)] = []

    var sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }

    var acceleration = UserDefaults.standard.object(forKey: "acceleration") as? Bool ?? true {
        didSet { UserDefaults.standard.set(acceleration, forKey: "acceleration") }
    }

    var style = PointerStyle.load() {
        didSet {
            style.save()
            overlays.forEach { $0.view.style = style }
        }
    }

    /// Screen coordinates. Each view draws in its own space, so it gets the converted point.
    private(set) var secondaryPointerPosition = CGPoint(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 300)

    init() {
        rebuildOverlays()

        // Plugging in a display or changing resolution moves every screen origin. Without
        // this the overlays keep the old frames and the pointer cannot reach the new screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
    }

    func show() {
        overlays.forEach { $0.window.orderFrontRegardless() }
        debugLog("overlays \(overlays.map { $0.window.frame })")
    }

    func moveSecondaryBy(_ delta: CGPoint) {
        let scaled = scaledDelta(delta, sensitivity: sensitivity, acceleration: acceleration)
        secondaryPointerPosition = clampedPoint(
            CGPoint(x: secondaryPointerPosition.x + scaled.x, y: secondaryPointerPosition.y - scaled.y)
        )
        syncViewPositions()
    }

    func pulseSecondary() {
        overlays.forEach { $0.view.pulse() }
    }

    private func rebuildOverlays() {
        let wasVisible = overlays.contains { $0.window.isVisible }
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let view = PointerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.style = style
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            return (window, view)
        }
        syncViewPositions()
        if wasVisible {
            show()
        }
    }

    private func screensChanged() {
        rebuildOverlays()
        secondaryPointerPosition = clampedPoint(secondaryPointerPosition)
        syncViewPositions()
    }

    private func syncViewPositions() {
        for overlay in overlays {
            let origin = overlay.window.frame.origin
            overlay.view.pointerPosition = CGPoint(
                x: secondaryPointerPosition.x - origin.x,
                y: secondaryPointerPosition.y - origin.y
            )
        }
    }

    /// Keeps the pointer on an actual screen. Displays of different sizes leave empty
    /// corners inside their bounding box, and the pointer must not disappear into them.
    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let frame = screen.frame
            // maxX/maxY are one past the last pixel.
            let candidate = CGPoint(
                x: min(max(point.x, frame.minX), frame.maxX - 1),
                y: min(max(point.y, frame.minY), frame.maxY - 1)
            )
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}

/// How the second pointer looks. Persisted in UserDefaults.
struct PointerStyle: Equatable {
    var color: NSColor
    var mirrored: Bool
    var scale: CGFloat
    /// Seconds a trail ghost lasts; 0 turns the trail off.
    var trail: TimeInterval

    static let defaultColor = NSColor(srgbRed: 0.12, green: 0.53, blue: 1.0, alpha: 1)

    static func load() -> PointerStyle {
        let defaults = UserDefaults.standard
        var color = defaultColor
        if let c = defaults.array(forKey: "pointerColor") as? [Double], c.count == 4 {
            color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        return PointerStyle(
            color: color,
            mirrored: defaults.object(forKey: "pointerMirrored") as? Bool ?? false,
            scale: CGFloat(defaults.object(forKey: "pointerScale") as? Double ?? 1.0),
            trail: defaults.object(forKey: "pointerTrail") as? Double ?? 0
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        let rgb = color.usingColorSpace(.sRGB) ?? color
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map(Double.init), forKey: "pointerColor")
        defaults.set(mirrored, forKey: "pointerMirrored")
        defaults.set(Double(scale), forKey: "pointerScale")
        defaults.set(trail, forKey: "pointerTrail")
    }
}

final class PointerView: NSView {
    var style = PointerStyle.load() {
        didSet {
            if style.trail == 0 {
                trail.removeAll()
            }
            needsDisplay = true
        }
    }

    /// View coordinates, not screen coordinates.
    var pointerPosition: CGPoint = .zero {
        didSet {
            if style.trail > 0 {
                recordTrail(oldValue)
            }
            // Repainting the union of every screen on each HID report is the whole frame
            // budget on a large desktop. Only the arrow, its trail and its pulse change.
            setNeedsDisplay(dirtyRect(around: oldValue))
            setNeedsDisplay(dirtyRect(around: pointerPosition))
        }
    }

    private var pulseUntil: Date?
    private var trail: [(point: CGPoint, time: Date)] = []
    private var trailTimer: Timer?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTrail()
        drawArrow(at: pointerPosition, alpha: 1)
        drawPulseIfNeeded()
    }

    func pulse() {
        pulseUntil = Date().addingTimeInterval(0.35)
        setNeedsDisplay(dirtyRect(around: pointerPosition))
    }

    private var margin: CGFloat { 48 * style.scale }

    private func dirtyRect(around point: CGPoint) -> NSRect {
        // Covers the arrow plus the widest pulse ring.
        NSRect(x: point.x - margin, y: point.y - margin, width: margin * 2, height: margin * 2)
    }

    // MARK: Trail

    private func recordTrail(_ previous: CGPoint) {
        let now = Date()
        // Ghosts are dropped only at a minimum spacing, so a slow drift does not pile
        // dozens of arrows on top of each other.
        if trail.last.map({ hypot($0.point.x - previous.x, $0.point.y - previous.y) >= 10 * style.scale }) ?? true {
            trail.append((previous, now))
        }
        pruneTrail(now: now)
        startTrailTimerIfNeeded()
    }

    private func pruneTrail(now: Date) {
        let expired = trail.filter { now.timeIntervalSince($0.time) >= style.trail }
        for ghost in expired {
            setNeedsDisplay(dirtyRect(around: ghost.point))
        }
        trail.removeAll { now.timeIntervalSince($0.time) >= style.trail }
    }

    /// Ghosts keep fading after the mouse stops, so they need their own redraw clock.
    private func startTrailTimerIfNeeded() {
        guard trailTimer == nil else { return }
        trailTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.pruneTrail(now: Date())
            for ghost in self.trail {
                self.setNeedsDisplay(self.dirtyRect(around: ghost.point))
            }
            if self.trail.isEmpty {
                timer.invalidate()
                self.trailTimer = nil
            }
        }
    }

    private func drawTrail() {
        let now = Date()
        for ghost in trail {
            let age = now.timeIntervalSince(ghost.time) / style.trail
            guard age < 1 else { continue }
            drawArrow(at: ghost.point, alpha: 0.5 * (1 - age), shadow: false)
        }
    }

    // MARK: Pulse

    private func drawPulseIfNeeded() {
        guard let pulseUntil, pulseUntil > Date() else {
            return
        }

        let progress = 1.0 - min(max(pulseUntil.timeIntervalSinceNow / 0.35, 0), 1)
        let radius = (12 + (28 * progress)) * style.scale
        style.color.withAlphaComponent(0.45 * (1 - progress)).setStroke()
        let path = NSBezierPath(ovalIn: CGRect(
            x: pointerPosition.x - radius,
            y: pointerPosition.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        path.lineWidth = 3
        path.stroke()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else {
                return
            }
            self.setNeedsDisplay(self.dirtyRect(around: self.pointerPosition))
        }
    }

    // MARK: Arrow

    /// The arrow's tip always sits on `point`, in both shapes and at every size.
    private func drawArrow(at point: CGPoint, alpha: CGFloat, shadow: Bool = true) {
        PointerArt.draw(color: style.color, tip: point, scale: style.scale, mirrored: style.mirrored, alpha: alpha, shadow: shadow)
    }
}

/// The pointer drawing, shared by the overlay and the menu previews.
enum PointerArt {
    /// Outline of the macOS arrow with the tip at the origin, y pointing down.
    private static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.7, y: 12.9), CGPoint(x: 6.6, y: 19.5),
        CGPoint(x: 9.3, y: 18.3), CGPoint(x: 6.5, y: 11.9), CGPoint(x: 11.7, y: 11.9)
    ]

    static func path(tip: CGPoint, scale: CGFloat, mirrored: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, p) in outline.enumerated() {
            let point = CGPoint(x: tip.x + (mirrored ? -p.x : p.x) * scale, y: tip.y - p.y * scale)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// White edge on dark fills, black edge on light ones, so the arrow reads on any background.
    static func borderColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.62 ? .white : .black
    }

    static func draw(color: NSColor, tip: CGPoint, scale: CGFloat, mirrored: Bool, alpha: CGFloat = 1, shadow: Bool = true) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = path(tip: tip, scale: scale, mirrored: mirrored)
        let border = borderColor(for: color)

        context.saveGState()
        context.setAlpha(alpha)
        if shadow {
            context.setShadow(
                offset: CGSize(width: 1.5 * scale, height: -2.5 * scale),
                blur: 5 * scale,
                color: NSColor.black.withAlphaComponent(0.5).cgColor
            )
        }
        // One transparency layer so the shadow is cast once by the finished outline.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        border.setFill()
        border.setStroke()
        path.lineWidth = 3.6 * scale
        path.fill()
        path.stroke()
        color.setFill()
        path.fill()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Menu thumbnail of the pointer in a given colour and shape.
    static func preview(color: NSColor, mirrored: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 26, height: 30), flipped: false) { rect in
            draw(color: color, tip: CGPoint(x: mirrored ? rect.maxX - 6 : 6, y: rect.maxY - 4), scale: 1.05, mirrored: mirrored, shadow: true)
            return true
        }
    }
}
