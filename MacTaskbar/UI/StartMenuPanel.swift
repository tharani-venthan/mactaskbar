import AppKit
import SwiftUI

class StartMenuPanel: NSPanel {
    static let shared = StartMenuPanel()
    private var hostingView: NSHostingView<AnyView>?
    private var clickMonitor: Any?

    private init() {
        super.init(
            contentRect: .zero,
            // NOTE: NOT using .nonactivatingPanel — we need to become key
            // so NSTextField inside can receive keyboard input
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        // Allow this panel to become key so text fields work
        hidesOnDeactivate = false
    }

    // Override so the panel CAN become key window (needed for text input)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 560; let height: CGFloat = 620
        let taskbarH = TaskbarSettings.shared.iconSize.taskbarHeight
        let x = screen.frame.minX + 8
        let y = taskbarH + 8
        setFrame(CGRect(x: x, y: y, width: width, height: height), display: false)

        let view = StartMenuView(onDismiss: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: AnyView(view))
        contentView = hosting
        hostingView = hosting

        orderFrontRegardless()
        // Make key so text fields receive input
        makeKeyAndOrderFront(nil)
        setupClickOutside()
    }

    func hide() {
        orderOut(nil)
        removeClickOutside()
        // Return focus to previously active app
        NSApp.activate(ignoringOtherApps: false)
    }

    private func setupClickOutside() {
        removeClickOutside()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.hide() }
        }
    }

    private func removeClickOutside() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}
