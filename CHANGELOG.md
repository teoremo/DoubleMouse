# Changelog

## 1.3.1 - 2026-10-16

Fork changes.

- Fixed the blue pointer never moving on a Mac without Input Monitoring: the app now requests it at launch and offers a menu item when it is missing. Previously every device open failed with `kIOReturnNotPermitted`.
- Added a secondary keyboard that types into the app last clicked with the blue pointer, with a keyboard picker, modifiers, key repeat, and Command shortcuts performed through the target app's menu.
- Added pointer appearance settings: color presets and picker, shape, size, and a fading trail, with a contrasting border and a shadow.
- Added `Main Pointer Device`, `Swap Pointers` and slower speeds (0.1× to 0.4×).
- Blue and main clicks no longer interfere: blue presses are ignored while the main button is held, real main presses are swallowed during a blue drag, and the main cursor is restored reliably after quick blue clicks.
- Fixed the main pointer freezing for a quarter second after each cursor warp.
- Fixed the blue pointer freezing while a menu is open.
- Fixed the pointer stopping short on displays of different sizes: one overlay window per display, and the pointer stays on real screen area.
- Fixed duplicated input from one device matching several HID usages.
- Added `DOUBLEMOUSE_DEBUG=1` logging.
- Added hold-to-scroll for the blue pointer (hold the right button and move), because the Magic Mouse cannot scroll while captured.
- Added `Keep <App> Active While Typing` for apps that drop their focused field when deactivated: they come forward for second-keyboard typing, and the main keyboard is redirected to the main app meanwhile.
- A real click with the main mouse now cancels a pending focus handback and updates the remembered main app.
- Changed the bundle identifier to `com.teoremo.doublemouse`, so permissions are separate from the original app.

## 1.2.2 - 2026-07-29

- The published DMG is now signed with a Developer ID and notarized by Apple, so macOS no longer asks you to approve the first launch.
- Updating from an earlier version requires granting Accessibility, and Input Monitoring where it applies, one more time: the signature changed, so macOS treats this build as a different app and its old permissions do not carry over.
- Release builds now happen outside the working copy. iCloud Drive syncs Desktop and Documents, and its file provider was stamping attributes on the app bundle mid-build that made code signing fail at random.

## 1.2.1 - 2026-07-28

- Redrew the app icon: two translucent glass pointers overlapping on a light macOS tile, replacing the pair that faced away from each other.
- Added the vector sources for the icon, including a dark-appearance variant.

## 1.2.0 - 2026-07-28

- Added right-click and horizontal scrolling for the blue pointer.
- Added adjustable pointer speed and optional acceleration, so raw HID counts no longer map 1:1 to pixels.
- The selected blue device is now remembered between launches.
- Fixed the overlay not following display changes: connecting a monitor or changing resolution left the blue pointer unable to reach the new screen.
- Fixed the blue pointer being drawn at the wrong offset when a display sits left of or below the main one.
- Fixed reconnected devices inheriting the identity of an unplugged one, by keying devices on their IOService registry ID.
- Coalesced each HID report into a single movement, halving emitted drag events and redrawing only the area around the pointer instead of the whole desktop.
- Narrowed the Accessibility press path to button-like controls, so clicks on text fields, tables, and web content behave like real clicks.

## 1.1.1 - 2026-07-10

- Refreshed the app icon with inward-facing glass cursor arrows.
- Clarified the two-device requirement in the release materials.

## 1.1.0 - 2026-07-10

- Added true simultaneous movement for the system cursor and blue pointer.
- Captured only the selected secondary HID device, leaving the primary pointer native to macOS.
- Added independent blue-pointer clicks, scrolling, and drag-and-drop.
- Kept the system cursor in place while blue actions are emitted.
- Simplified the menu to blue-device selection and capture status.
- Added the DoubleMouse app icon and reproducible universal DMG packaging.
- Removed cursor-cancellation experiments, event counters, obsolete modes, and unused click suppression.

## 1.0.3 - 2026-05-31

- Removed the release-delay setting.
- The system cursor is released on the next main run-loop cycle after secondary mouse movement.

## 1.0.2 - 2026-05-31

- Tested a fixed 10 ms release delay.
- Removed the manual delay editor after runtime changes caused cursor jitter.

## 1.0.1 - 2026-05-31

- Reduced the default release delay from 50 ms to 25 ms.

## 1.0.0 - 2026-05-31

- First working prototype.
- Independent system cursor and blue secondary pointer.
- Secondary pointer clicks.
- Menu bar device assignment.
