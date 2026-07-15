import AppKit
import ApplicationServices

// Private CoreGraphics/AX bridge: returns the CGWindowID backing an AX window
// element. This is the ONLY reliable way to map a CGWindowID (what we get from
// CGWindowListCopyWindowInfo) to an AXUIElement (what we need to raise/close a
// specific window). Bounds/title/z-order matching is guesswork and was why
// clicking window 2 or 3 always acted on window 1. Used by AltTab, yabai, etc.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

class FocusManager {
    static let shared = FocusManager()

    // MARK: - Focus a specific window by ID

    func focusWindow(windowID: CGWindowID, pid: pid_t) {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) else { return }

        // If already active, just raise — no need to re-activate
        if app.isActive {
            raiseWindowByID(windowID: windowID, pid: pid)
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
            // Wait for activation before raising specific window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.raiseWindowByID(windowID: windowID, pid: pid)
            }
        }
    }

    /// Core window raise — resolves CG window to its matching AX window (see resolveAXWindow)
    private func raiseWindowByID(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }

        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl), !axWindows.isEmpty else { return }
        performRaise(resolveAXWindow(windowID: windowID, pid: pid, axWindows: axWindows))
    }

    private func performRaise(_ axWin: AXUIElement) {
        // Un-minimize first — raising a minimized window is a no-op otherwise.
        // Setting the attribute to false on a non-minimized window is harmless.
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
    }

    // MARK: - Minimized-window discovery & restore

    /// Windows of `pid` that are currently minimized (absent from CGWindowList).
    /// Uses _AXUIElementGetWindow so each entry carries its real CGWindowID.
    func minimizedWindows(pid: pid_t) -> [(id: CGWindowID, title: String)] {
        guard AXIsProcessTrusted() else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl) else { return [] }

        var result: [(id: CGWindowID, title: String)] = []
        for axWin in axWindows {
            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef)
            guard (minRef as? Bool) == true else { continue }

            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWin, &wid) == .success, wid != 0 else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
            result.append((id: wid, title: (titleRef as? String) ?? ""))
        }
        return result
    }

    /// Restore a minimized window and bring it to front.
    func restoreWindow(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) else { return }
        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl), !axWindows.isEmpty else { return }
        let axWin = resolveAXWindow(windowID: windowID, pid: pid, axWindows: axWindows)
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        app.activate(options: [.activateIgnoringOtherApps])
        performRaise(axWin)
    }

    // MARK: - Close window

    func closeWindow(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl), !axWindows.isEmpty else { return }
        pressAXButton(resolveAXWindow(windowID: windowID, pid: pid, axWindows: axWindows), kAXCloseButtonAttribute)
    }

    // MARK: - Minimise / Maximise

    func minimiseWindow(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl), !axWindows.isEmpty else { return }
        pressAXButton(resolveAXWindow(windowID: windowID, pid: pid, axWindows: axWindows), kAXMinimizeButtonAttribute)
    }

    /// Resolve the AX window matching a given CG window.
    /// Primary: direct CGWindowID match via _AXUIElementGetWindow (exact).
    /// Fallbacks (only if the private API is ever unavailable): bounds, title, z-order.
    private func resolveAXWindow(windowID: CGWindowID, pid: pid_t, axWindows: [AXUIElement]) -> AXUIElement {
        // Primary — exact CGWindowID match.
        for axWin in axWindows {
            var axID: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &axID) == .success, axID == windowID {
                return axWin
            }
        }
        // Fallbacks
        if let cgBounds = getCGWindowBounds(windowID: windowID) {
            if let match = axWindows.first(where: { boundsMatch(axWin: $0, cgBounds: cgBounds) }) {
                return match
            }
        }
        if let cgTitle = getCGWindowTitle(windowID: windowID), !cgTitle.isEmpty {
            for axWin in axWindows {
                var ref: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &ref)
                if (ref as? String) == cgTitle { return axWin }
            }
        }
        if let cgIndex = getCGWindowZIndex(windowID: windowID, pid: pid), cgIndex < axWindows.count {
            return axWindows[cgIndex]
        }
        return axWindows[0]
    }

    func maximiseWindow(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        let appEl = AXUIElementCreateApplication(pid)
        guard let axWindows = getAXWindows(appEl), !axWindows.isEmpty else { return }
        pressAXButton(resolveAXWindow(windowID: windowID, pid: pid, axWindows: axWindows), kAXZoomButtonAttribute)
    }

    // MARK: - AX helpers

    private func getAXWindows(_ appEl: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref)
        return ref as? [AXUIElement]
    }

    private func pressAXButton(_ axWin: AXUIElement, _ attribute: String) {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, attribute as CFString, &ref)
        guard let btn = ref, CFGetTypeID(btn) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }

    // MARK: - CG helpers

    /// Z-order index of windowID among this pid's on-screen layer-0 windows (front = 0)
    private func getCGWindowZIndex(windowID: CGWindowID, pid: pid_t) -> Int? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        let pidWins = list.filter {
            ($0[kCGWindowOwnerPID] as? pid_t) == pid &&
            ($0[kCGWindowLayer] as? Int) == 0
        }
        return pidWins.firstIndex { ($0[kCGWindowNumber] as? CGWindowID) == windowID }
    }

    private func getCGWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
            as? [[CFString: Any]],
              let info = list.first,
              let d = info[kCGWindowBounds] as? [String: CGFloat] else { return nil }
        return CGRect(x: d["X"] ?? 0, y: d["Y"] ?? 0,
                      width: d["Width"] ?? 0, height: d["Height"] ?? 0)
    }

    private func getCGWindowTitle(windowID: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
            as? [[CFString: Any]] else { return nil }
        return list.first?[kCGWindowName] as? String
    }

    private func boundsMatch(axWin: AXUIElement, cgBounds: CGRect) -> Bool {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero; var s = CGSize.zero
        if let v = posRef  { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = sizeRef { AXValueGetValue(v as! AXValue, .cgSize,  &s) }
        // AXPositionAttribute is already in top-left-origin global screen
        // coordinates — the same system CGWindowList uses. No flip needed;
        // the previous flip against NSScreen height meant this never matched.
        let tol: CGFloat = 8
        return abs(p.x - cgBounds.minX) < tol &&
               abs(p.y - cgBounds.minY) < tol &&
               abs(s.width  - cgBounds.width)  < tol &&
               abs(s.height - cgBounds.height) < tol
    }
}
