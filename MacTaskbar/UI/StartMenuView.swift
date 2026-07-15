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
    @ObservedObject private var settings = TaskbarSettings.shared
    @ObservedObject private var launcher = AppLaunchTracker.shared
    @State private var searchText        = ""
    @State private var showAllApps       = false
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching       = false
    @State private var selectedResultIdx = -1   // -1 = none selected

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Background — rounded, light/dark aware
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(settings.isLightMode ? .white : .black).opacity(settings.isLightMode ? 0.6 : 0.75))
            VisualEffectBlur(material: settings.taskbarMaterial, blendingMode: .behindWindow)
                .cornerRadius(14)

            if showAllApps {
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
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 8)
        .onChange(of: searchText) { query in
            selectedResultIdx = -1
            guard !query.isEmpty else { searchResults = []; return }
            performSearch(query: query)
        }
    }

    // MARK: - Spotlight-style search results

    var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBarWithHandlers.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

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
                    .padding(.horizontal, 8)
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
            searchBarWithHandlers.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            HStack {
                Text("Pinned")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(settings.isLightMode ? .black : .white)
                Spacer()
                Button(action: { showAllApps = true }) {
                    HStack(spacing: 3) {
                        Text("All apps").font(.system(size: 12))
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .foregroundColor(settings.isLightMode ? .black.opacity(0.6) : .white.opacity(0.7))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color(settings.isLightMode ? .black : .white).opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 6) {
                ForEach(settings.startPinnedBundleIDs, id: \.self) { bid in
                    PinnedAppCell(bundleID: bid, onLaunch: {
                        launchApp(bundleID: bid); onDismiss()
                    })
                }
            }
            .padding(.horizontal, 16)

            Divider().background(Color(settings.isLightMode ? .black : .white).opacity(0.1))
                .padding(.vertical, 10)

            if !launcher.recentApps.isEmpty {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 6)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                    ForEach(launcher.recentApps.prefix(6)) { r in
                        RecentAppRow(recent: r, onLaunch: {
                            launchApp(bundleID: r.bundleID); onDismiss()
                        })
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
            bottomBar
        }
    }

    var searchBarWithHandlers: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary).font(.system(size: 14))
            SearchField(
                text: $searchText,
                placeholder: "Search apps, files, settings...",
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
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(Color(settings.isLightMode ? .black : .white).opacity(0.1)))
    }

    var bottomBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(settings.isLightMode ? .black.opacity(0.7) : .white.opacity(0.75))
                Text(NSFullUserName())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(settings.isLightMode ? .black : .white)
            }
            Spacer()
            Button(action: { onDismiss() }) {
                Image(systemName: "power")
                    .font(.system(size: 15))
                    .foregroundColor(settings.isLightMode ? .black.opacity(0.7) : .white.opacity(0.75))
                    .padding(8)
                    .background(Circle().fill(Color(settings.isLightMode ? .black : .white).opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(settings.isLightMode ? .black : .white).opacity(0.06))
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

    private func open(result: SearchResult) {
        switch result {
        case .app(_, let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .file(_, let url, _):
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }

    private func launchApp(bundleID: String) {
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
        VStack(spacing: 4) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 40, height: 40) }
            else { RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
                .frame(width: 40, height: 40) }
            Text(name).font(.system(size: 10))
                .foregroundColor(settings.isLightMode ? .black.opacity(0.85) : .white.opacity(0.85))
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 68)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isHovered ? Color(settings.isLightMode ? .black : .white).opacity(0.1) : Color.clear))
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
        HStack(spacing: 8) {
            if let i = icon { Image(nsImage: i).resizable().frame(width: 26, height: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name).font(.system(size: 12, weight: .medium))
                    .foregroundColor(settings.isLightMode ? .black : .white).lineLimit(1)
                Text(timeAgo).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isHovered ? Color(settings.isLightMode ? .black : .white).opacity(0.08) : Color.clear)
        .cornerRadius(6).contentShape(Rectangle())
        .onHover { isHovered = $0 }.onTapGesture { onLaunch() }
    }
}
