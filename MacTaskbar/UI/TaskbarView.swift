import SwiftUI
import AppKit

struct TaskbarView: View {
    @ObservedObject private var windowManager = WindowManager.shared
    @ObservedObject private var settings      = TaskbarSettings.shared

    var body: some View {
        ZStack {
            TaskbarBackground()

            Group {
                switch settings.iconPosition {
                case .center:
                    // Start button is part of the centered group itself (like
                    // Windows 11), not a fixed left anchor — so it moves as a
                    // unit with the icon row instead of staying pinned left.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            StartButton()
                            iconsRow
                        }
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 44)
                    }
                case .left:
                    HStack(spacing: 0) {
                        StartButton().padding(.leading, 6)
                        iconsRow
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: settings.iconSize.taskbarHeight)
        .contextMenu {
            Button("Taskbar Settings") { SettingsPanelController.shared.toggle() }
            Divider()
            Button("Task Manager") { TaskManagerPanel.shared.show() }
        }
    }

    // fixedSize makes the row hug its intrinsic width — without it the NSView
    // stretches to fill all available space and "center" alignment has nothing
    // to actually center.
    private var iconsRow: some View {
        DraggableIconsRow(items: windowManager.taskbarItems)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: settings.iconSize.taskbarHeight)
    }
}

// MARK: - Background

struct TaskbarBackground: View {
    @ObservedObject private var settings = TaskbarSettings.shared
    var body: some View {
        ZStack {
            DynamicBlurBackground()
            Color(settings.isLightMode ? .white : .black)
                .opacity(settings.isLightMode ? 0.25 : 0.55)
        }.ignoresSafeArea()
    }
}

struct DynamicBlurBackground: NSViewRepresentable {
    @ObservedObject private var settings = TaskbarSettings.shared
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = settings.taskbarMaterial
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = settings.taskbarMaterial
    }
}

// MARK: - Start Button

struct StartButton: View {
    @State private var isHovered = false
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        // Scale off iconPt so Start stays proportionate to the app icons at
        // every size — it was fixed at 18pt, which only looked right around
        // the S/M presets and looked tiny next to XL icons.
        let logoSize = settings.iconSize.iconPt * 0.45
        Button(action: { StartMenuPanel.shared.toggle() }) {
            WindowsLogo(size: logoSize)
                .padding(settings.iconSize.iconPt * 0.2)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.15) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Start  (\(settings.startHotkeyDisplayString))")
    }
}

// MARK: - Draggable Icons Row
//
// Architecture: each icon is a SwiftUI AppIconView (so hover, tap, and the
// right-click context menu all work natively). Drag-to-reorder is layered on
// via a *local NSEvent monitor* rather than by hijacking hit-testing — the
// monitor sees mouse events before they reach the hosting views, so it can
// claim a press-and-move as a drag while letting a plain click fall through to
// SwiftUI as a tap. This is necessary because SwiftUI `.onDrag` never starts
// inside a `.nonactivatingPanel` (the window never becomes a drag source).

/// Shared flag so AppIconView can suppress its hover preview mid-reorder.
final class TaskbarDragState {
    static let shared = TaskbarDragState()
    var isReordering = false
}

struct DraggableIconsRow: NSViewRepresentable {
    let items: [WindowManager.TaskbarItem]

    func makeNSView(context: Context) -> IconRowNSView { IconRowNSView() }
    func updateNSView(_ nsView: IconRowNSView, context: Context) { nsView.update(items: items) }
}

/// Lays out SwiftUI icon views and adds drag-to-reorder via an event monitor.
/// Views are keyed by bundleID and reused, so reorders animate positions
/// (Windows 11-style) instead of tearing everything down; the dragged icon
/// tracks the cursor 1:1 while its neighbors spring aside.
final class IconRowNSView: NSView {
    private var views: [String: NSHostingView<AppIconView>] = [:]  // bundleID → view
    private var items: [WindowManager.TaskbarItem] = []
    private let spacing: CGFloat = 2
    private var monitor: Any?
    private var lastIconW: CGFloat = 0

    // Drag state
    private var draggingBID: String?
    private var downX: CGFloat = 0
    private var grabOffsetX: CGFloat = 0
    private var isDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var iconW: CGFloat { TaskbarSettings.shared.iconSize.iconPt + 16 }
    private var rowH: CGFloat { TaskbarSettings.shared.iconSize.taskbarHeight }
    private var slotW: CGFloat { iconW + spacing }

    func update(items newItems: [WindowManager.TaskbarItem]) {
        let oldOrder = items.map(\.bundleID)
        let newOrder = newItems.map(\.bundleID)
        let sizeChanged = iconW != lastIconW
        lastIconW = iconW

        // Drop views whose apps left the bar
        for bid in Set(oldOrder).subtracting(newOrder) {
            views[bid]?.removeFromSuperview()
            views[bid] = nil
        }
        // Create new views / refresh existing ones in place
        for item in newItems {
            if let hv = views[item.bundleID] {
                hv.rootView = AppIconView(item: item)
            } else {
                let hv = NSHostingView(rootView: AppIconView(item: item))
                hv.wantsLayer = true
                hv.frame = CGRect(x: frame.width, y: 0, width: iconW, height: rowH)
                addSubview(hv)
                views[item.bundleID] = hv
            }
        }

        let orderChanged = oldOrder != newOrder
        items = newItems
        if orderChanged || sizeChanged {
            // Animate reorders; snap instantly for size changes/new members
            layoutIcons(animated: orderChanged && !sizeChanged)
        }
    }

    private func slotX(_ idx: Int) -> CGFloat { CGFloat(idx) * slotW }

    private func layoutIcons(animated: Bool) {
        let totalW = max(CGFloat(items.count) * slotW - spacing, 1)
        frame.size = NSSize(width: totalW, height: rowH)
        invalidateIntrinsicContentSize()

        for (idx, item) in items.enumerated() {
            guard let hv = views[item.bundleID] else { continue }
            let target = CGRect(x: slotX(idx), y: 0, width: iconW, height: rowH)
            // The actively dragged icon follows the cursor, not its slot
            if isDragging && item.bundleID == draggingBID {
                hv.frame.size = target.size
                continue
            }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    hv.animator().frame = target
                }
            } else {
                hv.frame = target
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(CGFloat(items.count) * slotW - spacing, 1), height: rowH)
    }

    /// Slot index for a point (arithmetic — views may be mid-animation).
    private func indexAt(_ p: CGPoint) -> Int? {
        guard slotW > 0, p.x >= 0 else { return nil }
        let idx = Int(p.x / slotW)
        return idx < items.count ? idx : nil
    }

    // MARK: Drag via local event monitor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] ev in self?.handle(ev) ?? ev }
        } else if window == nil, let m = monitor {
            NSEvent.removeMonitor(m); monitor = nil
        }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    /// Return the event to let it through to SwiftUI, or nil to swallow it.
    private func handle(_ ev: NSEvent) -> NSEvent? {
        guard let win = window, ev.window === win else { return ev }
        let p = convert(ev.locationInWindow, from: nil)

        switch ev.type {
        case .leftMouseDown:
            if bounds.contains(p), let idx = indexAt(p) {
                draggingBID = items[idx].bundleID
                downX = p.x
                grabOffsetX = p.x - slotX(idx)
                isDragging = false
            } else {
                draggingBID = nil
            }
            return ev   // let SwiftUI register the press so a no-move click taps

        case .leftMouseDragged:
            guard let bid = draggingBID else { return ev }
            if !isDragging {
                guard abs(p.x - downX) > 5 else { return ev }
                isDragging = true
                TaskbarDragState.shared.isReordering = true
                HoverPreviewPanel.shared.hide()
                IconTooltipPanel.shared.hide()
                if let hv = views[bid] {
                    hv.layer?.zPosition = 100   // dragged icon rides above neighbors
                    hv.alphaValue = 0.85
                }
            }
            guard let hv = views[bid] else { return nil }

            // 1:1 cursor tracking, clamped to the row
            hv.frame.origin.x = min(max(p.x - grabOffsetX, 0), frame.width - iconW)

            // Reorder when the dragged icon's center crosses into another slot
            if let curIdx = items.firstIndex(where: { $0.bundleID == bid }) {
                let targetIdx = min(max(Int(hv.frame.midX / slotW), 0), items.count - 1)
                if targetIdx != curIdx {
                    WindowManager.shared.moveItem(fromBundleID: bid, toBundleID: items[targetIdx].bundleID)
                    // moveItem → rebuild → update() animates the neighbors aside
                }
            }
            return nil  // swallow while dragging

        case .leftMouseUp:
            let wasDragging = isDragging
            if wasDragging, let bid = draggingBID, let hv = views[bid] {
                hv.layer?.zPosition = 0
                hv.alphaValue = 1.0
                isDragging = false
                layoutIcons(animated: true)   // snap the dragged icon into its slot
            }
            draggingBID = nil
            isDragging = false
            TaskbarDragState.shared.isReordering = false
            return wasDragging ? nil : ev  // swallow the up after a drag → no tap

        default:
            return ev
        }
    }
}

// MARK: - Task Manager Panel

class TaskManagerPanel {
    static let shared = TaskManagerPanel()
    private var panel: NSPanel?

    func show() {
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.title = "Task Manager"
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: TaskManagerView())
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
}

struct TaskManagerView: View {
    @State private var apps: [NSRunningApplication] = []
    @State private var selected: Set<pid_t> = []
    @ObservedObject private var monitor = ProcessMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Select one or more apps to force quit:")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            // Column header
            HStack(spacing: 10) {
                Text("App").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("CPU").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Text("Memory").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Text("Network").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)

            List(apps, id: \.processIdentifier, selection: $selected) { app in
                let stats = monitor.stats[app.processIdentifier]
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    }
                    Text(app.localizedName ?? "Unknown").font(.system(size: 13))
                    if !app.isFinishedLaunching {
                        Text("Not Responding").font(.system(size: 11)).foregroundColor(.red)
                    }
                    Spacer()
                    Text(stats?.cpuDisplay ?? "—")
                        .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                        .frame(width: 54, alignment: .trailing)
                    Text(stats?.memDisplay ?? "—")
                        .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Text(stats?.netDisplay ?? "—")
                        .font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
            Divider()
            HStack {
                Button("Refresh") { loadApps() }.buttonStyle(.bordered)
                Spacer()
                Button("Force Quit Selected") {
                    selected.forEach { pid in
                        apps.first { $0.processIdentifier == pid }?.forceTerminate()
                    }
                    selected = []
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadApps() }
                }
                .buttonStyle(.borderedProminent).tint(.red).disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .onAppear { loadApps(); ProcessMonitor.shared.start() }
        .onDisappear { ProcessMonitor.shared.stop() }
    }

    private func loadApps() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}
