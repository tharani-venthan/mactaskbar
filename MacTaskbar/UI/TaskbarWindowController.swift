import AppKit
import SwiftUI

class TaskbarWindowController: NSWindowController {
    private var taskbarPanel: NSPanel?
    private let settings = TaskbarSettings.shared
    private var settingsObserver: Any?
    private var isHidden = false
    private var edgeTrackingArea: NSTrackingArea?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var workAreaTimer: Timer?

    convenience init() {
        let panel = Self.makePanel()
        self.init(window: panel)
        self.taskbarPanel = panel
        setupContent()
        positionAtBottom()
        reserveScreenSpace()
        setupSettingsObserver()
        setupGlobalHotkey()
        setupWorkAreaMaintenance()
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Above everything, including a maximized/fullscreen app's own window —
        // matches the real Dock's level so nothing ever draws over the taskbar.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    /// CGSSetWorkArea is a private, unentitled API — macOS periodically resets
    /// the reported work area back to full-screen (e.g. on Space switches,
    /// display changes, or just after a few seconds), which is why apps were
    /// sizing themselves into the taskbar's space. Reapplying it on a timer
    /// plus on the relevant notifications keeps it honest. This still isn't a
    /// full guarantee — a first-party Dock-level entitlement would be — but it
    /// covers the common cases (launch, resize, space switch, display change).
    private func setupWorkAreaMaintenance() {
        workAreaTimer?.invalidate()
        workAreaTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            self.reserveScreenSpace()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reserveScreenSpace() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reserveScreenSpace() }
    }

    private func setupContent() {
        guard let panel = taskbarPanel else { return }
        panel.contentView = NSHostingView(rootView: TaskbarView())
    }

    // MARK: - Start menu hotkey (user-customisable in Settings)
    // The monitors read TaskbarSettings live on every event, so a combo change
    // in Settings takes effect immediately — no re-registration needed.
    private static let hotkeyModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private static func matchesStartHotkey(_ event: NSEvent) -> Bool {
        let s = TaskbarSettings.shared
        let wanted = NSEvent.ModifierFlags(rawValue: UInt(s.startHotkeyModifiers)).intersection(hotkeyModifierMask)
        let actual = event.modifierFlags.intersection(hotkeyModifierMask)
        return Int(event.keyCode) == s.startHotkeyKeyCode && actual == wanted
    }

    private func setupGlobalHotkey() {
        // Global monitor: fires while other apps are frontmost
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if Self.matchesStartHotkey(event) {
                DispatchQueue.main.async { StartMenuPanel.shared.toggle() }
            }
        }
        // Local monitor: fires while our own panels are key (e.g. closing the menu)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.matchesStartHotkey(event) {
                DispatchQueue.main.async { StartMenuPanel.shared.toggle() }
                return nil
            }
            return event
        }
    }

    // MARK: - Position

    func positionAtBottom(animated: Bool = false) {
        guard let panel = taskbarPanel, let screen = NSScreen.main else { return }
        let height = settings.iconSize.taskbarHeight
        let sf = screen.frame
        let target = CGRect(x: sf.minX, y: sf.minY, width: sf.width, height: height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
        reserveScreenSpace()
        setupEdgeTracking()
    }

    // MARK: - Auto-hide edge tracking

    private func setupEdgeTracking() {
        guard settings.autoHide, let screen = NSScreen.main else { return }
        // Create a tiny 1px strip at screen bottom to detect mouse entry
        let strip = CGRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: 2)
        // We poll mouse position instead (more reliable than NSTrackingArea on screen edge)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.settings.autoHide else { return }
            let mouse = NSEvent.mouseLocation
            if mouse.y <= 3 && self.isHidden {
                self.showTaskbar()
            } else if mouse.y > self.settings.iconSize.taskbarHeight + 10 && !self.isHidden {
                // Check if any popup panel is visible before hiding
                if !HoverPreviewPanel.shared.isVisible && !StartMenuPanel.shared.isVisible {
                    self.hideTaskbar()
                }
            }
        }
    }

    func hideTaskbar() {
        guard let panel = taskbarPanel, let screen = NSScreen.main, !isHidden else { return }
        isHidden = true
        let sf = screen.frame
        let h = settings.iconSize.taskbarHeight
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(
                CGRect(x: sf.minX, y: sf.minY - h + 2, width: sf.width, height: h),
                display: true
            )
        }
        restoreFullScreenSpace(screen: screen)
    }

    func showTaskbar() {
        guard isHidden else { return }
        isHidden = false
        positionAtBottom(animated: true)
    }

    // MARK: - Screen space reservation (CGSSetWorkArea)

    private func reserveScreenSpace() {
        guard let screen = NSScreen.main else { return }
        callCGSSetWorkArea(screen: screen, taskbarHeight: settings.iconSize.taskbarHeight)
    }

    private func callCGSSetWorkArea(screen: NSScreen, taskbarHeight: CGFloat) {
        guard let cgs = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return }
        defer { dlclose(cgs) }
        typealias ConnFn     = @convention(c) () -> UInt32
        typealias WorkAreaFn = @convention(c) (UInt32, UInt32, CGRect) -> Int32
        guard let connSym = dlsym(cgs, "CGSMainConnectionID"),
              let workSym = dlsym(cgs, "CGSSetWorkArea") else { return }
        let connID    = unsafeBitCast(connSym, to: ConnFn.self)()
        let setArea   = unsafeBitCast(workSym, to: WorkAreaFn.self)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? CGMainDisplayID()
        let sf = screen.frame
        _ = setArea(connID, displayID, CGRect(x: sf.minX, y: sf.minY + taskbarHeight,
                                              width: sf.width, height: sf.height - taskbarHeight))
    }

    private func restoreFullScreenSpace(screen: NSScreen) {
        guard let cgs = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return }
        defer { dlclose(cgs) }
        typealias ConnFn     = @convention(c) () -> UInt32
        typealias WorkAreaFn = @convention(c) (UInt32, UInt32, CGRect) -> Int32
        guard let connSym = dlsym(cgs, "CGSMainConnectionID"),
              let workSym = dlsym(cgs, "CGSSetWorkArea") else { return }
        let connID  = unsafeBitCast(connSym, to: ConnFn.self)()
        let setArea = unsafeBitCast(workSym, to: WorkAreaFn.self)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? CGMainDisplayID()
        _ = setArea(connID, displayID, screen.frame)
    }

    // MARK: - Settings observer

    private func setupSettingsObserver() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.positionAtBottom(animated: true)
            if self?.settings.autoHide == true {
                self?.setupEdgeTracking()
            }
        }
    }

    override func showWindow(_ sender: Any?) { taskbarPanel?.orderFrontRegardless() }

    deinit {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        workAreaTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let screen = NSScreen.main { restoreFullScreenSpace(screen: screen) }
    }
}
