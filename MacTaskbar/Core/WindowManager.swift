import AppKit
import Combine
import Foundation

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let cgBounds: CGRect
    let ownerPID: pid_t
    /// True when discovered via the AX pass (kAXMinimizedAttribute) — these
    /// windows are absent from CGWindowList, so cgBounds is a placeholder and
    /// no live thumbnail capture is possible (only a cached one).
    var isMinimized: Bool = false
}

struct AppGroup: Identifiable, Equatable {
    let id: String // bundleID
    let bundleID: String
    let app: NSRunningApplication
    var windows: [WindowInfo]
    var icon: NSImage? { app.icon }
    var name: String { app.localizedName ?? bundleID }
    var isActive: Bool { app.isActive }
}

/// The central source of truth for what's on the taskbar.
/// Order rule (exactly like Windows 11):
///   1. Pinned apps (in pinned order). If running → show with dot.
///   2. Unpinned running apps — appended after all pinned slots, in launch order.
@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var taskbarItems: [TaskbarItem] = []

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let settings = TaskbarSettings.shared

    // Track launch order for unpinned apps
    private var launchOrder: [String] = [] // bundle IDs in order they appeared

    enum TaskbarItem: Identifiable, Equatable {
        case pinnedOnly(bundleID: String)           // pinned, not running
        case running(group: AppGroup, pinned: Bool) // running (may or may not be pinned)

        var id: String {
            switch self {
            case .pinnedOnly(let b): return "pin_\(b)"
            case .running(let g, _): return "run_\(g.bundleID)"
            }
        }

        var bundleID: String {
            switch self {
            case .pinnedOnly(let b): return b
            case .running(let g, _): return g.bundleID
            }
        }

        var isPinned: Bool {
            switch self {
            case .pinnedOnly: return true
            case .running(_, let p): return p
            }
        }

        var appGroup: AppGroup? {
            if case .running(let g, _) = self { return g }
            return nil
        }

        var icon: NSImage? {
            switch self {
            case .pinnedOnly(let bid):
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
                return nil
            case .running(let g, _):
                return g.icon
            }
        }

        var name: String {
            switch self {
            case .pinnedOnly(let bid):
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    return url.deletingPathExtension().lastPathComponent
                }
                return bid
            case .running(let g, _):
                return g.name
            }
        }

        var windowCount: Int {
            appGroup?.windows.count ?? 0
        }

        var isActive: Bool {
            appGroup?.isActive ?? false
        }

        static func == (lhs: TaskbarItem, rhs: TaskbarItem) -> Bool {
            lhs.id == rhs.id
        }
    }

    private init() {
        startPolling()
        listenToWorkspaceEvents()

        // React to pin changes
        settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuildTaskbarItems() }
            .store(in: &cancellables)
    }

    // MARK: - Polling

    private func startPolling() {
        rebuildTaskbarItems()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildTaskbarItems() }
        }
    }

    private func listenToWorkspaceEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            Task { @MainActor in self?.rebuildTaskbarItems() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bid = app.bundleIdentifier {
                self?.launchOrder.removeAll { $0 == bid }
            }
            Task { @MainActor in self?.rebuildTaskbarItems() }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildTaskbarItems() }
        }
    }

    // MARK: - Core rebuild

    func rebuildTaskbarItems() {
        let runningApps = fetchRunningAppGroups()
        let pinnedIDs = settings.pinnedBundleIDs

        // Update launch order
        for bid in runningApps.keys {
            if !launchOrder.contains(bid) {
                launchOrder.append(bid)
            }
        }

        // Unified free-mix order: pinned and unpinned icons can sit anywhere.
        // Prune entries that are neither pinned nor running (a closed unpinned
        // app disappears and forgets its slot), then append newcomers —
        // pinned first, then running apps in launch order.
        var order = settings.iconOrder.filter { pinnedIDs.contains($0) || runningApps[$0] != nil }
        for bid in pinnedIDs where !order.contains(bid) { order.append(bid) }
        for bid in launchOrder where runningApps[bid] != nil && !order.contains(bid) { order.append(bid) }
        settings.iconOrder = order   // setter no-ops when unchanged (avoids rebuild loop)

        var items: [TaskbarItem] = []
        for bid in order {
            if let group = runningApps[bid] {
                items.append(.running(group: group, pinned: pinnedIDs.contains(bid)))
            } else if pinnedIDs.contains(bid) {
                items.append(.pinnedOnly(bundleID: bid))
            }
        }

        self.taskbarItems = items
    }

    private func fetchRunningAppGroups() -> [String: AppGroup] {
        // Get window list
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [:] }

        // Build pid → windows map
        var pidToWindows: [pid_t: [WindowInfo]] = [:]
        for info in windowList {
            guard
                let layer = info[kCGWindowLayer] as? Int, layer == 0,
                let pid = info[kCGWindowOwnerPID] as? pid_t,
                let windowID = info[kCGWindowNumber] as? CGWindowID
            else { continue }

            let title = info[kCGWindowName] as? String ?? ""
            let boundsDict = info[kCGWindowBounds] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Exclude tiny windows (panels, tooltips)
            if bounds.width < 50 || bounds.height < 50 { continue }

            let winInfo = WindowInfo(id: windowID, title: title, cgBounds: bounds, ownerPID: pid)
            pidToWindows[pid, default: []].append(winInfo)
        }

        // Build bundleID → AppGroup map
        var groups: [String: AppGroup] = [:]
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            guard let bid = app.bundleIdentifier else { continue }
            // Exclude self
            if bid == Bundle.main.bundleIdentifier { continue }

            var windows = pidToWindows[app.processIdentifier] ?? []

            // Pass 2: CGWindowList omits minimized windows entirely, so
            // discover them via the app's AX window list and merge them in.
            let knownIDs = Set(windows.map(\.id))
            for mw in FocusManager.shared.minimizedWindows(pid: app.processIdentifier)
            where !knownIDs.contains(mw.id) {
                windows.append(WindowInfo(
                    id: mw.id,
                    title: mw.title,
                    cgBounds: .zero,   // placeholder — no live bounds while minimized
                    ownerPID: app.processIdentifier,
                    isMinimized: true
                ))
            }

            let group = AppGroup(
                id: bid,
                bundleID: bid,
                app: app,
                windows: windows
            )
            groups[bid] = group
        }

        return groups
    }

    // MARK: - Actions

    /// Reorder an icon by dropping it onto another icon's slot. Any icon can
    /// move anywhere (free mixing) — the unified order is persisted, and a
    /// closed unpinned app simply drops out of it.
    func moveItem(fromBundleID src: String, toBundleID dst: String) {
        guard src != dst else { return }
        var order = settings.iconOrder
        guard let from = order.firstIndex(of: src),
              let to = order.firstIndex(of: dst) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        settings.iconOrder = order
        rebuildTaskbarItems()
    }

    func activateApp(bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func launchOrActivate(bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular
        }) {
            // App is running — activate it
            if app.isActive {
                // Already active — hide it (toggle behavior)
                app.hide()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            // Not running — launch it
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}
