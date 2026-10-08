import SwiftUI
import AppKit

class SettingsPanelController: NSWindowController {
    static let shared = SettingsPanelController()
    private init() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 635),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Taskbar Settings"
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: SettingsView())
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func toggle() {
        if window?.isVisible == true { window?.orderOut(nil) }
        else { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = TaskbarSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Taskbar Settings").font(.system(size: 16, weight: .semibold))

            // Icon size
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Icon Size").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(settings.iconSize.iconPt))pt")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Picker("", selection: $settings.iconSizeRaw) {
                    ForEach(TaskbarSettings.IconSize.allCases, id: \.rawValue) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // Icon position
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon Position").font(.system(size: 13, weight: .medium))
                Picker("", selection: $settings.iconPositionRaw) {
                    ForEach(TaskbarSettings.IconPosition.allCases, id: \.rawValue) { p in
                        Text(p.rawValue).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // Appearance
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.system(size: 13, weight: .medium))
                Picker("", selection: $settings.appearanceModeRaw) {
                    ForEach(TaskbarSettings.AppearanceMode.allCases, id: \.rawValue) { m in
                        Text(m.rawValue).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // Start menu style
            VStack(alignment: .leading, spacing: 6) {
                Text("Start Menu Style").font(.system(size: 13, weight: .medium))
                Picker("", selection: $settings.startStyleRaw) {
                    ForEach(TaskbarSettings.StartStyle.allCases, id: \.rawValue) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // Accent bar color
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Accent Bar Color").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Capsule().fill(settings.accentBarColor).frame(width: 18, height: 4)
                }
                Picker("", selection: $settings.accentBarStyleRaw) {
                    ForEach(TaskbarSettings.AccentBarStyle.allCases, id: \.rawValue) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            // Toggles
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-hide taskbar", isOn: $settings.autoHide)
                    .font(.system(size: 13))
                Toggle("Show clock", isOn: $settings.showClock)
                    .font(.system(size: 13))
                Toggle("Green button maximizes above the taskbar", isOn: $settings.greenButtonMaximizes)
                    .font(.system(size: 13))
                Text("Off: the green button enters macOS full screen, where the taskbar hides.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            // Start menu hotkey
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Start Menu Shortcut").font(.system(size: 13, weight: .medium))
                HStack {
                    HotkeyRecorderButton()
                    Spacer()
                    Button("Reset") {
                        settings.startHotkeyKeyCode = 53
                        settings.startHotkeyModifiers = Int(NSEvent.ModifierFlags.control.rawValue)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text("Click the box, then press the key combination you want.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 635)
    }
}

// MARK: - Hotkey recorder

struct HotkeyRecorderButton: View {
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { isRecording ? stopRecording() : startRecording() }) {
            Text(isRecording ? "Press keys…" : settings.startHotkeyDisplayString)
                .font(.system(size: 13, weight: .medium).monospaced())
                .foregroundColor(isRecording ? .orange : .primary)
                .frame(minWidth: 110)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.orange : Color.secondary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    // .function was previously excluded from the captured modifier set, so
    // Fn-combos (e.g. Fn+F) silently lost their Fn bit when saved. Option was
    // already captured correctly via keyDown — dead-key composition (e.g.
    // Option+E) only delays the *character*, not keyCode/modifierFlags, which
    // is all this recorder reads.
    private static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            // Plain Escape cancels recording
            let mods = event.modifierFlags.intersection(Self.modifierMask)
            if event.keyCode == 53 && mods.isEmpty { return nil }
            settings.startHotkeyKeyCode = Int(event.keyCode)
            settings.startHotkeyModifiers = Int(mods.rawValue)
            return nil  // swallow the keystroke
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
