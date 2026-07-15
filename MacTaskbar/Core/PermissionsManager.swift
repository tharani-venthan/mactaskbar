import AppKit
import SwiftUI
import ApplicationServices

class PermissionsManager {
    static let shared = PermissionsManager()

    // Always read live — a stored Bool goes stale the moment the user flips
    // a toggle in System Settings.
    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var allGranted: Bool { hasScreenRecording && hasAccessibility }

    /// Show the system prompt for Accessibility (only fires if not yet granted).
    func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    /// Show the system prompt for Screen Recording (only fires if not yet granted).
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func openPrivacySettings(for type: String) {
        let urlString: String
        switch type {
        case "screen":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case "accessibility":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording only takes effect after the app restarts — relaunch in place.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Onboarding panel
// Shown at launch only when something is missing. Live-updates as the user
// flips toggles in System Settings; offers a relaunch once everything is on.

class PermissionsOnboardingController {
    static let shared = PermissionsOnboardingController()
    private var window: NSWindow?

    func showIfNeeded() {
        guard !PermissionsManager.shared.allGranted else { return }
        if window == nil {
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 420, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "Welcome to MacTaskbar"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PermissionsOnboardingView(
                onDone: { [weak self] in self?.window?.orderOut(nil) }
            ))
            w.center()
            w.level = .floating
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PermissionsOnboardingView: View {
    let onDone: () -> Void
    @State private var hasAX = PermissionsManager.shared.hasAccessibility
    @State private var hasSR = PermissionsManager.shared.hasScreenRecording
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacTaskbar needs two permissions")
                .font(.system(size: 16, weight: .semibold))
            Text("macOS remembers these per app signature. You only need to do this once — they'll survive rebuilds from now on.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                granted: hasAX,
                title: "Accessibility",
                detail: "Required to switch, close, and minimize specific windows.",
                action: {
                    PermissionsManager.shared.requestAccessibility()
                    PermissionsManager.shared.openPrivacySettings(for: "accessibility")
                }
            )
            permissionRow(
                granted: hasSR,
                title: "Screen Recording",
                detail: "Required for live window preview thumbnails.",
                action: {
                    PermissionsManager.shared.requestScreenRecording()
                    PermissionsManager.shared.openPrivacySettings(for: "screen")
                }
            )

            Divider()

            if hasAX && hasSR {
                HStack {
                    Text("All set! Restart to apply Screen Recording.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                    Spacer()
                    Button("Relaunch MacTaskbar") { PermissionsManager.shared.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Tip: if a permission looks ON in System Settings but still shows ✕ here, remove the stale MacTaskbar entry with the − button in Settings, then re-add it.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onReceive(timer) { _ in
            hasAX = PermissionsManager.shared.hasAccessibility
            hasSR = PermissionsManager.shared.hasScreenRecording
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action).buttonStyle(.bordered)
            }
        }
    }
}
