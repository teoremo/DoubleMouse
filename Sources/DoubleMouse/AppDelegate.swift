import AppKit

private let sensitivityOptions: [Double] = [0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = PointerOverlayController()
    private let clickPerformer = ClickPerformer()
    private lazy var hidMonitor = HIDMouseMonitor(delegate: self)

    private let keyboardRouter = KeyboardRouter()
    private let mainButtonGuard = MainButtonGuard()
    private var blueIgnoringPress = false
    private var moveLogCount = 0
    private var appToRestore: NSRunningApplication?
    /// The app the main keyboard is typing into: the last app activated by anything other
    /// than a blue click.
    private var mainFocusApp = NSWorkspace.shared.frontmostApplication
    /// Activations before this time are blue-click side effects, not the user switching apps.
    private var blueFocusGuardUntil = Date.distantPast

    private var keepFocus = UserDefaults.standard.object(forKey: "keepFocus") as? Bool ?? false {
        didSet { UserDefaults.standard.set(keepFocus, forKey: "keepFocus") }
    }
    private var didShowAccessibilityWarning = false
    private var blueButtonIsDown = false
    private var blueDragStarted = false
    private var bluePressPosition = CGPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "DoubleMouse")

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, Date() >= self.blueFocusGuardUntil,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.mainFocusApp = app
        }

        overlay.show()
        hidMonitor.start()
        mainButtonGuard.start()
        clickPerformer.mainGuard = mainButtonGuard
        keyboardRouter.onChange = { [weak self] in self?.rebuildMenu() }
        keyboardRouter.start()
        showAccessibilityWarningIfNeeded()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: clickPerformer.currentCursor())
        }
        mainButtonGuard.blocksMainButtons = false
        keyboardRouter.stop()
        hidMonitor.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let main = NSMenuItem(title: "Main Pointer Device", action: nil, keyEquivalent: "")
        main.submenu = mainDeviceSubmenu()
        menu.addItem(main)

        let devices = NSMenuItem(title: "Blue Pointer Mouse", action: nil, keyEquivalent: "")
        devices.submenu = deviceSubmenu()
        menu.addItem(devices)

        let keyboard = NSMenuItem(title: "Secondary Keyboard", action: nil, keyEquivalent: "")
        keyboard.submenu = keyboardSubmenu()
        menu.addItem(keyboard)

        let appearance = NSMenuItem(title: "Pointer Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = appearanceSubmenu()
        menu.addItem(appearance)

        let swap = NSMenuItem(title: "Swap Pointers", action: #selector(swapPointers), keyEquivalent: "")
        swap.target = self
        swap.isEnabled = hidMonitor.allDevices.count == 2
        menu.addItem(swap)

        let assignBlue = NSMenuItem(title: "Set Blue Pointer From Next Movement", action: #selector(assignSecondaryFromNextMovement), keyEquivalent: "")
        assignBlue.target = self
        menu.addItem(assignBlue)

        if let assignmentPrompt = hidMonitor.assignmentPrompt {
            let prompt = NSMenuItem(title: assignmentPrompt, action: nil, keyEquivalent: "")
            prompt.isEnabled = false
            menu.addItem(prompt)
        }

        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedSubmenu()
        menu.addItem(speed)

        let accelerationItem = NSMenuItem(title: "Pointer Acceleration", action: #selector(toggleAcceleration), keyEquivalent: "")
        accelerationItem.target = self
        accelerationItem.state = overlay.acceleration ? .on : .off
        menu.addItem(accelerationItem)

        let focusItem = NSMenuItem(title: "Keep Keyboard Focus With Main Pointer", action: #selector(toggleKeepFocus), keyEquivalent: "")
        focusItem.target = self
        focusItem.state = keepFocus ? .on : .off
        menu.addItem(focusItem)

        menu.addItem(.separator())

        if keyboardRouter.selectedKeyboardID != nil {
            let typing = NSMenuItem(title: "Keyboard Types Into: \(keyboardRouter.targetApp?.localizedName ?? "click with the blue pointer first")", action: nil, keyEquivalent: "")
            typing.isEnabled = false
            menu.addItem(typing)
        }

        let secondary = hidMonitor.secondaryDeviceName ?? "not selected"
        let capture = hidMonitor.isSecondaryDeviceSeized ? "exclusive" : "shared"
        let summary = NSMenuItem(title: "Blue Pointer: \(secondary) [\(capture)]", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        if !hidMonitor.hasInputMonitoringAccess {
            let input = NSMenuItem(title: "Grant Input Monitoring Permission", action: #selector(requestInputMonitoringPermission), keyEquivalent: "")
            input.target = self
            menu.addItem(input)
        }

        if !AXIsProcessTrusted() {
            let permission = NSMenuItem(title: "Grant Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DoubleMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func deviceSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard !hidMonitor.allDevices.isEmpty else {
            let empty = NSMenuItem(title: "Move a mouse to detect devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        for device in hidMonitor.allDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectSecondaryDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == hidMonitor.selectedSecondaryDeviceID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func mainDeviceSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard !hidMonitor.allDevices.isEmpty else {
            let empty = NSMenuItem(title: "Move a mouse to detect devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        for device in hidMonitor.allDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMainDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == hidMonitor.mainDeviceID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let colorPresets: [(name: String, color: NSColor)] = [
        ("Ocean", rgb(0x1E88FF)), ("Coral", rgb(0xFF4D4F)), ("Emerald", rgb(0x1FBF75)), ("Amber", rgb(0xFFB300)),
        ("Violet", rgb(0x8E5CF6)), ("Hot Pink", rgb(0xFF3D9A)), ("Cyan", rgb(0x00C2D8)), ("Lime", rgb(0xA6E22E)),
        ("Black", rgb(0x000000)), ("White", rgb(0xFFFFFF))
    ]

    private func appearanceSubmenu() -> NSMenu {
        let menu = NSMenu()
        let style = overlay.style

        func parent(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            items.forEach(sub.addItem)
            item.submenu = sub
            menu.addItem(item)
        }

        func option(_ title: String, value: Any, selected: Bool, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = selected ? .on : .off
            return item
        }

        var colors = Self.colorPresets.map { preset -> NSMenuItem in
            let selected = Self.sameColor(style.color, preset.color)
            let item = option(preset.name, value: preset.color, selected: selected, action: #selector(selectPointerColor(_:)))
            item.image = PointerArt.preview(color: preset.color)
            return item
        }
        colors.append(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(chooseCustomColor), keyEquivalent: "")
        custom.target = self
        colors.append(custom)
        parent("Color", colors)

        parent("Shape", [
            option("Standard Arrow", value: false, selected: !style.mirrored, action: #selector(selectPointerShape(_:))),
            option("Mirrored Arrow", value: true, selected: style.mirrored, action: #selector(selectPointerShape(_:)))
        ].enumerated().map { index, item in
            item.image = PointerArt.preview(color: style.color, mirrored: index == 1)
            return item
        })

        parent("Size", [("Small", 0.75), ("Normal", 1.0), ("Large", 1.5), ("Extra Large", 2.0), ("Huge", 3.0)].map { name, scale in
            option(name, value: scale, selected: abs(Double(style.scale) - scale) < 0.001, action: #selector(selectPointerSize(_:)))
        })

        parent("Trail", [("Off", 0.0), ("Short", 0.25), ("Medium", 0.6), ("Long", 1.2)].map { name, seconds in
            option(name, value: seconds, selected: abs(style.trail - seconds) < 0.001, action: #selector(selectPointerTrail(_:)))
        })

        return menu
    }

    private static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        let difference = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        return difference < 0.01
    }

    @objc private func selectPointerColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        overlay.style.color = color
        rebuildMenu()
    }

    @objc private func chooseCustomColor() {
        let panel = NSColorPanel.shared
        panel.color = overlay.style.color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        overlay.style.color = sender.color
        rebuildMenu()
    }

    @objc private func selectPointerShape(_ sender: NSMenuItem) {
        guard let mirrored = sender.representedObject as? Bool else { return }
        overlay.style.mirrored = mirrored
        rebuildMenu()
    }

    @objc private func selectPointerSize(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        overlay.style.scale = CGFloat(scale)
        rebuildMenu()
    }

    @objc private func selectPointerTrail(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        overlay.style.trail = seconds
        rebuildMenu()
    }

    private func keyboardSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let none = NSMenuItem(title: "None", action: #selector(selectKeyboard(_:)), keyEquivalent: "")
        none.target = self
        none.state = keyboardRouter.selectedKeyboardID == nil ? .on : .off
        submenu.addItem(none)
        submenu.addItem(.separator())

        for keyboard in keyboardRouter.allKeyboards {
            let item = NSMenuItem(title: keyboard.name, action: #selector(selectKeyboard(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = keyboard.id
            item.state = keyboard.id == keyboardRouter.selectedKeyboardID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectKeyboard(_ sender: NSMenuItem) {
        keyboardRouter.select(id: sender.representedObject as? UInt64)
    }

    private func speedSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for value in sensitivityOptions {
            let item = NSMenuItem(title: String(format: "%g×", value), action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(overlay.sensitivity - value) < 0.001 ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectSecondaryDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt64 else {
            return
        }
        hidMonitor.setSecondaryDevice(id: id)
    }

    @objc private func selectMainDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt64 else {
            return
        }
        hidMonitor.setMainDevice(id: id)
    }

    @objc private func swapPointers() {
        hidMonitor.swapPointers()
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else {
            return
        }
        overlay.sensitivity = value
        rebuildMenu()
    }

    @objc private func toggleKeepFocus() {
        keepFocus.toggle()
        rebuildMenu()
    }

    /// A click activates the app under the blue pointer, which sends the keyboard there.
    /// Remember the app being typed into and bring it back once the click has landed.
    /// With a secondary keyboard the main keyboard must stay in its own app, so a blue click
    /// may not take focus no matter what the menu option says.
    private var shouldKeepFocus: Bool {
        keepFocus || keyboardRouter.selectedKeyboardID != nil
    }

    private func rememberFrontApp() {
        guard shouldKeepFocus, !isInMenuBar(overlay.secondaryPointerPosition) else {
            appToRestore = nil
            return
        }
        blueFocusGuardUntil = Date().addingTimeInterval(1.0)
        appToRestore = mainFocusApp
    }

    /// Menu bar clicks open menus, and re-activating another app would dismiss them.
    private func isInMenuBar(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return point.y >= screen.visibleFrame.maxY
    }

    private func restoreFrontApp() {
        guard let app = appToRestore else { return }
        blueFocusGuardUntil = Date().addingTimeInterval(1.0)
        appToRestore = nil

        // The target app activates asynchronously, so check twice before letting go.
        func restore(attempt: Int) {
            if !app.isTerminated, NSWorkspace.shared.frontmostApplication != app {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if result != .success {
                    app.activate()
                }
                debugLog("restore focus to \(app.localizedName ?? "?") attempt=\(attempt) result=\(result.rawValue)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { restore(attempt: 1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { restore(attempt: 2) }
    }

    @objc private func toggleAcceleration() {
        overlay.acceleration.toggle()
        rebuildMenu()
    }

    @objc private func assignSecondaryFromNextMovement() {
        hidMonitor.assignSecondaryDeviceFromNextMovement()
    }

    @objc private func requestInputMonitoringPermission() {
        if !hidMonitor.requestInputMonitoringAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func showAccessibilityWarningIfNeeded() {
        guard !AXIsProcessTrusted(), !didShowAccessibilityWarning else {
            return
        }

        didShowAccessibilityWarning = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "DoubleMouse Needs Accessibility Permission"
        alert.informativeText = "DoubleMouse needs this permission to press controls and emit clicks from the blue pointer. While running with swift run, macOS grants this permission to Terminal; packaged as an app, it will request permission as DoubleMouse."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibilityPermission()
        }
    }

}

extension AppDelegate: HIDMouseMonitorDelegate {
    func mouseMonitor(_ monitor: HIDMouseMonitor, didMoveSecondaryBy delta: CGPoint) {
        overlay.moveSecondaryBy(delta)
        moveLogCount += 1
        if moveLogCount % 15 == 0 {
            debugLog("move delta=\(delta) pos=\(overlay.secondaryPointerPosition) down=\(blueButtonIsDown) drag=\(blueDragStarted) ignoring=\(blueIgnoringPress)")
        }

        guard blueButtonIsDown, !blueIgnoringPress else {
            return
        }

        let point = overlay.secondaryPointerPosition
        if !blueDragStarted, !blueIgnoringPress,
           hypot(point.x - bluePressPosition.x, point.y - bluePressPosition.y) >= 3 {
            blueDragStarted = true
            mainButtonGuard.blocksMainButtons = true
            clickPerformer.beginDrag(at: bluePressPosition, returningTo: clickPerformer.currentCursor())
        }
        if blueDragStarted {
            clickPerformer.drag(to: point, returningTo: clickPerformer.currentCursor())
        }
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didScrollSecondaryBy delta: CGPoint) {
        clickPerformer.scroll(at: overlay.secondaryPointerPosition, delta: delta)
    }

    func mouseMonitor(_ monitor: HIDMouseMonitor, didChangeSecondaryButton button: MouseButton, isPressed: Bool) {
        guard button == .left else {
            // Right button: no drag, macOS has no second button state to spare anyway.
            if !isPressed, !mainButtonGuard.isMainButtonDown, !blueDragStarted {
                rememberFrontApp()
                defer { restoreFrontApp() }
                clickPerformer.performRightClick(at: overlay.secondaryPointerPosition, returningTo: clickPerformer.currentCursor())
                overlay.pulseSecondary()
            }
            return
        }

        debugLog("blue button \(button) pressed=\(isPressed) pos=\(overlay.secondaryPointerPosition) mainDown=\(mainButtonGuard.isMainButtonDown) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        guard isPressed != blueButtonIsDown else {
            return
        }

        blueButtonIsDown = isPressed
        if isPressed {
            blueDragStarted = false
            // A blue press while the main button is held would join the main click or drag.
            blueIgnoringPress = mainButtonGuard.isMainButtonDown
            rememberFrontApp()
            keyboardRouter.setTarget(atQuartzPoint: clickPerformer.quartzPoint(fromAppKitPoint: overlay.secondaryPointerPosition))
            bluePressPosition = overlay.secondaryPointerPosition
            return
        }

        if blueIgnoringPress || (!blueDragStarted && mainButtonGuard.isMainButtonDown) {
            blueIgnoringPress = false
            blueDragStarted = false
            restoreFrontApp()
            return
        }

        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: clickPerformer.currentCursor())
            mainButtonGuard.blocksMainButtons = false
        } else {
            clickPerformer.performClick(at: overlay.secondaryPointerPosition, returningTo: clickPerformer.currentCursor())
        }
        blueDragStarted = false
        overlay.pulseSecondary()
        restoreFrontApp()
    }

    func mouseMonitorDevicesChanged(_ monitor: HIDMouseMonitor) {
        rebuildMenu()
    }
}
