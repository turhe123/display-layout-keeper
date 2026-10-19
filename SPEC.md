# DisplayLayoutKeeper — specification

**Tagline:** Remembers where your windows sit for each monitor setup and restores them when displays change.

**Category:** Window Management

**Inspired by (paid):** Stay ($15 one-time)

**Frameworks:** SwiftUI, AppKit, ApplicationServices, CoreGraphics, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

(1) What the paid app does. Stay is a long-running menu bar utility priced at 15 dollars with a trial. It saves window positions per display configuration and puts windows back when you plug in or unplug a monitor, a pain point every laptop user with a dock knows because macOS scrambles windows after sleep or reconnect. Reviews at Macworld and MacStories covered it and it remains a go-to recommendation for the problem, which shows durable demand. Our version delivers the core: capture, auto-restore, and manual restore keyed by the current monitor arrangement.

(2) Feature set. The app computes a display signature from the connected displays, built from each display's unique identifier, its pixel size and its origin in the global arrangement. For each signature it stores a snapshot of all visible, normal-layer windows: owning app bundle identifier, window title, and frame. Snapshots are saved automatically on a timer, default every 60 seconds, but only while the signature is stable for at least five seconds, and also just before sleep. When the display configuration changes and a snapshot exists for the new signature, the app waits a configurable delay, default three seconds, then restores windows by matching bundle identifier plus title, falling back to bundle identifier plus window index. A Save Now item and a Restore Now item exist for manual control. Per-app exclusion list is supported.

(3) UI spec. MenuBarExtra with a monitor icon. The menu shows the current configuration name such as Laptop plus 1 external, the time of the last snapshot, Save Now, Restore Now, a submenu listing known configurations with a delete action, Settings and Quit. Settings fields: auto-save interval stepper, restore delay stepper, auto-restore toggle, launch at login toggle, excluded apps list with add and remove buttons using an open panel on the Applications folder. Empty state: when no snapshot exists for the current setup, the menu says No saved layout yet and Restore Now is disabled. A short notification confirms an automatic restore.

(4) Technical approach. Observe NSApplication didChangeScreenParametersNotification and also register a CGDisplayRegisterReconfigurationCallback for finer events. Display identity comes from CGDisplayCreateUUIDFromDisplayID so that it survives port changes. Enumerate windows with CGWindowListCopyWindowInfo to get owner pid, layer, bounds and name, then perform restores through AXUIElement by walking each application's window list and setting position and size. Requires Accessibility permission, requested with AXIsProcessTrustedWithOptions. Window titles from CGWindowList need Screen Recording permission on recent macOS, so prefer reading AXTitle through Accessibility for each window instead, which avoids that prompt entirely. Persist snapshots as JSON files in Application Support under the app folder, one per signature. Use UserNotifications for the confirmation, requested lazily. Launch at login uses SMAppService.

(5) Edge cases. Minimized and other-Space windows are not reachable via Accessibility, so skip them silently and note this limitation in Settings help text. Titles that change, such as browser tabs, fall back to index matching. Never move a window to a frame that lies fully off all current displays, clamp into the nearest display. Avoid restoring during the first seconds after wake until displays settle. Cap stored snapshots at twenty configurations and drop the oldest. If Accessibility trust is revoked at runtime, disable restore and show a warning row in the menu.
