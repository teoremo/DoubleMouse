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

struct HIDKeyboard {
    let id: UInt64
    let name: String
    let persistentKey: String
    let reference: IOHIDDevice
}

/// Takes exclusive ownership of one keyboard and replays its keystrokes into the app the
/// blue pointer last clicked, while the other keyboard keeps typing into the frontmost app.
final class KeyboardRouter {
    var onChange: (() -> Void)?

    /// App receiving the secondary keyboard. Set from blue-pointer clicks.
    private(set) var targetApp: NSRunningApplication?

    private var manager: IOHIDManager!
    private var keyboards: [UInt64: HIDKeyboard] = [:]
    private var selectedID: UInt64?
    private var seizedID: UInt64?
    private var flags = CGEventFlags()
    private var held = Set<Int>()
    private var repeatTimer: Timer?
    private let source = CGEventSource(stateID: .privateState)

    var allKeyboards: [HIDKeyboard] {
        keyboards.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedKeyboardID: UInt64? { selectedID }
    var isSeized: Bool { selectedID != nil && seizedID == selectedID }

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
    }

    func stop() {
        releaseAllKeys()
        for keyboard in keyboards.values {
            IOHIDDeviceClose(keyboard.reference, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedID = nil
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
        updateSeizure()
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
        updateSeizure()
        onChange?()
    }

    private func removed(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        keyboards.removeValue(forKey: id)
        if seizedID == id {
            releaseAllKeys()
            seizedID = nil
        }
        if selectedID == id { selectedID = nil }
        onChange?()
    }

    private func updateSeizure() {
        guard seizedID != selectedID else { return }

        if let seizedID, let old = keyboards[seizedID]?.reference {
            IOHIDDeviceClose(old, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDDeviceOpen(old, IOOptionBits(kIOHIDOptionsTypeNone))
            self.seizedID = nil
        }
        guard let selectedID, let device = keyboards[selectedID]?.reference else { return }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        debugLog("keyboard seize id=\(selectedID) result=\(String(format: "0x%08x", result))")
        if result == kIOReturnSuccess {
            seizedID = selectedID
        } else {
            IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }

        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(IOHIDElementGetDevice(element)), &id)
        guard id == selectedID, isSeized else { return }

        let usage = Int(IOHIDElementGetUsage(element))
        guard keyCodes[usage] != nil else { return }
        let isDown = IOHIDValueGetIntegerValue(value) != 0

        if isDown {
            guard held.insert(usage).inserted else { return }
            if let flag = modifierFlags[usage] { flags.insert(flag) }
            post(usage: usage, isDown: true)
            scheduleRepeat(for: usage)
        } else {
            guard held.remove(usage) != nil else { return }
            if let flag = modifierFlags[usage] { flags.remove(flag) }
            post(usage: usage, isDown: false)
            repeatTimer?.invalidate()
        }
    }

    private func post(usage: Int, isDown: Bool) {
        guard let code = keyCodes[usage], let app = targetApp, !app.isTerminated else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { return }
        event.flags = flags
        event.postToPid(app.processIdentifier)
    }

    // HID keyboards do not auto-repeat; macOS does that for the keyboards it owns.
    private func scheduleRepeat(for usage: Int) {
        repeatTimer?.invalidate()
        guard modifierFlags[usage] == nil else { return }
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
