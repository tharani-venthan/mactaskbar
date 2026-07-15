# MacTaskbar — Development Log

A record of where this project started, every problem we hit, and how each one was fixed.
(The app itself and its intended behavior are described in [README.md](README.md).)

---

## Where we started

The project began as a working prototype of a Windows 11-style taskbar for macOS
(SwiftUI + AppKit, `LSUIElement` agent app, always-on-top `NSPanel` at the bottom
of the screen). The basics worked — taskbar rendering, pinned apps, hover
previews with window thumbnails, start menu — but several core interactions
were broken:

1. Clicking a window thumbnail in the hover preview always raised the app's
   **first** window, never the one clicked.
2. The close / minimize / maximize buttons on preview cards did nothing.
3. Drag-to-reorder taskbar icons did not work at all.
4. Closed windows kept showing in the window count.
5. Permissions (Accessibility, Screen Recording) were re-requested on **every
   launch**, even when already granted.

The project also lived through an early process mistake: each iteration was
saved as a copied folder (`V1.0`, `V1.2` … `V1.5`) instead of using version
control, which eventually caused path confusion.

---

## Fixes and features, in order

### 1. Window switching (the hardest bug)
**Symptom:** clicking any thumbnail raised the same (frontmost) window.

**Failed attempts, kept for the record:**
- Reordering the CG→AX window matching heuristics (bounds → title → z-order).
- Fixing a real coordinate-system bug in the bounds matcher (AX positions are
  already top-left-origin like CGWindowList; the code was double-flipping Y).

**Actual fix (`Core/FocusManager.swift`):** use the private
`_AXUIElementGetWindow` API to get the **exact CGWindowID** for each
`AXUIElement` — the same technique AltTab and yabai use. No more guessing.
All window operations (raise, close, minimize, maximize, restore) resolve
through one `resolveAXWindow` helper with heuristics kept only as fallback.

**Final root cause discovery:** even correct code failed because Accessibility
permission never actually stuck (see §6). Both had to be fixed.

### 2. Preview card buttons
**Symptom:** traffic-light buttons (close/minimize/maximize) on thumbnails dead;
only "Quit" worked.
**Fix (`UI/HoverPreviewPanel.swift`):** the whole card had an `onTapGesture`
that swallowed clicks before they reached the buttons. Scoped the tap gesture
to the thumbnail layer only.

### 3. Drag-to-reorder icons
**Symptom:** click-hold-drag did nothing.

**Failed attempts, kept for the record:**
- `mouseDown`/`mouseDragged` overrides on the container NSView — never fired,
  child `NSHostingView`s win hit-testing.
- `NSPanGestureRecognizer` on each hosting view — lost the race to SwiftUI's
  internal gesture handling.
- SwiftUI `.onDrag`/`.onDrop` — **never starts inside a
  `.nonactivatingPanel`**; the window can't become a drag source.
- Overriding `hitTest` to claim all events — dragging worked but killed
  SwiftUI `.onHover` and `.contextMenu` (hover previews and right-click broke).

**Actual fix (`UI/TaskbarView.swift`):** a **local NSEvent monitor**
(`NSEvent.addLocalMonitorForEvents`) that sees mouse events first, claims
press-and-move as a drag, and lets plain clicks fall through to SwiftUI.
Reordering works for **pinned and unpinned** icons (within each group —
pinned slots always precede running apps). Pinned order persists; unpinned
order lasts until the app quits.

### 4. Hover behavior (Windows 11 style)
- Running app → window preview appears near-instantly (0.1 s).
- Not-running app → small dark tooltip "toast" with the app name after ~0.8 s
  (`IconTooltipPanel` in `UI/AppIconView.swift`).
- Removed the permanent "Show app labels" setting in favor of the tooltip.

### 5. Minimized windows + preview grid
- `WindowInfo` gained `isMinimized`. `WindowManager` now does **two-pass
  discovery**: CGWindowList for on-screen windows, then the app's AX window
  list filtered on `kAXMinimizedAttribute` (with real CGWindowIDs via
  `_AXUIElementGetWindow`). Minimized windows no longer vanish from counts
  and previews.
- Preview cards for minimized windows show the last cached thumbnail (dimmed)
  or the app icon, with a **Restore** button; any focus action un-minimizes
  first.
- Preview panel layout changed from a horizontal scroll row to a wrapping
  `LazyVGrid` (up to 3 columns).

### 6. Permissions — the systemic fix
**Symptom:** permissions re-requested every launch; System Settings showed
them ON but they didn't work. This also silently broke window switching
(no Accessibility → the app could only "activate", which shows window #1).

**Root cause:** `CODE_SIGN_IDENTITY = "-"` in the project forced **ad-hoc
signing** — a different signature every build. macOS ties privacy grants to
the code signature, so each rebuild looked like a new app and old grants
pointed at dead binaries.

**Fixes:**
- Removed the forced ad-hoc identity; builds now sign with the stable
  **Apple Development** certificate (team `7SU7VHW3XY`), so grants persist
  across rebuilds.
- Rewrote `Core/PermissionsManager.swift`: no more blind system prompts at
  every launch. A **welcome/onboarding panel** appears only when a permission
  is missing — live ✓/✕ status per permission (polls every second), "Grant…"
  buttons that open the exact System Settings pane, and a "Relaunch" button
  once everything is green (Screen Recording needs a restart to take effect).
- One-time cleanup after the signing change (run manually):
  `tccutil reset ScreenCapture com.mactaskbar.app` and
  `tccutil reset Accessibility com.mactaskbar.app`, plus removing stale
  MacTaskbar rows in System Settings → Privacy & Security.

### 7. App icon
- Master art: `Icon/MacTaskbar.png` (2048×2048).
- Generated `MacTaskbar/Resources/AppIcon.icns` (all 10 sizes via
  `sips` + `iconutil`), added to the Resources build phase, and set
  `CFBundleIconFile = AppIcon` in Info.plist. The exported app shows the
  icon in Finder. (No Dock icon by design — `LSUIElement`.)

### 8. Folder cleanup
- Consolidated to a **single line of code**: the former `V1.5` became
  `The Grid/Build/MacTaskbar/` alongside the other projects in `Build/`.
- Old `V1.0`–`V1.4` copies and a stray leftover `.xcodeproj` moved to Trash
  (`~/.Trash/MacTaskbar-old-versions/`).
- Recommended for the future: `git init` instead of versioned folder copies.

### 9. Distribution
- Release build packaged at `Export/MacTaskbar-v1.0.zip`.
- Signed but **not notarized** (that needs the paid Apple Developer Program),
  so recipients must approve once: System Settings → Privacy & Security →
  **"Open Anyway"** — then the onboarding panel walks them through
  permissions.

---

## Building

```bash
cd "/Users/tharaniventhan/The Grid/Build/MacTaskbar"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project MacTaskbar.xcodeproj -scheme MacTaskbar -configuration Debug build
```

(`DEVELOPER_DIR` override is needed because `xcode-select` on this machine
points at the Command Line Tools.)

---

## Architecture map

| Area | File | Role |
|---|---|---|
| Data | `Core/WindowManager.swift` | Polls windows (0.5 s), two-pass CG+AX discovery, builds ordered `TaskbarItem` list, icon reordering |
| Window ops | `Core/FocusManager.swift` | CGWindowID→AXUIElement via `_AXUIElementGetWindow`; raise/close/minimize/maximize/restore |
| Thumbnails | `Core/ThumbnailService.swift` | `CGWindowListCreateImage` capture + cache (cache serves minimized windows) |
| Permissions | `Core/PermissionsManager.swift` | Live permission status + onboarding panel + relaunch |
| Bar | `UI/TaskbarView.swift` | Taskbar layout, icon row + drag-reorder event monitor, force-quit panel |
| Icon | `UI/AppIconView.swift` | Per-icon visuals, hover logic, tap, context menu, name tooltip |
| Preview | `UI/HoverPreviewPanel.swift` | Grid of window thumbnails with per-window controls |
| Host window | `UI/TaskbarWindowController.swift` | Bottom-anchored non-activating panel, auto-hide, work-area reservation, hotkeys |
| Settings | `Settings/TaskbarSettings.swift` + `UI/SettingsPanel.swift` | Icon size/position, appearance, auto-hide, pins |

## Known limitations / next ideas

- Not notarized — first-run "Open Anyway" step for other users.
- Unpinned icon order resets when the app quits.
- The AX minimized-window scan runs per app on every 0.5 s poll; if the bar
  ever feels laggy with many apps, throttle that pass.
- Space (virtual desktop) awareness is implicit: previews show current-Space
  windows only because of `optionOnScreenOnly` + the AX minimized pass.
- Future: `git init` for real version control; notarized distribution.
