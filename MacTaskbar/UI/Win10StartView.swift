import SwiftUI
import AppKit

// Windows 10 Start layout: icon rail · alphabetical app list · live-tile grid,
// on a square, flush-to-the-bar acrylic sheet. Lives as an extension so it
// shares StartMenuView's search field, results and launch helpers.

enum Win10Start {
    static let railWidth: CGFloat = 48
    static let listWidth: CGFloat = 272
    static let tile: CGFloat = 100
    static let tileGap: CGFloat = 4
    static let tilesWidth = tile * 3 + tileGap * 2 + 32
    static let width = railWidth + listWidth + tilesWidth
}

extension StartMenuView {
    var win10Content: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                win10List.frame(width: Win10Start.listWidth)
                win10Tiles.frame(width: Win10Start.tilesWidth)
            }
            .padding(.leading, Win10Start.railWidth)

            // The rail overlays the list when expanded, like the hamburger in Windows 10
            Win10Rail(expanded: $railExpanded, onDismiss: onDismiss)
        }
        .onAppear {
            guard installedApps.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = AllApp.loadInstalled()
                DispatchQueue.main.async { installedApps = apps }
            }
        }
    }

    // MARK: App list column

    private var win10List: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBarFields
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Rectangle().fill(tint.opacity(0.08)))
                .overlay(Rectangle().strokeBorder(tint.opacity(0.18), lineWidth: 1))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            if !searchText.isEmpty {
                win10SearchResults
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !launcher.recentApps.isEmpty {
                            Win10ListHeader(title: "Recent")
                            ForEach(launcher.recentApps.prefix(3)) { recent in
                                Win10AppRow(name: recent.name, bundleID: recent.bundleID,
                                            icon: Self.icon(bundleID: recent.bundleID)) {
                                    launchApp(bundleID: recent.bundleID); onDismiss()
                                }
                            }
                        }
                        ForEach(win10Sections, id: \.key) { section in
                            Win10ListHeader(title: section.key)
                            ForEach(section.apps) { app in
                                Win10AppRow(name: app.name,
                                            bundleID: Bundle(url: app.url)?.bundleIdentifier,
                                            icon: app.icon) {
                                    NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
                                    onDismiss()
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var win10SearchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(20)
                } else if searchResults.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 12)).foregroundColor(tint.opacity(0.6))
                        .padding(.horizontal, 16).padding(.top, 12)
                } else {
                    // Same order as searchResults (apps first), so the arrow-key
                    // selection index lines up row for row.
                    ForEach(Array(searchResults.prefix(14).enumerated()), id: \.offset) { i, result in
                        SearchResultRow(result: result, isSelected: selectedResultIdx == i,
                                        onOpen: { open(result: result) })
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Installed apps grouped under their first letter; anything else under "#".
    private var win10Sections: [(key: String, apps: [AllApp])] {
        let groups = Dictionary(grouping: installedApps) { app -> String in
            guard let first = app.name.first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        return groups.keys
            .sorted { a, b in a == "#" ? b != "#" : (b != "#" && a.localizedCaseInsensitiveCompare(b) == .orderedAscending) }
            .map { (key: $0, apps: groups[$0] ?? []) }
    }

    // MARK: Tile column

    private var win10Tiles: some View {
        let pinned = settings.startPinnedBundleIDs
        let recents = launcher.recentApps.map(\.bundleID).filter { !pinned.contains($0) }.prefix(6)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Win10TileGroup(title: "Pinned", bundleIDs: pinned) { launchApp(bundleID: $0); onDismiss() }
                if !recents.isEmpty {
                    Win10TileGroup(title: "Recent", bundleIDs: Array(recents)) { launchApp(bundleID: $0); onDismiss() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }
    }

    static func icon(bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

// MARK: - Rail

private struct Win10Rail: View {
    @Binding var expanded: Bool
    let onDismiss: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        let light = settings.isLightMode
        VStack(alignment: .leading, spacing: 0) {
            item("line.3.horizontal", expanded ? "START" : "", bold: true) {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }
            Spacer(minLength: 0)
            item("person.crop.circle", NSFullUserName()) {}
            item("doc", "Documents") { openFolder(.documentDirectory) }
            item("photo", "Pictures") { openFolder(.picturesDirectory) }
            item("gearshape", "Settings") { onDismiss(); SettingsPanelController.shared.toggle() }
            item("power", "Power") { onDismiss() }
        }
        .frame(width: expanded ? 220 : Win10Start.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(expanded
                    ? AnyView((light ? Color(white: 0.93) : Color(white: 0.14)).shadow(color: .black.opacity(0.35), radius: 8, x: 2))
                    : AnyView(Color.clear))
        .clipped()
    }

    private func item(_ symbol: String, _ label: String, bold: Bool = false, action: @escaping () -> Void) -> some View {
        Win10RailItem(symbol: symbol, label: label, bold: bold, showLabel: expanded, action: action)
    }

    private func openFolder(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }
}

private struct Win10RailItem: View {
    let symbol: String
    let label: String
    let bold: Bool
    let showLabel: Bool
    let action: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false

    var body: some View {
        let tint = StartMenuStyle.tint(settings.isLightMode)
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: Win10Start.railWidth, height: 48)
            if showLabel {
                Text(label).font(.system(size: 13, weight: bold ? .semibold : .regular)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(tint)
        .background(tint.opacity(isHovered ? 0.12 : 0))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .help(label)
    }
}

// MARK: - List pieces

private struct Win10ListHeader: View {
    let title: String
    @ObservedObject private var settings = TaskbarSettings.shared
    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundColor(StartMenuStyle.tint(settings.isLightMode).opacity(0.9))
            .padding(.leading, 16)
            .frame(height: 36)
    }
}

private struct Win10AppRow: View {
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let action: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false

    var body: some View {
        let tint = StartMenuStyle.tint(settings.isLightMode)
        HStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "app").resizable().foregroundColor(tint.opacity(0.5)) }
            }
            .frame(width: 26, height: 26)
            Text(name).font(.system(size: 13)).foregroundColor(tint).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 38)
        .background(tint.opacity(isHovered ? 0.12 : 0))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
        .contextMenu {
            if let bundleID {
                Button(settings.isPinnedToStart(bundleID) ? "Unpin from Start" : "Pin to Start") {
                    if settings.isPinnedToStart(bundleID) { settings.unpinFromStart(bundleID: bundleID) }
                    else { settings.pinToStart(bundleID: bundleID) }
                }
                Button(settings.isPinned(bundleID) ? "Unpin from Taskbar" : "Pin to Taskbar") {
                    if settings.isPinned(bundleID) { settings.unpin(bundleID: bundleID) }
                    else { settings.pin(bundleID: bundleID) }
                }
            }
        }
    }
}

// MARK: - Tiles

private struct Win10TileGroup: View {
    let title: String
    let bundleIDs: [String]
    let onLaunch: (String) -> Void
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(StartMenuStyle.tint(settings.isLightMode).opacity(0.9))
                .frame(height: 36)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Win10Start.tile), spacing: Win10Start.tileGap), count: 3),
                      alignment: .leading, spacing: Win10Start.tileGap) {
                ForEach(bundleIDs, id: \.self) { bid in
                    Win10Tile(bundleID: bid) { onLaunch(bid) }
                }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct Win10Tile: View {
    let bundleID: String
    let onLaunch: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false
    @State private var isPressed = false

    private var name: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }

    var body: some View {
        let tint = StartMenuStyle.tint(settings.isLightMode)
        ZStack(alignment: .bottomLeading) {
            // Translucent plate — the acrylic behind shows through, as on Windows 10
            Rectangle().fill(tint.opacity(isHovered ? 0.17 : 0.11))
            Group {
                if let icon = StartMenuView.icon(bundleID: bundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app").resizable().foregroundColor(tint.opacity(0.5))
                }
            }
            .frame(width: 44, height: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -6)
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(tint)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.bottom, 6)
        }
        .frame(width: Win10Start.tile, height: Win10Start.tile)
        .overlay(Rectangle().strokeBorder(tint.opacity(isHovered ? 0.45 : 0), lineWidth: 2))
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 20, perform: {}, onPressingChanged: { isPressed = $0 })
        .simultaneousGesture(TapGesture().onEnded(onLaunch))
        .contextMenu {
            if settings.isPinnedToStart(bundleID) {
                Button("Unpin from Start") { settings.unpinFromStart(bundleID: bundleID) }
            } else {
                Button("Pin to Start") { settings.pinToStart(bundleID: bundleID) }
            }
            Button(settings.isPinned(bundleID) ? "Unpin from Taskbar" : "Pin to Taskbar") {
                if settings.isPinned(bundleID) { settings.unpin(bundleID: bundleID) }
                else { settings.pin(bundleID: bundleID) }
            }
        }
    }
}

/// Square-cornered behind-window blur (VisualEffectBlur rounds its layer).
struct AcrylicBlur: NSViewRepresentable {
    let light: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = .fullScreenUI
        v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}
