import AppKit
import Foundation

struct RecentApp: Codable, Identifiable {
    let id: String // bundleID
    let bundleID: String
    let name: String
    let date: Date
}

class AppLaunchTracker: ObservableObject {
    static let shared = AppLaunchTracker()
    @Published var recentApps: [RecentApp] = []

    private let maxRecent = 8
    private let key = "recentApps"

    private init() {
        load()
        listenForLaunches()
    }

    private func listenForLaunches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  let name = app.localizedName else { return }
            self?.record(bundleID: bid, name: name)
        }
    }

    func record(bundleID: String, name: String) {
        var apps = recentApps.filter { $0.bundleID != bundleID }
        apps.insert(RecentApp(id: bundleID, bundleID: bundleID, name: name, date: Date()), at: 0)
        recentApps = Array(apps.prefix(maxRecent))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recentApps) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let apps = try? JSONDecoder().decode([RecentApp].self, from: data) {
            recentApps = apps
        }
    }
}
