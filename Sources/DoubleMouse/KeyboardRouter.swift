import AppKit
import IOKit.hid

private let keyboardDefaultsKey = "secondaryKeyboardKey"

/// HID keyboard usage (page 0x07) to macOS virtual key code, ANSI/ISO.
private let keyCodes: [Int: CGKeyCode] = {
    var map: [Int: CGKeyCode] = [:]
    let letters: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    for (i, code) in letters.enumerated() { map[0x04 + i] = code }
    let digits: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    for (i, code) in digits.enumerated() { map[0x1E + i] = code }
    let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    for (i, code) in fkeys.enumerated() { map[0x3A + i] = code }
    let keypad: [CGKeyCode] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]
    for (i, code) in keypad.enumerated() { map[0x59 + i] = code }
    let others: [Int: CGKeyCode] = [
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33,
        0x30: 30, 0x31: 42, 0x32: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47,
        0x38: 44, 0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126, 0x53: 71, 0x54: 75, 0x55: 67,
        0x56: 78, 0x57: 69, 0x58: 76, 0x63: 65, 0x64: 10,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54
    ]
    return map.merging(others) { $1 }
}()

private let modifierFlags: [Int: CGEventFlags] = [
    0xE0: .maskControl, 0xE4: .maskControl,
    0xE1: .maskShift, 0xE5: .maskShift,
    0xE2: .maskAlternate, 0xE6: .maskAlternate,
    0xE3: .maskCommand, 0xE7: .maskCommand
]

/// Character a menu item shows for its Command shortcut, for the keys worth matching.
private func menuCharacter(forUsage usage: Int) -> String? {
    switch usage {
    case 0x04...0x1D: return String(UnicodeScalar(UInt8(65 + usage - 0x04)))
    case 0x1E...0x26: return String(usage - 0x1E + 1)
    case 0x27: return "0"
    case 0x2D: return "-"
    case 0x2E: return "="
    case 0x2F: return "["
    case 0x30: return "]"
    case 0x31: return "\\"
    case 0x33: return ";"
    case 0x34: return "'"
    case 0x35: return "`"
    case 0x36: return ","
    case 0x37: return "."
    case 0x38: return "/"
    default: return nil
    }
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

/// Menu key equivalents only fire in the frontmost app, so a Command shortcut aimed at a
/// background app is performed by pressing the matching menu item through Accessibility.
private func pressMenuItem(pid: pid_t, character: String, modifiers: Int) -> Bool {
    guard AXIsProcessTrusted(),
          let bar = axValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as String) else {
        return false
    }

    func search(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 7,
              let children = axValue(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return false
        }
        for child in children {
            if (axValue(child, kAXRoleAttribute as String) as? String) == kAXMenuItemRole as String,
               let char = axValue(child, kAXMenuItemCmdCharAttribute as String) as? String,
               char.uppercased() == character,
               (axValue(child, kAXMenuItemCmdModifiersAttribute as String) as? Int ?? 0) == modifiers,
               (axValue(child, kAXEnabledAttribute as String) as? Bool) != false {
                return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
            }
            if search(child, depth: depth + 1) { return true }
        }
        return false
    }
    return search(bar as! AXUIElement, depth: 0)
}

struct HIDKeyboard {
    let id: UInt64
    let name: String
    let persistentKey: String
    let reference: IOHIDDevice
}

/// Replays one keyboard's keystrokes into the app the blue pointer last clicked, while the
/// other keyboard keeps typing into the frontmost app.
///
/// macOS only lets root seize a keyboard (IOHIDDeviceOpen fails with kIOReturnNotPrivileged),
/// so the keyboard still reaches the system. Instead, every key the HID layer reports from
/// the selected keyboard is remembered, and an event tap drops the matching system event.
final class KeyboardRouter {
    var onChange: (() -> Void)?
    /// Called for each key press sent to the target app.
    var onKeyTyped: (() -> Void)?

    /// App receiving the secondary keyboard. Set from blue-pointer clicks.
    private(set) var targetApp: NSRunningApplication?

    private var manager: IOHIDManager!
    private var keyboards: [UInt64: HIDKeyboard] = [:]
    private var selectedID: UInt64?
    private var tap: CFMachPort?
    private var pendingDown: [CGKeyCode: Date] = [:]
    private var pendingUp: [CGKeyCode: Date] = [:]
    private let suppressWindow: TimeInterval = 0.25
    private var flags = CGEventFlags()
    private var held = Set<Int>()
    private var repeatTimer: Timer?
    private let source = CGEventSource(stateID: .privateState)

    var allKeyboards: [HIDKeyboard] {
        keyboards.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedKeyboardID: UInt64? { selectedID }

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0x8))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<KeyboardRouter>.fromOpaque(context!).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<KeyboardRouter>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        startSuppressionTap()
    }

    private func startSuppressionTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let router = Unmanaged<KeyboardRouter>.fromOpaque(context).takeUnretainedValue()
                return router.filter(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: context
        ) else {
            debugLog("keyboard tap unavailable (needs Accessibility)")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    }

    /// Returns false to drop a system event that came from the secondary keyboard.
    private func filter(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard selectedID != nil,
              event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else {
            return true
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let now = Date()
        let isHeld = held.contains { keyCodes[$0] == code }

        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return !isHeld
            }
            if let expiry = pendingDown[code], expiry > now {
                pendingDown[code] = nil
                return false
            }
        case .keyUp:
            if let expiry = pendingUp[code], expiry > now {
                pendingUp[code] = nil
                return false
            }
        default: // flagsChanged: modifiers report press and release the same way.
            if let expiry = pendingDown[code], expiry > now {
                pendingDown[code] = nil
                return false
            }
            if let expiry = pendingUp[code], expiry > now {
                pendingUp[code] = nil
                return false
            }
        }
        return true
    }

    func stop() {
        releaseAllKeys()
        for keyboard in keyboards.values {
            IOHIDDeviceClose(keyboard.reference, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// nil stops routing and gives the keyboard back to macOS.
    func select(id: UInt64?) {
        releaseAllKeys()
        selectedID = id
        if let id, let keyboard = keyboards[id] {
            UserDefaults.standard.set(keyboard.persistentKey, forKey: keyboardDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: keyboardDefaultsKey)
        }
        onChange?()
    }

    /// The window under the point decides which app receives the secondary keyboard.
    func setTarget(atQuartzPoint point: CGPoint) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point) else {
                continue
            }
            if targetApp?.processIdentifier != pid {
                releaseAllKeys()
                targetApp = NSRunningApplication(processIdentifier: pid)
                debugLog("keyboard target: \(targetApp?.localizedName ?? "?")")
                onChange?()
            }
            return
        }
    }

    private func added(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        guard keyboards[id] == nil else { return }

        let number = { (key: String) -> Int in
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        let key = "\(number(kIOHIDVendorIDKey)):\(number(kIOHIDProductIDKey)):\(number(kIOHIDLocationIDKey))"
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keyboard"
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        keyboards[id] = HIDKeyboard(id: id, name: transport.map { "\(product) (\($0))" } ?? product, persistentKey: key, reference: device)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            Unmanaged<KeyboardRouter>.fromOpaque(context!).takeUnretainedValue().input(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        debugLog("keyboard added id=\(id) \(keyboards[id]!.name) key=\(key)")

        if key == UserDefaults.standard.string(forKey: keyboardDefaultsKey) {
            selectedID = id
        }
        onChange?()
    }

    private func removed(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        keyboards.removeValue(forKey: id)
        if selectedID == id {
            releaseAllKeys()
            selectedID = nil
        }
        onChange?()
    }

    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }

        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(IOHIDElementGetDevice(element)), &id)
        guard id == selectedID else { return }

        let usage = Int(IOHIDElementGetUsage(element))
        guard keyCodes[usage] != nil else { return }
        let isDown = IOHIDValueGetIntegerValue(value) != 0
        let expiry = Date().addingTimeInterval(suppressWindow)

        if isDown {
            onKeyTyped?()
            guard held.insert(usage).inserted else { return }
            pendingDown[keyCodes[usage]!] = expiry
            if let flag = modifierFlags[usage] { flags.insert(flag) }
            post(usage: usage, isDown: true)
            scheduleRepeat(for: usage)
        } else {
            guard held.remove(usage) != nil else { return }
            pendingUp[keyCodes[usage]!] = expiry
            if let flag = modifierFlags[usage] { flags.remove(flag) }
            post(usage: usage, isDown: false)
            repeatTimer?.invalidate()
        }
    }

    private var menuHandled = Set<Int>()

    private func post(usage: Int, isDown: Bool) {
        guard let code = keyCodes[usage], let app = targetApp, !app.isTerminated else { return }

        if modifierFlags[usage] == nil {
            if isDown, flags.contains(.maskCommand), let character = menuCharacter(forUsage: usage) {
                var modifiers = 0
                if flags.contains(.maskShift) { modifiers |= 1 }
                if flags.contains(.maskAlternate) { modifiers |= 2 }
                if flags.contains(.maskControl) { modifiers |= 4 }
                if pressMenuItem(pid: app.processIdentifier, character: character, modifiers: modifiers) {
                    debugLog("menu shortcut \(character) mods=\(modifiers) -> \(app.localizedName ?? "?")")
                    menuHandled.insert(usage)
                    return
                }
            } else if !isDown, menuHandled.remove(usage) != nil {
                return
            }
        }

        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.postToPid(app.processIdentifier)
    }

    // HID keyboards do not auto-repeat; macOS does that for the keyboards it owns.
    private func scheduleRepeat(for usage: Int) {
        repeatTimer?.invalidate()
        guard modifierFlags[usage] == nil, !flags.contains(.maskCommand) else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, self.held.contains(usage) else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
                guard let self, self.held.contains(usage) else {
                    timer.invalidate()
                    return
                }
                self.post(usage: usage, isDown: true)
            }
        }
    }

    private func releaseAllKeys() {
        repeatTimer?.invalidate()
        for usage in held {
            post(usage: usage, isDown: false)
        }
        held.removeAll()
        flags = CGEventFlags()
    }
}
