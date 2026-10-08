import SwiftUI
import AppKit

// MARK: - Search result types

enum SearchResult: Identifiable {
    case app(name: String, url: URL, icon: NSImage?)
    case file(name: String, url: URL, icon: NSImage?)

    var id: String {
        switch self {
        case .app(let n, let u, _): return "app_\(u.path)"
        case .file(let n, let u, _): return "file_\(u.path)"
        }
    }
    var name: String {
        switch self { case .app(let n,_,_): return n; case .file(let n,_,_): return n }
    }
    var url: URL {
        switch self { case .app(_,let u,_): return u; case .file(_,let u,_): return u }
    }
    var icon: NSImage? {
        switch self { case .app(_,_,let i): return i; case .file(_,_,let i): return i }
    }
    var isApp: Bool { if case .app = self { return true }; return false }
}

// MARK: - StartMenuView

struct StartMenuView: View {
    // Not private: the Windows 10 layout (Win10StartView.swift) is an
    // extension of this view and shares its search and launch state.
    @ObservedObject var settings = TaskbarSettings.shared
    @ObservedObject var launcher = AppLaunchTracker.shared
    @State var searchText        = ""
    @State private var showAllApps       = false
    @State var searchResults: [SearchResult] = []
    @State var isSearching       = false
    @State var selectedResultIdx = -1   // -1 = none selected
    @State var installedApps: [AllApp] = []
    @State var railExpanded = false

    let onDismiss: () -> Void

    var tint: Color { StartMenuStyle.tint(settings.isLightMode) }
    private var isWin10: Bool { settings.startStyle == .windows10 }

    var body: some View {
        ZStack {
            // Windows 11 acrylic: blur underneath, near-opaque neutral tint on top
            if isWin10 {
                // Windows 10 acrylic is far more see-through than 11's Mica
                AcrylicBlur(light: settings.isLightMode)
                StartMenuStyle.acrylic(settings.isLightMode)
            } else {
                VisualEffectBlur(material: settings.taskbarMaterial, blendingMode: .behindWindow)
                StartMenuStyle.surface(settings.isLightMode)
            }

            if isWin10 {
                win10Content
            } else if showAllApps {
                AllAppsView(isShowing: $showAllApps)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if !searchText.isEmpty {
                searchResultsView
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showAllApps)
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
        // The panel's own window shadow follows this shape; a SwiftUI shadow
        // here would just be clipped by the window bounds.
        .clipShape(RoundedRectangle(cornerRadius: isWin10 ? 0 : StartMenuStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: isWin10 ? 0 : StartMenuStyle.cornerRadius)
            .strokeBorder(tint.opacity(isWin10 ? 0.07 : 0.12), lineWidth: 1))
        .onChange(of: searchText) { query in
            selectedResultIdx = -1
            guard !query.isEmpty else { searchResults = []; return }
            performSearch(query: query)
        }
    }

    // MARK: - Spotlight-style search results

    var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBarWithHandlers.padding(.horizontal, StartMenuStyle.inset).padding(.top, 28).padding(.bottom, 12)

            if isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
            } else if searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                // Apps section
                let apps  = searchResults.filter { $0.isApp }
                let files = searchResults.filter { !$0.isApp }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !apps.isEmpty {
                            SectionLabel(title: "Applications")
                            ForEach(Array(apps.prefix(6).enumerated()), id: \.offset) { i, r in
                                SearchResultRow(
                                    result: r,
                                    isSelected: selectedResultIdx == i,
                                    onOpen: { open(result: r) }
                                )
                            }
                        }
                        if !files.isEmpty {
                            SectionLabel(title: "Files & Folders")
                            ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { i, r in
                                SearchResultRow(
                                    result: r,
                                    isSelected: selectedResultIdx == (apps.prefix(6).count + i),
                                    onOpen: { open(result: r) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, StartMenuStyle.inset - 12)
                    .padding(.bottom, 12)
                }
            }
            Spacer(minLength: 0)
            bottomBar
        }
    }

    // MARK: - Main pinned content

    var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBarWithHandlers
                .padding(.horizontal, StartMenuStyle.inset).padding(.top, 28).padding(.bottom, 24)

            HStack {
                StartSectionTitle("Pinned")
                Spacer()
                StartChipButton(title: "All apps", chevron: .trailing) { showAllApps = true }
            }
            .padding(.horizontal, StartMenuStyle.inset + 12).padding(.bottom, 14)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 4) {
                ForEach(settings.startPinnedBundleIDs, id: \.self) { bid in
                    PinnedAppCell(bundleID: bid, onLaunch: {
                        launchApp(bundleID: bid); onDismiss()
                    })
                }
            }
            .padding(.horizontal, StartMenuStyle.inset)

            if !launcher.recentApps.isEmpty {
                StartSectionTitle("Recommended")
                    .padding(.horizontal, StartMenuStyle.inset + 12).padding(.top, 28).padding(.bottom, 12)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 4) {
                    ForEach(launcher.recentApps.prefix(6)) { r in
                        RecentAppRow(recent: r, onLaunch: {
                            launchApp(bundleID: r.bundleID); onDismiss()
                        })
                    }
                }
                .padding(.horizontal, StartMenuStyle.inset)
            }

            Spacer(minLength: 0)
            bottomBar
        }
    }

    var searchBarWithHandlers: some View {
        searchBarFields
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(tint.opacity(0.06)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.14), lineWidth: 1))
    }

    /// The search field itself, without chrome — each Start style frames it.
    var searchBarFields: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(tint.opacity(0.75)).font(.system(size: 13))
            SearchField(
                text: $searchText,
                placeholder: isWin10 ? "Type here to search" : "Search for apps, settings, and documents",
                onArrowDown: {
                    let max = searchResults.count - 1
                    selectedResultIdx = min(selectedResultIdx + 1, max)
                },
                onArrowUp: {
                    selectedResultIdx = max(selectedResultIdx - 1, -1)
                },
                onReturn: {
                    if selectedResultIdx >= 0 && selectedResultIdx < searchResults.count {
                        open(result: searchResults[selectedResultIdx])
                    } else if let first = searchResults.first {
                        open(result: first)
                    }
                }
            )
            .frame(height: 20)
            if !searchText.isEmpty {
                Button(action: { searchText = ""; selectedResultIdx = -1 }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary).font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    var bottomBar: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(tint.opacity(0.8))
                Text(NSFullUserName())
                    .font(.system(size: 12))
                    .foregroundColor(tint)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .startHover(radius: 4)
            Spacer()
            Button(action: { onDismiss() }) {
                Image(systemName: "power")
                    .font(.system(size: 15))
                    .foregroundColor(tint.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .startHover(radius: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, StartMenuStyle.inset + 2)
        .frame(height: 64)
        .background(Color.black.opacity(settings.isLightMode ? 0.04 : 0.22))
        .overlay(Rectangle().fill(tint.opacity(0.08)).frame(height: 1), alignment: .top)
    }

    // MARK: - Search logic (Spotlight-style using NSMetadataQuery)

    private func performSearch(query: String) {
        isSearching = true
        searchResults = []

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [SearchResult] = []

            // 1. Search installed apps
            let appDirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            for dir in appDirs {
                guard let items = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil
                ) else { continue }
                for url in items where url.pathExtension == "app" {
                    let name = url.deletingPathExtension().lastPathComponent
                    if name.localizedCaseInsensitiveContains(query) {
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        results.append(.app(name: name, url: url, icon: icon))
                    }
                }
            }

            // 2. Search recent + home directory files via NSMetadataQuery (sync wrapper)
            let metaResults = searchFiles(query: query)
            results.append(contentsOf: metaResults)

            // Sort apps first, then files; alphabetical within each
            results.sort {
                if $0.isApp != $1.isApp { return $0.isApp }
                return $0.name < $1.name
            }

            DispatchQueue.main.async {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func searchFiles(query: String) -> [SearchResult] {
        var found: [SearchResult] = []
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let searchDirs = [
            homeURL.appendingPathComponent("Desktop"),
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent("Downloads"),
        ]
        let fm = FileManager.default
        for dir in searchDirs {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var count = 0
            for case let url as URL in enumerator {
                guard count < 50 else { break }
                let name = url.deletingPathExtension().lastPathComponent
                if name.localizedCaseInsensitiveContains(query) {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    found.append(.file(name: name, url: url, icon: icon))
                    count += 1
                }
            }
        }
        return found
    }

    func open(result: SearchResult) {
        switch result {
        case .app(_, let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .file(_, let url, _):
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }

    func launchApp(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let title: String
    @ObservedObject private var settings = TaskbarSettings.shared
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }
}

// MARK: - Search result row

struct SearchResultRow: View {
    let result: SearchResult
    var isSelected: Bool = false
    let onOpen: () -> Void
    @State private var isHovered = false
    @ObservedObject private var settings = TaskbarSettings.shared

    var highlighted: Bool { isSelected || isHovered }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = result.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: result.isApp ? "app" : "doc")
                    .font(.system(size: 20)).foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(settings.isLightMode ? .black : .white)
                Text(result.isApp
                     ? "Application"
                     : result.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            if result.isApp {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted
                      ? Color(settings.isLightMode ? .black : .white).opacity(isSelected ? 0.14 : 0.08)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onOpen() }
    }
}

// MARK: - NSTextField wrapper for search

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onArrowDown: (() -> Void)? = nil
    var onArrowUp:   (() -> Void)? = nil
    var onReturn:    (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.isBordered = false
        f.backgroundColor = .clear
        f.textColor = .labelColor
        f.font = .systemFont(ofSize: 13)
        f.focusRingType = .none
        f.delegate = context.coordinator
        f.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.placeholderTextColor]
        )
        return f
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Auto-focus: place cursor at END (not select-all) so first char isn't overwritten
        DispatchQueue.main.async {
            guard let window = nsView.window, window.isKeyWindow else { return }
            if nsView.currentEditor() == nil {
                window.makeFirstResponder(nsView)
                // Move insertion point to end of text
                if let editor = nsView.currentEditor() as? NSTextView {
                    let end = editor.string.endIndex
                    let nsEnd = editor.string.distance(
                        from: editor.string.startIndex, to: end)
                    editor.selectedRange = NSRange(location: nsEnd, length: 0)
                }
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField {
                parent.text = f.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                (control as? NSTextField)?.stringValue = ""
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)) {
                parent.onArrowDown?()
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                parent.onArrowUp?()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onReturn?()
                return true
            }
            return false
        }
    }
}

// MARK: - Pinned cell

struct PinnedAppCell: View {
    let bundleID: String
    let onLaunch: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false
    @State private var icon: NSImage?

    var name: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }
    var body: some View {
        VStack(spacing: 8) {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 36, height: 36) }
            else { RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
                .frame(width: 36, height: 36) }
            Text(name).font(.system(size: 12))
                .foregroundColor(StartMenuStyle.tint(settings.isLightMode))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity).frame(height: 84)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(StartMenuStyle.tint(settings.isLightMode).opacity(isHovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }.onTapGesture { onLaunch() }
        .contextMenu {
            Button("Unpin from Start") { settings.unpinFromStart(bundleID: bundleID) }
            Button(settings.isPinned(bundleID) ? "Unpin from Taskbar" : "Pin to Taskbar") {
                if settings.isPinned(bundleID) { settings.unpin(bundleID: bundleID) }
                else { settings.pin(bundleID: bundleID) }
            }
        }
        .onAppear {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

// MARK: - Recent row

struct RecentAppRow: View {
    let recent: RecentApp
    let onLaunch: () -> Void
    @State private var isHovered = false
    @ObservedObject private var settings = TaskbarSettings.shared

    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: recent.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    var timeAgo: String {
        let d = Date().timeIntervalSince(recent.date)
        if d < 60 { return "Just now" }
        if d < 3600 { return "\(Int(d/60))m ago" }
        if d < 86400 { return "\(Int(d/3600))h ago" }
        return "\(Int(d/86400))d ago"
    }
    var body: some View {
        HStack(spacing: 12) {
            if let i = icon { Image(nsImage: i).resizable().interpolation(.high).frame(width: 32, height: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name).font(.system(size: 12, weight: .medium))
                    .foregroundColor(StartMenuStyle.tint(settings.isLightMode)).lineLimit(1)
                Text(timeAgo).font(.system(size: 11))
                    .foregroundColor(StartMenuStyle.tint(settings.isLightMode).opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 56)
        .startHover(radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { onLaunch() }
    }
}

// MARK: - Shared Start menu styling

enum StartMenuStyle {
    static let cornerRadius: CGFloat = 8
    /// Horizontal inset of the content column (Windows 11 uses a wide margin).
    static let inset: CGFloat = 28

    static func tint(_ light: Bool) -> Color { light ? .black : .white }
    static func acrylic(_ light: Bool) -> Color {
        light ? Color(red: 0.93, green: 0.93, blue: 0.93).opacity(0.62)
              : Color(red: 0.10, green: 0.10, blue: 0.10).opacity(0.58)
    }
    static func surface(_ light: Bool) -> Color {
        light ? Color(red: 0.95, green: 0.95, blue: 0.95).opacity(0.86)
              : Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.84)
    }
}

struct StartSectionTitle: View {
    let title: String
    @ObservedObject private var settings = TaskbarSettings.shared
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(StartMenuStyle.tint(settings.isLightMode))
    }
}

/// The small bordered "All apps ›" / "‹ Back" button.
struct StartChipButton: View {
    enum Chevron { case leading, trailing }
    let title: String
    let chevron: Chevron
    let action: () -> Void
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false

    var body: some View {
        let tint = StartMenuStyle.tint(settings.isLightMode)
        Button(action: action) {
            HStack(spacing: 6) {
                if chevron == .leading { Image(systemName: "chevron.left").font(.system(size: 8, weight: .semibold)) }
                Text(title).font(.system(size: 12))
                if chevron == .trailing { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(isHovered ? 0.11 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.09), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct StartHover: ViewModifier {
    let radius: CGFloat
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false
    init(radius: CGFloat) { self.radius = radius }
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(StartMenuStyle.tint(settings.isLightMode).opacity(isHovered ? 0.08 : 0)))
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Windows 11's subtle rounded hover plate.
    func startHover(radius: CGFloat) -> some View { modifier(StartHover(radius: radius)) }
}
