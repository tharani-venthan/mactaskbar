import AppKit
import SwiftUI

class TaskbarWindowController: NSWindowController {
    private var taskbarPanel: NSPanel?
    private let settings = TaskbarSettings.shared
    private var settingsObserver: Any?
    private var isHidden = false
    private var hiddenForFullScreen = false
    private var lastReservedHeight: CGFloat = 0
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
        setupWorkAreaEnforcer()
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Matches the real Dock's level so no ordinary window draws over the
        // taskbar. Deliberately not .fullScreenAuxiliary: in a native
        // full-screen Space the taskbar steps aside (see setupWorkAreaEnforcer).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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

    /// The part that actually keeps windows above the taskbar — see
    /// WorkAreaEnforcer for why CGSSetWorkArea alone doesn't.
    private func setupWorkAreaEnforcer() {
        let enforcer = WorkAreaEnforcer.shared
        enforcer.taskbarScreen = { [weak self] in self?.taskbarPanel?.screen ?? NSScreen.main }
        enforcer.reservedFrame = { [weak self] in
            guard let self, !self.isHidden, !self.hiddenForFullScreen, !self.settings.autoHide,
                  let screen = self.taskbarPanel?.screen ?? NSScreen.main else { return nil }
            let sf = screen.frame
            return CGRect(x: sf.minX, y: sf.minY, width: sf.width, height: self.settings.iconSize.taskbarHeight)
        }
        enforcer.onFullScreenChange = { [weak self] fullScreen in
            guard let self, let panel = self.taskbarPanel else { return }
            self.hiddenForFullScreen = fullScreen
            if fullScreen {
                HoverPreviewPanel.shared.hide()
                IconTooltipPanel.shared.hide()
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        enforcer.start()
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
        if !hiddenForFullScreen { panel.orderFrontRegardless() }
        reserveScreenSpace()
        setupEdgeTracking()

        // Windows that fit the old strip may now sit under a taller/re-shown bar.
        let reserved = settings.autoHide ? 0 : height
        if reserved > lastReservedHeight { WorkAreaEnforcer.shared.sweep() }
        lastReservedHeight = reserved
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

    override func showWindow(_ sender: Any?) {
        if !hiddenForFullScreen { taskbarPanel?.orderFrontRegardless() }
    }

    deinit {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        workAreaTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let screen = NSScreen.main { restoreFullScreenSpace(screen: screen) }
    }
}
