import AppKit

private let sensitivityOptions: [Double] = [0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0, 1.5, 2.0]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = PointerOverlayController()
    private let clickPerformer = ClickPerformer()
    private lazy var hidMonitor = HIDMouseMonitor(delegate: self)

    private let mainButtonGuard = MainButtonGuard()
    private var blueIgnoringPress = false
    private var moveLogCount = 0
    private var appToRestore: NSRunningApplication?

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

        overlay.show()
        hidMonitor.start()
        mainButtonGuard.start()
        showAccessibilityWarningIfNeeded()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if blueDragStarted {
            clickPerformer.endDrag(at: overlay.secondaryPointerPosition, returningTo: clickPerformer.currentCursor())
        }
        mainButtonGuard.blocksMainButtons = false
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
    private func rememberFrontApp() {
        guard keepFocus, !isInMenuBar(overlay.secondaryPointerPosition) else {
            appToRestore = nil
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        appToRestore = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    /// Menu bar clicks open menus, and re-activating another app would dismiss them.
    private func isInMenuBar(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return point.y >= screen.visibleFrame.maxY
    }

    private func restoreFrontApp() {
        guard keepFocus, let app = appToRestore else { return }
        appToRestore = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication != app, !app.isTerminated else { return }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            debugLog("restore focus to \(app.localizedName ?? "?") result=\(result.rawValue)")
        }
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
            bluePressPosition = overlay.secondaryPointerPosition
            return
        }

        if blueIgnoringPress || (!blueDragStarted && mainButtonGuard.isMainButtonDown) {
            blueIgnoringPress = false
            blueDragStarted = false
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
