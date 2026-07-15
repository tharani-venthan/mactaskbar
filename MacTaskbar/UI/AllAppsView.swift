import SwiftUI
import AppKit

struct AllApp: Identifiable {
    let id: String // path
    let name: String
    let url: URL
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

struct AllAppsView: View {
    @Binding var isShowing: Bool
    @State private var apps: [AllApp] = []
    @State private var searchText = ""

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
        grouped.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isShowing = false } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))

                Spacer()

                Text("All Apps")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .font(.system(size: 13))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.15))

            // App list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sortedKeys, id: \.self) { key in
                        Section {
                            ForEach(grouped[key] ?? []) { app in
                                AppRowView(app: app)
                            }
                        } header: {
                            Text(key)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3))
                        }
                    }
                }
            }
        }
        .onAppear { loadApps() }
    }

    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AllApp] = []
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]

            for dir in dirs {
                let url = URL(fileURLWithPath: dir)
                guard let items = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil
                ) else { continue }

                for item in items where item.pathExtension == "app" {
                    let name = item.deletingPathExtension().lastPathComponent
                    found.append(AllApp(id: item.path, name: name, url: item))
                }
            }

            let sorted = found.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self.apps = sorted }
        }
    }
}

struct AppRowView: View {
    let app: AllApp
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            Text(app.name)
                .font(.system(size: 13))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
