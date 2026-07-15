import SwiftUI
import AppKit

struct AppIconView: View {
    let item: WindowManager.TaskbarItem
    /// Driven by the AppKit row (IconRowNSView) which owns mouse events; the
    /// view's own .onHover can't fire because hit-testing is intercepted there.
    var forcedHover: Bool = false
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false
    @State private var hoverWorkItem: DispatchWorkItem?
    @State private var iconFrame: CGRect = .zero

    var iconColor: Color { settings.isLightMode ? .black : .white }

    private var hovering: Bool { isHovered || forcedHover }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Hover-only highlight — Windows 11 never fills the background
                // for the active state; focus is shown by the underline bar.
                if hovering {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(iconColor.opacity(0.10))
                        .frame(width: settings.iconSize.iconPt + 10,
                               height: settings.iconSize.iconPt + 8)
                }
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).antialiased(true)
                    } else {
                        Image(systemName: "app.fill").resizable()
                            .foregroundColor(iconColor.opacity(0.6))
                    }
                }
                .frame(width: settings.iconSize.iconPt, height: settings.iconSize.iconPt)
                .scaleEffect(hovering ? 1.08 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hovering)
            }

            // Windows 11 underline indicator — one visual unit centered under
            // the icon. Focus is shown by bar width/opacity/color; multi-window
            // apps show 2 segments (capped at 2, like real Windows 11).
            // Widths scale off iconPt — fixed pixel widths only looked right
            // at one icon size and looked broken (too big/tiny) at the others.
            let pt = settings.iconSize.iconPt
            let wideW = pt * 0.45, narrowW = pt * 0.14, segW = pt * 0.16
            let barH = max(2, pt * 0.075)
            HStack(spacing: 2) {
                if item.windowCount > 0 {
                    if item.isActive {
                        Capsule()
                            .fill(settings.accentBarColor)
                            .frame(width: item.windowCount > 1 ? wideW * 0.6 : wideW, height: barH)
                        if item.windowCount > 1 {
                            Capsule()
                                .fill(iconColor.opacity(0.35))
                                .frame(width: segW, height: barH)
                        }
                    } else {
                        Capsule()
                            .fill(iconColor.opacity(0.45))
                            .frame(width: narrowW, height: barH)
                        if item.windowCount > 1 {
                            Capsule()
                                .fill(iconColor.opacity(0.45))
                                .frame(width: narrowW, height: barH)
                        }
                    }
                }
            }
            .frame(height: max(4, barH + 1))
            .animation(.easeInOut(duration: 0.15), value: item.isActive)
        }
        .frame(minWidth: settings.iconSize.iconPt + 14)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { iconFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { iconFrame = $0 }
        })
        .onHover { hovering in
            isHovered = hovering
            hoverWorkItem?.cancel()
            if hovering {
                let work = DispatchWorkItem {
                    // Don't pop a preview while the user is dragging to reorder.
                    guard !TaskbarDragState.shared.isReordering else { return }
                    if self.item.windowCount > 0 {
                        HoverPreviewPanel.shared.show(for: self.item, iconFrame: self.iconFrame)
                    } else {
                        // Not running — no window thumbnails to show, so just
                        // surface the app name like a Windows 11 taskbar tooltip.
                        IconTooltipPanel.shared.show(text: self.item.name, iconFrame: self.iconFrame)
                    }
                }
                hoverWorkItem = work
                // Open apps reveal their window preview almost instantly;
                // closed/not-running apps wait ~0.4s before showing the name.
                let delay: TimeInterval = item.windowCount > 0 ? 0.1 : 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                HoverPreviewPanel.shared.scheduleDismiss()
                IconTooltipPanel.shared.hide()
            }
        }
        .onTapGesture { handleTap() }
        .contextMenu { contextMenuContent }
    }

    private func handleTap() {
        HoverPreviewPanel.shared.hide()
        switch item {
        case .pinnedOnly(let bid):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        case .running(let group, _):
            if group.windows.isEmpty {
                // Running but no open windows — e.g. Spotify after its window
                // is closed via the traffic light, process still alive. There's
                // no window to raise, so just bring the app forward and let it
                // decide what to show (it'll typically reopen its main window).
                group.app.activate(options: [.activateIgnoringOtherApps])
            } else if group.isActive {
                if group.windows.count > 1 {
                    HoverPreviewPanel.shared.show(for: item, iconFrame: iconFrame)
                } else {
                    group.app.hide()
                }
            } else {
                group.app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        let isPinnedTaskbar = item.isPinned
        let isPinnedStart = TaskbarSettings.shared.isPinnedToStart(item.bundleID)
        let bid = item.bundleID

        if let group = item.appGroup {
            if group.windows.count > 1 {
                ForEach(group.windows) { win in
                    Button(win.title.isEmpty ? group.name : win.title) {
                        FocusManager.shared.focusWindow(windowID: win.id, pid: win.ownerPID)
                    }
                }
                Divider()
            }
            Button("New Window") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            Divider()
            Button("Quit \(group.name)") { group.app.terminate() }
            Button("Force Quit \(group.name)") { group.app.forceTerminate() }
            Divider()
        }

        // Pin to Start and Pin to Taskbar are independent — an app can be
        // pinned to either, both, or neither, matching real Windows 11.
        Button(isPinnedTaskbar ? "Unpin from Taskbar" : "Pin to Taskbar") {
            if isPinnedTaskbar { TaskbarSettings.shared.unpin(bundleID: bid) }
            else               { TaskbarSettings.shared.pin(bundleID: bid) }
        }
        Button(isPinnedStart ? "Unpin from Start" : "Pin to Start") {
            if isPinnedStart { TaskbarSettings.shared.unpinFromStart(bundleID: bid) }
            else             { TaskbarSettings.shared.pinToStart(bundleID: bid) }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            Button("Open File Location") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

// MARK: - Windows 11-style name tooltip ("toast" above the icon)

final class IconTooltipPanel: NSPanel {
    static let shared = IconTooltipPanel()

    private init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = true // purely informational — never steals hover/clicks
    }

    func show(text: String, iconFrame: CGRect) {
        let hosting = NSHostingView(rootView: TooltipLabel(text: text))
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        contentView = hosting

        let taskbarH = TaskbarSettings.shared.iconSize.taskbarHeight
        var x = iconFrame.midX - size.width / 2
        if let screen = NSScreen.main {
            x = max(screen.frame.minX + 4, min(x, screen.frame.maxX - size.width - 4))
        }
        setFrame(CGRect(x: x, y: taskbarH + 6, width: size.width, height: size.height), display: false)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

struct TooltipLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.85))
            .cornerRadius(6)
            .fixedSize()
    }
}
