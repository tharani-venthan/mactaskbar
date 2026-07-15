import SwiftUI
import AppKit

@main
struct MacTaskbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var taskbarController: TaskbarWindowController?
    let windowManager = WindowManager.shared
    let permissionsManager = PermissionsManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (also set LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        // Launch taskbar
        taskbarController = TaskbarWindowController()
        taskbarController?.showWindow(nil)

        // Guide through permissions only if something is missing
        PermissionsOnboardingController.shared.showIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
