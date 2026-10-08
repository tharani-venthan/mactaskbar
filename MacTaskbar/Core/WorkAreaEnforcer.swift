import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Keeps other apps' windows out of the taskbar's strip.
///
/// macOS gives a third-party bar no way to reserve screen space — only the
/// Dock and menu bar shrink `NSScreen.visibleFrame`, and the private
/// CGSSetWorkArea call is ignored/reset by current macOS. So a zoomed, tiled
/// or "filled" window is sized by the system to the full screen height and
/// ends up underneath the taskbar. This does what uBar-style bars do instead:
/// watch every app's windows through Accessibility and pull the bottom edge
/// of any window that lands in the strip back up to the taskbar's top.
///
/// It also covers the two other ways a window can "go full screen":
///   • the green button — optionally turned into a Windows-style maximize
///     (fill the area above the taskbar) instead of a native full-screen Space;
///   • real native full screen (video, ⌃⌘F, menu) — the taskbar gets out of
///     the way, like Windows does for full-screen apps.
final class WorkAreaEnforcer {
    static let shared = WorkAreaEnforcer()

    /// Taskbar frame (Cocoa coords) while it is reserving space; nil while it
    /// is auto-hidden or otherwise not occupying the strip.
    var reservedFrame: () -> CGRect? = { nil }
    var taskbarScreen: () -> NSScreen? = { NSScreen.main }
    var onFullScreenChange: ((Bool) -> Void)?

    private let settings = TaskbarSettings.shared
    private let systemWide = AXUIElementCreateSystemWide()
    private var started = false

    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [AXUIElement] = []
    private var generation = 0
    private var recentFixes: [CGWindowID: (count: Int, since: Date)] = [:]

    private var isFullScreen = false
    private var fullScreenTimer: Timer?

    private var eventTap: CFMachPort?
    private var swallowNextMouseUp = false
    /// Windows we maximized: the frame to restore to, and the frame the app
    /// actually accepted (apps with a max size don't reach the full work area).
    private var maximized: [CGWindowID: (restore: CGRect, applied: CGRect)] = [:]

    private static let windowNotifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        // Everything here needs Accessibility; wait for the onboarding grant.
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }
        started = true
        // A hung app must not stall us (the click tap below runs synchronously).
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        for app in NSWorkspace.shared.runningApplications { observe(app) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(app)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers[app.processIdentifier] = nil
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.checkFullScreen() }
        }
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFullScreen()
        }

        installGreenButtonTap()
        sweep()
        checkFullScreen()
    }

    /// Re-check every window — call when the reserved strip appears or grows.
    func sweep() {
        guard started else { return }
        for pid in observers.keys {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &ref)
            for win in (ref as? [AXUIElement]) ?? [] { enforce(win) }
        }
    }

    // MARK: - Window observation

    private func observe(_ app: NSRunningApplication, retries: Int = 4) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }
        // A just-launched app often isn't answering AX yet (and may not have
        // settled its activation policy) — try again shortly.
        let retry = { [weak self] in
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.observe(app, retries: retries - 1) }
        }
        guard app.activationPolicy == .regular else { retry(); return }

        var created: AXObserver?
        guard AXObserverCreate(pid, axWindowCallback, &created) == .success, let observer = created else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in Self.windowNotifications
        where AXObserverAddNotification(observer, appEl, name as CFString, refcon) == .success {
            registered = true
        }
        guard registered else { retry(); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref)
        for win in (ref as? [AXUIElement]) ?? [] { enforce(win) }
    }

    fileprivate func windowChanged(_ element: AXUIElement) {
        if !pending.contains(where: { CFEqual($0, element) }) { pending.append(element) }
        scheduleFlush(after: 0.2)
    }

    /// Debounced: zoom/tile animations fire a burst of resize notifications,
    /// and correcting a window mid-animation just gets overwritten.
    private func scheduleFlush(after delay: TimeInterval) {
        generation += 1
        let scheduled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            // Never resize a window out from under an in-progress drag.
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleFlush(after: 0.15)
                return
            }
            let windows = self.pending
            self.pending = []
            windows.forEach(self.enforce)
            self.checkFullScreen()
        }
    }

    // MARK: - Enforcement

    private func enforce(_ win: AXUIElement) {
        guard let reserved = reservedFrame(),
              string(win, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !bool(win, "AXFullScreen"), !bool(win, kAXMinimizedAttribute),
              let frame = frame(of: win) else { return }

        // AX frames are top-left-origin, relative to the primary display.
        let barTop = primaryHeight - reserved.maxY
        let barBottom = primaryHeight - reserved.minY
        guard frame.maxX > reserved.minX, frame.minX < reserved.maxX,
              frame.minY < barTop,
              frame.maxY > barTop + 1,
              // A window the user parked half off the bottom of the screen is
              // left alone, exactly as Windows leaves it.
              frame.maxY <= barBottom + 1 else { return }

        let newHeight = barTop - frame.minY
        guard newHeight >= 100 else { return }

        // An app that insists on its own size would otherwise ping-pong with us.
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(win, &wid)
        let now = Date()
        var fix = recentFixes[wid] ?? (0, now)
        if now.timeIntervalSince(fix.since) > 3 { fix = (0, now) }
        guard fix.count < 4 else { return }
        recentFixes[wid] = (fix.count + 1, fix.since)

        setSize(win, CGSize(width: frame.width, height: newHeight))
    }

    // MARK: - Native full screen

    /// True while the frontmost window is a native full-screen window on the
    /// taskbar's display and Space.
    private func checkFullScreen() {
        guard started,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }

        var full = false
        var ref: CFTypeRef?
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let win = ref as! AXUIElement
            var wid: CGWindowID = 0
            if bool(win, "AXFullScreen"),
               _AXUIElementGetWindow(win, &wid) == .success,
               // The app can stay frontmost after swiping to another Space —
               // only count the window if it is actually on this Space.
               isOnScreen(wid),
               let frame = frame(of: win),
               screen(containing: frame) == taskbarScreen() {
                full = true
            }
        }
        guard full != isFullScreen else { return }
        isFullScreen = full
        onFullScreenChange?(full)
    }

    private func isOnScreen(_ wid: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber] as? CGWindowID) == wid }
    }

    // MARK: - Green button → maximize

    private func installGreenButtonTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: greenButtonTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true to swallow the event.
    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false

        case .leftMouseUp:
            defer { swallowNextMouseUp = false }
            return swallowNextMouseUp

        case .leftMouseDown:
            swallowNextMouseUp = false
            // ⌥-click keeps its native meaning (zoom), which enforce() then fits.
            guard settings.greenButtonMaximizes, !event.flags.contains(.maskAlternate) else { return false }
            let point = event.location
            // Hit-testing our own windows from the main thread would wait on ourselves.
            guard !isOverOwnWindow(point) else { return false }

            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
                  let button = hit,
                  string(button, kAXSubroleAttribute) == "AXFullScreenButton" else { return false }
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(button, kAXWindowAttribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
            let win = ref as! AXUIElement
            // In full screen the green button is the way back out — leave it.
            guard !bool(win, "AXFullScreen") else { return false }

            swallowNextMouseUp = true
            DispatchQueue.main.async { self.toggleMaximize(win) }
            return true

        default:
            return false
        }
    }

    private func isOverOwnWindow(_ cgPoint: CGPoint) -> Bool {
        let point = CGPoint(x: cgPoint.x, y: primaryHeight - cgPoint.y)
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
    }

    private func toggleMaximize(_ win: AXUIElement) {
        guard let current = frame(of: win) else { return }
        let target = workArea(containing: current)
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(win, &wid)

        if let state = maximized[wid], approx(current, state.applied) {
            setFrame(win, state.restore)
            maximized[wid] = nil
        } else if approx(current, target) {
            // Already filling the work area but not by us — "restore down".
            setFrame(win, target.insetBy(dx: target.width * 0.125, dy: target.height * 0.125))
        } else {
            setFrame(win, target)
            maximized[wid] = (restore: current, applied: frame(of: win) ?? target)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    // MARK: - Geometry

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func screen(containing axFrame: CGRect) -> NSScreen? {
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    /// Usable area (AX coords) of the screen the given window is on: below
    /// the menu bar, beside any Dock, above the taskbar.
    private func workArea(containing axFrame: CGRect) -> CGRect {
        guard let screen = screen(containing: axFrame) ?? taskbarScreen() else { return axFrame }
        var area = screen.visibleFrame
        if let reserved = reservedFrame(), screen.frame.intersects(reserved) {
            let bottom = max(area.minY, reserved.maxY)
            area = CGRect(x: area.minX, y: bottom, width: area.width, height: area.maxY - bottom)
        }
        return CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
    }

    private func approx(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 4
        return abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol &&
               abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    // MARK: - AX helpers

    private func frame(of win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func setPosition(_ win: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
    }

    private func setSize(_ win: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
    }

    private func setFrame(_ win: AXUIElement, _ frame: CGRect) {
        // Position first so the resize isn't clipped by the old screen edge,
        // then again because some apps nudge the origin while resizing.
        setPosition(win, frame.origin)
        setSize(win, frame.size)
        setPosition(win, frame.origin)
    }

    private func bool(_ el: AXUIElement, _ attribute: String) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attribute as CFString, &ref)
        return ref as? String
    }
}

private let axWindowCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    Unmanaged<WorkAreaEnforcer>.fromOpaque(refcon).takeUnretainedValue().windowChanged(element)
}

private let greenButtonTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let enforcer = Unmanaged<WorkAreaEnforcer>.fromOpaque(refcon).takeUnretainedValue()
    return enforcer.handleTap(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
