import SwiftUI
import AppKit

struct AllApp: Identifiable {
    let id: String // path
    let name: String
    let url: URL
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// Every .app in the standard application folders, sorted by name.
    static func loadInstalled() -> [AllApp] {
        var found: [AllApp] = []
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil
            ) else { continue }
            for item in items where item.pathExtension == "app" {
                found.append(AllApp(id: item.path, name: item.deletingPathExtension().lastPathComponent, url: item))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AllAppsView: View {
    @Binding var isShowing: Bool
    @State private var apps: [AllApp] = []
    @State private var searchText = ""
    @ObservedObject private var settings = TaskbarSettings.shared

    var filteredApps: [AllApp] {
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var grouped: [String: [AllApp]] {
        Dictionary(grouping: filteredApps) { app in
            String(app.name.prefix(1)).uppercased()
        }
    }

    var sortedKeys: [String] {
        grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        let tint = StartMenuStyle.tint(settings.isLightMode)
        VStack(spacing: 0) {
            // Search — same capsule as the main Start page
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(tint.opacity(0.75)).font(.system(size: 13))
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(tint)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(tint.opacity(0.06)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, StartMenuStyle.inset).padding(.top, 28).padding(.bottom, 24)

            // Header: title left, Back on the right (where "All apps" was)
            HStack {
                StartSectionTitle("All apps")
                Spacer()
                StartChipButton(title: "Back", chevron: .leading) {
                    withAnimation(.easeInOut(duration: 0.2)) { isShowing = false }
                }
            }
            .padding(.horizontal, StartMenuStyle.inset + 12).padding(.bottom, 10)

            // App list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedKeys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(tint)
                            .frame(width: 28, height: 36)
                            .padding(.leading, 12)
                        ForEach(grouped[key] ?? []) { app in
                            AppRowView(app: app)
                        }
                    }
                }
                .padding(.horizontal, StartMenuStyle.inset)
                .padding(.bottom, 12)
            }
        }
        .onAppear { loadApps() }
    }

    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let sorted = AllApp.loadInstalled()
            DispatchQueue.main.async { self.apps = sorted }
        }
    }
}

struct AppRowView: View {
    let app: AllApp
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable().interpolation(.high)
                .frame(width: 28, height: 28)
            Text(app.name)
                .font(.system(size: 13))
                .foregroundColor(StartMenuStyle.tint(settings.isLightMode))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .startHover(radius: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
