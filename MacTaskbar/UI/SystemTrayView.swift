import SwiftUI
import AppKit

// Windows 11 clock: time over date, right-aligned at the trailing edge.
// Wi-Fi/volume/battery are intentionally left to the macOS menu bar.
struct SystemTrayView: View {
    @ObservedObject private var settings = TaskbarSettings.shared
    @State private var isHovered = false

    var body: some View {
        if settings.showClock {
            let size = settings.iconSize
            let tint: Color = settings.isLightMode ? .black : .white
            let fontSize = min(12, max(10, size.taskbarHeight * 0.24))
            TimelineView(.everyMinute) { context in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                    Text(context.date.formatted(date: .numeric, time: .omitted))
                }
                .font(.system(size: fontSize))
                .foregroundColor(tint.opacity(0.92))
                .padding(.horizontal, 8)
                .frame(height: size.taskbarHeight - 8)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(isHovered ? 0.09 : 0)))
            }
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            .help(Date().formatted(date: .complete, time: .omitted))
        }
    }
}
