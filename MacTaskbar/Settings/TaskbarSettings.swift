import SwiftUI
import AppKit
import Combine

class TaskbarSettings: ObservableObject {
    static let shared = TaskbarSettings()

    enum IconSize: String, CaseIterable {
        case xs     = "XS"
        case small  = "S"
        case medium = "M"
        case large  = "L"
        case xl     = "XL"

        var iconPt: CGFloat {
            switch self {
            case .xs: return 24; case .small: return 32
            case .medium: return 40; case .large: return 48; case .xl: return 56
            }
        }
        var taskbarHeight: CGFloat {
            switch self {
            case .xs: return 38; case .small: return 48
            case .medium: return 58; case .large: return 66; case .xl: return 76
            }
        }
    }

    enum IconPosition: String, CaseIterable {
        case left = "Left"; case center = "Center"
    }

    enum AppearanceMode: String, CaseIterable {
        case dark = "Dark"; case light = "Light"; case system = "System"
    }

    enum StartStyle: String, CaseIterable {
        case windows11 = "Windows 11"; case windows10 = "Windows 10"
    }

    enum AccentBarStyle: String, CaseIterable {
        case system = "System"; case windowsBlue = "Windows Blue"
    }

    @AppStorage("iconSize")       var iconSizeRaw: String       = IconSize.medium.rawValue
    @AppStorage("iconPosition")   var iconPositionRaw: String   = IconPosition.left.rawValue
    @AppStorage("autoHide")       var autoHide: Bool            = false
    @AppStorage("startStyle")     var startStyleRaw: String     = StartStyle.windows10.rawValue
    @AppStorage("showClock")      var showClock: Bool           = true
    /// Green title-bar button fills the area above the taskbar (Windows-style
    /// maximize) instead of entering a native full-screen Space.
    @AppStorage("greenButtonMaximizes") var greenButtonMaximizes: Bool = true
    @AppStorage("appearanceMode") var appearanceModeRaw: String = AppearanceMode.dark.rawValue
    @AppStorage("accentBarStyle") var accentBarStyleRaw: String = AccentBarStyle.system.rawValue
    @AppStorage("pinnedApps")     private var pinnedAppsData: Data = Data()
    @AppStorage("startPinnedApps") private var startPinnedAppsData: Data = Data()
    @AppStorage("iconOrder")      private var iconOrderData: Data = Data()

    // Start menu hotkey (default: Ctrl+Esc, like the Windows key era)
    @AppStorage("startHotkeyKeyCode")   var startHotkeyKeyCode: Int = 53 // Esc
    @AppStorage("startHotkeyModifiers") var startHotkeyModifiers: Int = Int(NSEvent.ModifierFlags.control.rawValue)

    var iconSize: IconSize {
        get { IconSize(rawValue: iconSizeRaw) ?? .medium }
        set { iconSizeRaw = newValue.rawValue }
    }
    var iconPosition: IconPosition {
        get { IconPosition(rawValue: iconPositionRaw) ?? .left }
        set { iconPositionRaw = newValue.rawValue }
    }
    var startStyle: StartStyle {
        get { StartStyle(rawValue: startStyleRaw) ?? .windows10 }
        set { startStyleRaw = newValue.rawValue }
    }
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .dark }
        set { appearanceModeRaw = newValue.rawValue }
    }

    // Taskbar colours based on mode
    var taskbarBgOpacity: Double {
        switch appearanceMode {
        case .dark: return 0.55
        case .light: return 0.35
        case .system: return 0.45
        }
    }
    var taskbarMaterial: NSVisualEffectView.Material {
        isLightMode ? .sheet : .hudWindow
    }
    var isLightMode: Bool {
        switch appearanceMode {
        case .light:  return true
        case .dark:   return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
    }

    var accentBarStyle: AccentBarStyle {
        get { AccentBarStyle(rawValue: accentBarStyleRaw) ?? .system }
        set { accentBarStyleRaw = newValue.rawValue }
    }
    /// Color of the focused-app underline bar.
    var accentBarColor: Color {
        switch accentBarStyle {
        case .system:      return Color(nsColor: .controlAccentColor)
        case .windowsBlue: return Color(red: 0/255, green: 120/255, blue: 212/255) // #0078D4
        }
    }

    /// Unified taskbar icon order (bundle IDs) — pinned and unpinned mixed
    /// freely. WindowManager prunes entries that are neither pinned nor
    /// running and appends newcomers.
    var iconOrder: [String] {
        get { (try? JSONDecoder().decode([String].self, from: iconOrderData)) ?? [] }
        set {
            guard newValue != iconOrder else { return }
            if let data = try? JSONEncoder().encode(newValue) {
                iconOrderData = data
                objectWillChange.send()
            }
        }
    }

    var startHotkeyDisplayString: String {
        var s = ""
        let mods = NSEvent.ModifierFlags(rawValue: UInt(startHotkeyModifiers))
        if mods.contains(.function) { s += "fn" }
        if mods.contains(.control)  { s += "⌃" }
        if mods.contains(.option)   { s += "⌥" }
        if mods.contains(.shift)    { s += "⇧" }
        if mods.contains(.command)  { s += "⌘" }
        return s + Self.keyName(forKeyCode: startHotkeyKeyCode)
    }

    static func keyName(forKeyCode code: Int) -> String {
        let names: [Int: String] = [
            53: "Esc", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9"
        ]
        return names[code] ?? "Key \(code)"
    }

    /// Apps pinned to the taskbar. Independent from `startPinnedBundleIDs` —
    /// an app can be pinned to either, both, or neither, like real Windows 11.
    var pinnedBundleIDs: [String] {
        get { (try? JSONDecoder().decode([String].self, from: pinnedAppsData)) ?? defaultPins() }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                pinnedAppsData = data
                objectWillChange.send()
            }
        }
    }

    /// Apps pinned in the Start menu's "Pinned" grid.
    var startPinnedBundleIDs: [String] {
        get { (try? JSONDecoder().decode([String].self, from: startPinnedAppsData)) ?? defaultPins() }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                startPinnedAppsData = data
                objectWillChange.send()
            }
        }
    }

    private func defaultPins() -> [String] {
        ["com.apple.finder","com.apple.Safari","com.apple.mail",
         "com.apple.Notes","com.apple.systempreferences"]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    // MARK: Taskbar pins
    func pin(bundleID: String) {
        var p = pinnedBundleIDs
        if !p.contains(bundleID) { p.append(bundleID) }
        pinnedBundleIDs = p
    }
    func unpin(bundleID: String) { pinnedBundleIDs = pinnedBundleIDs.filter { $0 != bundleID } }
    func isPinned(_ bundleID: String) -> Bool { pinnedBundleIDs.contains(bundleID) }
    func movePinnedApp(from: IndexSet, to: Int) {
        var p = pinnedBundleIDs; p.move(fromOffsets: from, toOffset: to); pinnedBundleIDs = p
    }

    // MARK: Start menu pins
    func pinToStart(bundleID: String) {
        var p = startPinnedBundleIDs
        if !p.contains(bundleID) { p.append(bundleID) }
        startPinnedBundleIDs = p
    }
    func unpinFromStart(bundleID: String) {
        startPinnedBundleIDs = startPinnedBundleIDs.filter { $0 != bundleID }
    }
    func isPinnedToStart(_ bundleID: String) -> Bool { startPinnedBundleIDs.contains(bundleID) }
}
