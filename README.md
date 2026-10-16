# DoubleMouse

<p align="center">
  <img src="Assets/DoubleMouse.png" alt="DoubleMouse icon" width="180">
</p>

> This is a personal fork of [franciscoxc/DoubleMouse](https://github.com/franciscoxc/DoubleMouse) with a fix for the blue pointer never moving, a second keyboard, and a customisable pointer. See the [changelog](CHANGELOG.md) for what differs.

Ever wondered how to be faster on your Mac? What if you had two physical mice, each with its own pointer?

**DoubleMouse** is an open-source macOS menu bar app for two pointing devices: two physical mice, or your MacBook's built-in trackpad plus one external mouse. Both pointers move simultaneously, and each can click, scroll, and drag. It is also handy in classrooms and support sessions, where teacher and student can each keep a hand on the computer without negotiating custody of the cursor.

## Download

Build the DMG yourself (see [Build The DMG](#build-the-dmg)); this fork publishes no binaries. The original project's signed and notarized builds are on [its releases page](https://github.com/franciscoxc/DoubleMouse/releases).

The app requires two pointing devices: two physical mice, or the built-in MacBook trackpad plus one external mouse. It supports Apple Silicon and Intel Macs running macOS 13 or later.

## Install

1. Open the DMG and drag DoubleMouse to Applications. Quit any other copy of DoubleMouse first.
2. Launch DoubleMouse. A build you made yourself is not notarized, so macOS may ask you to approve the first launch: right-click the app and choose Open.
3. Grant **both** permissions under System Settings > Privacy & Security:
   - **Input Monitoring**, which lets the app read the second device. Without it the blue pointer never moves.
   - **Accessibility**, which lets the app click, press controls, and filter the second keyboard.
4. Pick the blue device from the menu bar if it guessed wrong: `Blue Pointer Mouse`, `Main Pointer Device`, `Swap Pointers`, or `Set Blue Pointer From Next Movement`.

The permissions belong to the signature of the app. If you rebuild with a different signing identity, grant them again.

## Features

- Truly simultaneous movement of the normal macOS cursor and the blue pointer.
- Independent left and right clicks for both physical devices.
- Vertical and horizontal scrolling at the blue pointer location.
- Drag-and-drop with either pointer.
- Adjustable blue pointer speed and optional acceleration, so a high-DPI mouse can be matched to the system cursor.
- The chosen blue device is remembered between launches.
- External USB and Bluetooth mouse support.
- MacBook trackpad plus external mouse support when macOS exposes both HID devices.
- Compact menu bar device selection, from either side: choose the blue device, the main device, or swap them.
- A **secondary keyboard**: pick a second keyboard and its keystrokes go to the app you last clicked with the blue pointer, while the other keyboard keeps typing into the frontmost app.
- **Pointer appearance**: color presets plus a color picker, standard or mirrored arrow, five sizes, and a fading trail. The arrow has a contrasting border and a shadow, white on dark colors and black on light ones.
- Clicks on one pointer do not disturb the other: a blue click is ignored while the main button is held, and the main cursor is put back where it was.
- **Hold-to-scroll**: hold the blue device's right button and move to scroll, which is the only way to scroll with a Magic Mouse (its touch surface cannot be read while the device is captured). A quick right-click still opens the context menu.
- Slow speeds down to 0.1×, for large displays.
- Works across displays of different sizes and layouts.
- No analytics, accounts, network access, or kernel extension.

## How It Works

DoubleMouse opens HID devices independently and takes exclusive user-space ownership of the selected blue-pointer device. macOS continues to own the normal cursor, while DoubleMouse draws the blue pointer and emits its actions at the correct screen coordinates.

For the second keyboard, macOS only lets root capture a keyboard exclusively. DoubleMouse instead listens to the selected keyboard over HID, drops the matching system keystroke with an event tap, and sends the keystroke straight to the target app's process. Command shortcuts such as copy and paste are performed through the target app's menu, because menu shortcuts only fire in the frontmost app.

The implementation uses public AppKit, IOKit, Accessibility, and CoreGraphics APIs. It does not install a driver or system extension.

## Limitations

- macOS still has one global mouse-button state, so two simultaneous drag operations are not supported.
- The blue pointer does not trigger hover: buttons do not highlight under it, tooltips do not appear, and submenus do not open. macOS keeps a single cursor position, so putting the real cursor on the blue pointer and bringing it back on every movement would leave the real one jittering constantly. Clicking, scrolling, and dragging are unaffected.
- The second keyboard targets an app, not a window, so two windows of one app cannot be split. Some apps ignore keystrokes while inactive, and keys macOS handles globally (Cmd+Tab, Spotlight, brightness and volume) are not routed. Pressing the same key on both keyboards within about a quarter of a second can drop one press.
- With a secondary keyboard selected, a blue click hands focus straight back to the app the main keyboard is using. To type into the app you clicked, use the secondary keyboard.
- Some apps (WhatsApp and Todoist among them) lose their focused text field as soon as they are deactivated, so the second keyboard cannot type into them from the background. Mark them with `Keep <App> Active While Typing`: they are brought forward whenever you type on the second keyboard, and focus returns to your main app after 2 seconds without second-keyboard typing. While one is in front, the main keyboard's keystrokes are redirected to your main app, so both keyboards can type at once.
- Some games, remote desktops, canvases, or custom controls may reject synthetic pointer events.
- The blue device is remembered by USB/Bluetooth port, so moving a mouse to a different port clears the selection.

## Run From Source

```sh
swift run DoubleMouse
```

The pointer scaling curve has a self-check:

```sh
swift run DoubleMouse --selftest
```

When running from Terminal, macOS assigns the relevant privacy permissions to Terminal. The packaged app requests them as DoubleMouse.

Set `DOUBLEMOUSE_DEBUG=1` to log the detected devices, whether each could be opened, per-device report rates and input events to stderr. A device that fails to open with `0xe00002e2` is missing Input Monitoring.

## Build The DMG

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/package-release.sh 1.3.0
```

The script uses only native macOS tools and writes the DMG plus SHA-256 checksum to `dist/`. Without arguments it signs ad hoc, which needs no certificate but leaves the first launch behind a Gatekeeper warning and makes macOS ask for the permissions again after every rebuild. Setting `CODESIGN_IDENTITY` to an Apple Development certificate (`security find-identity -v -p codesigning`) keeps a stable signature.

## Notarize The DMG

Notarization removes that warning. It needs a Developer ID Application certificate, which is not the same as the Apple Development certificate Xcode creates for local builds, and a stored notarytool credential profile:

```sh
xcrun notarytool store-credentials doublemouse --apple-id <apple-id> --team-id <team-id>
```

That command prompts for an app-specific password, generated at appleid.apple.com, and keeps it in the login keychain. Then build with both variables set:

```sh
CODESIGN_IDENTITY="Developer ID Application: <name> (<team-id>)" \
NOTARY_PROFILE=doublemouse \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
scripts/package-release.sh <version>
```

The script then signs with the hardened runtime, submits the disk image, waits for the result, staples the ticket, and verifies the image the way Gatekeeper does. The checksum is written after stapling, since stapling rewrites the disk image.

Signing says nothing about the source, which stays MIT and complete: it only certifies who built one particular binary. A build you make yourself is ad-hoc signed and not notarized, so macOS will ask you to approve its first launch even though the published DMG opens without a prompt. That difference is expected. The signing key belongs to the maintainer and cannot be reproduced from this repository, which is the point of it.

## Contributing

Issues and pull requests are welcome. Include your macOS version, Mac model, pointing-device models, connection types, and whether the problem affects movement, clicks, scroll, or dragging.

## License

MIT. See [LICENSE](LICENSE).
