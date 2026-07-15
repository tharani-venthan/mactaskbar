import AppKit
import SwiftUI

class HoverPreviewPanel: NSPanel {
    static let shared = HoverPreviewPanel()

    private var hostingView: NSHostingView<AnyView>?
    private var currentBundleID: String?
    private var dismissTimer: Timer?
    private var cursorInsidePanel = false

    private init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = false; acceptsMouseMovedEvents = true
    }

    func show(for item: WindowManager.TaskbarItem, iconFrame: CGRect) {
        guard let group = item.appGroup, !group.windows.isEmpty else { return }
        dismissTimer?.invalidate(); dismissTimer = nil
        currentBundleID = item.bundleID; cursorInsidePanel = false

        let count = group.windows.count
        let isSingle = count == 1
        let cardW: CGFloat = isSingle ? 280 : 200
        let cardH: CGFloat = isSingle ? 180 : 130
        let padding: CGFloat = 12; let spacing: CGFloat = 10

        // Grid: up to 3 columns, wrapping into rows.
        let columns = min(count, 3)
        let rows = (count + columns - 1) / columns
        let titleH: CGFloat = 20   // per-card title line
        let headerH: CGFloat = 34  // app name + Quit row

        let totalW = CGFloat(columns) * cardW
                   + CGFloat(columns - 1) * spacing + padding * 2
        let panelW = max(totalW, 240)
        let panelH = CGFloat(rows) * (cardH + titleH)
                   + CGFloat(rows - 1) * spacing + headerH + padding * 2

        let taskbarH = TaskbarSettings.shared.iconSize.taskbarHeight
        var panelX = iconFrame.midX - panelW / 2
        if let screen = NSScreen.main {
            panelX = max(screen.frame.minX + 8, min(panelX, screen.frame.maxX - panelW - 8))
        }

        setFrame(CGRect(x: panelX, y: taskbarH + 8, width: panelW, height: panelH), display: false)

        let view = HoverPreviewView(
            group: group, cardWidth: cardW, cardHeight: cardH, columns: columns,
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: AnyView(view))
        contentView = hosting; hostingView = hosting
        setupPanelTracking(hosting: hosting)
        orderFrontRegardless()
    }

    func hide() {
        dismissTimer?.invalidate(); dismissTimer = nil
        cursorInsidePanel = false; orderOut(nil); currentBundleID = nil
    }

    func scheduleDismiss() {
        guard isVisible else { return }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, !self.cursorInsidePanel else { return }
            self.hide()
        }
    }

    func cancelDismiss() { dismissTimer?.invalidate(); dismissTimer = nil; cursorInsidePanel = true }
    func panelMouseExited() { cursorInsidePanel = false; scheduleDismiss() }
    func isShowing(for bid: String) -> Bool { currentBundleID == bid && isVisible }

    private func setupPanelTracking(hosting: NSView) {
        for a in hosting.trackingAreas { hosting.removeTrackingArea(a) }
        hosting.addTrackingArea(NSTrackingArea(
            rect: hosting.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { cancelDismiss() }
    override func mouseExited(with event: NSEvent)  { panelMouseExited() }
}

// MARK: - Preview View

struct HoverPreviewView: View {
    let group: AppGroup
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let columns: Int
    let onDismiss: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        ZStack {
            VisualEffectBlur(material: settings.taskbarMaterial, blendingMode: .behindWindow)
                .cornerRadius(10)
            Color(settings.isLightMode ? .white : .black).opacity(settings.isLightMode ? 0.2 : 0.4)
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 0) {
                // App header
                HStack(spacing: 6) {
                    if let icon = group.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(settings.isLightMode ? .black : .white)
                    Spacer()
                    Button(action: { group.app.terminate(); onDismiss() }) {
                        Text("Quit")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

                // Thumbnail cards — wrapping grid, up to 3 per row
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                    spacing: 10
                ) {
                    ForEach(group.windows) { window in
                        WindowPreviewCard(
                            windowInfo: window,
                            group: group,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight,
                            onFocus: {
                                if window.isMinimized {
                                    FocusManager.shared.restoreWindow(windowID: window.id, pid: window.ownerPID)
                                } else {
                                    FocusManager.shared.focusWindow(windowID: window.id, pid: window.ownerPID)
                                }
                                onDismiss()
                            },
                            onClose: {
                                FocusManager.shared.closeWindow(windowID: window.id, pid: window.ownerPID)
                            },
                            onMinimise: {
                                minimiseWindow(window)
                            },
                            onRestore: {
                                FocusManager.shared.restoreWindow(windowID: window.id, pid: window.ownerPID)
                                onDismiss()
                            },
                            onMaximise: {
                                maximiseWindow(window, app: group.app)
                                onDismiss()
                            }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    private func minimiseWindow(_ window: WindowInfo) {
        FocusManager.shared.minimiseWindow(windowID: window.id, pid: window.ownerPID)
    }

    private func maximiseWindow(_ window: WindowInfo, app: NSRunningApplication) {
        FocusManager.shared.maximiseWindow(windowID: window.id, pid: window.ownerPID)
    }
}

// MARK: - Window Preview Card (with traffic light buttons)

struct WindowPreviewCard: View {
    let windowInfo: WindowInfo
    let group: AppGroup
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let onFocus: () -> Void
    let onClose: () -> Void
    let onMinimise: () -> Void
    let onRestore: () -> Void
    let onMaximise: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @State private var controlsHovered = false
    @ObservedObject private var settings = TaskbarSettings.shared

    var windowTitle: String {
        windowInfo.title.isEmpty ? group.name : windowInfo.title
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Thumbnail — tap gesture scoped to just this layer so it
                // doesn't sit on top of (and swallow clicks for) the traffic
                // light buttons below, which are a sibling in the outer ZStack.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: cardWidth, height: cardHeight)

                    if let img = thumbnail {
                        ZStack {
                            Image(nsImage: img)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: cardWidth, height: cardHeight)
                                .clipped().cornerRadius(6)
                            if windowInfo.isMinimized {
                                // Dim the stale cached shot so its state is obvious
                                Color.black.opacity(0.45).cornerRadius(6)
                                    .frame(width: cardWidth, height: cardHeight)
                            }
                        }
                    } else if windowInfo.isMinimized {
                        // No live capture exists for a minimized window —
                        // fall back to the app icon as a placeholder.
                        VStack(spacing: 6) {
                            if let icon = group.icon {
                                Image(nsImage: icon).resizable()
                                    .frame(width: 48, height: 48)
                            }
                            Text("Minimized")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(width: cardWidth, height: cardHeight)
                    } else {
                        ProgressView().frame(width: cardWidth, height: cardHeight)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isHovered ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }

                // Traffic light controls (show on hover)
                if isHovered {
                    HStack(spacing: 5) {
                        // Close — red
                        TrafficButton(color: .red, symbol: "xmark", action: onClose)
                        if windowInfo.isMinimized {
                            // Restore — yellow (window is already minimized)
                            TrafficButton(color: Color(red: 1, green: 0.73, blue: 0), symbol: "square.on.square", action: onRestore)
                        } else {
                            // Minimise — yellow
                            TrafficButton(color: Color(red: 1, green: 0.73, blue: 0), symbol: "minus", action: onMinimise)
                            // Maximise — green
                            TrafficButton(color: Color(red: 0.13, green: 0.78, blue: 0.35), symbol: "arrow.up.left.and.arrow.down.right", action: onMaximise)
                        }
                    }
                    .padding(6)
                    .transition(.opacity)
                    .zIndex(10)  // ensure above thumbnail
                    .allowsHitTesting(true)
                }
            }

            // Window title
            Text(windowTitle)
                .font(.system(size: 11))
                .foregroundColor(settings.isLightMode ? .black.opacity(0.8) : .white.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: cardWidth)
                .padding(.top, 4)
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
        .task {
            if windowInfo.isMinimized {
                // CGWindowListCreateImage can't capture a minimized window;
                // use the last capture taken while it was still on screen.
                thumbnail = ThumbnailService.shared.cachedThumbnail(for: windowInfo.id)
            } else {
                thumbnail = await ThumbnailService.shared.thumbnail(
                    for: windowInfo.id,
                    size: CGSize(width: cardWidth, height: cardHeight)
                )
            }
        }
    }
}

struct TrafficButton: View {
    let color: Color
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 14, height: 14)
                if hovered {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Shared blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blendingMode
        v.state = .active; v.wantsLayer = true; v.layer?.cornerRadius = 10
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
