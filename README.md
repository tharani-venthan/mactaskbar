# MacTaskbar — Windows 11-style Taskbar for macOS

A macOS taskbar app that mimics Windows 11 taskbar behavior exactly.

## Download

**[Download the latest DMG](https://github.com/tharani-venthan/mactaskbar/releases/latest)** (macOS 13+, Apple Silicon and Intel).

Open the DMG and drag MacTaskbar into Applications. The app isn't notarised yet, so the first time right-click it → **Open** → **Open** (or System Settings → Privacy & Security → **Open Anyway**).

## How it Behaves (Exactly Like Windows 11)

**Pinned apps:**
- Pinned apps NEVER MOVE. They stay in their fixed position always.
- If a pinned app is running, its icon shows in the same pinned slot with a dot below it.
- If a pinned app is not running, clicking it launches it.
- The pinned slot order never changes — opening/closing apps doesn't shift positions.

**Running (unpinned) apps:**
- Apps that are running but NOT pinned appear to the RIGHT of all pinned slots.
- They appear in the order they were launched.
- When they quit, they disappear from the taskbar entirely.

**Click behavior:**
- Click a pinned (not running) icon → launches the app
- Click a running app (not active) → activates/brings to front
- Click the active app (single window) → hides it (toggle)
- Click the active app (multiple windows) → shows thumbnail preview
- Hover for 400ms → shows window thumbnail preview panel

## Setup Instructions

### Requirements
- macOS 13.0+
- Xcode 15+
- Apple Developer account (for signing)

### Build Steps

1. **Open in Xcode:**
   ```
   open MacTaskbar.xcodeproj
   ```

2. **Set your Team:**
   - Select the `MacTaskbar` target
   - Under Signing & Capabilities → set your Team
   - Bundle ID: `com.mactaskbar.app` (or change to your preference)

3. **Disable App Sandbox:**
   - The entitlements file already has sandbox disabled
   - This is required for `CGWindowListCopyWindowInfo`, AX APIs, and screen capture

4. **Build & Run** (⌘R)

### First Launch Permissions

On first launch, macOS will ask for:

1. **Screen Recording** — needed to show window thumbnails in hover previews
   - System Settings → Privacy & Security → Screen Recording → Enable MacTaskbar

2. **Accessibility** — needed to raise specific windows and close them
   - System Settings → Privacy & Security → Accessibility → Enable MacTaskbar

The app works without both (degraded — no thumbnails, no specific window raising), but is best with both.

### Customization

Right-click on the taskbar background → **Taskbar Settings**:
- Icon Size: Small (32pt) / Medium (44pt, default) / Large (56pt)
- Icon Position: Left / Center (default, like Win11)
- Auto-hide: slides bar off screen when not in use
- Show app labels: shows app name below icon

### Pinning Apps

**Pin:** Right-click any running app icon → "Pin to taskbar"
**Unpin:** Right-click any pinned icon → "Unpin from taskbar"
**Launch pinned:** Click the icon (even if not running)

Default pins: Finder, Safari, Mail, Notes, System Settings

## Architecture Notes

The key design that makes this work like Windows 11:

```
WindowManager.rebuildTaskbarItems():
  1. Loop through pinnedBundleIDs IN ORDER
     → If running: .running(group, pinned: true)  -- uses the pinned slot
     → If not running: .pinnedOnly(bundleID)        -- shows just the icon
  2. Append unpinned running apps IN LAUNCH ORDER
     → .running(group, pinned: false)
```

This means pinned slots NEVER SHIFT. The array index of a pinned app never changes regardless of what else is running.

## File Structure

```
MacTaskbar/
├── MacTaskbarApp.swift          — @main entry, AppDelegate
├── Core/
│   ├── WindowManager.swift      — Window polling + taskbar item ordering
│   ├── ThumbnailService.swift   — CGWindowListCreateImage captures
│   ├── FocusManager.swift       — AX window raise + close
│   ├── AppLaunchTracker.swift   — Recent apps tracking
│   └── PermissionsManager.swift — Screen recording + accessibility
├── Settings/
│   └── TaskbarSettings.swift    — @AppStorage settings + pinned app management
├── UI/
│   ├── TaskbarWindowController.swift  — NSPanel at screen bottom
│   ├── TaskbarView.swift              — Root: Start + Icons + Tray
│   ├── AppIconView.swift              — Icon with hover, dots, active line
│   ├── HoverPreviewPanel.swift        — Floating thumbnail panel
│   ├── ThumbnailCard.swift            — Individual window preview
│   ├── StartMenuPanel.swift           — Start menu NSPanel controller
│   ├── StartMenuView.swift            — Search + pinned grid + recents
│   ├── AllAppsView.swift              — Alphabetical app list
│   ├── SystemTrayView.swift           — Clock + Wi-Fi/volume/battery icons
│   └── SettingsPanel.swift            — Settings UI panel
└── Resources/
    └── WindowsLogo.swift              — 4-square Windows logo in SwiftUI
```
