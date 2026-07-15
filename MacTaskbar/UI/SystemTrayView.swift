import SwiftUI

// Tray now only shows nothing — kept as empty spacer for layout balance
struct SystemTrayView: View {
    var body: some View {
        // Removed: Wi-Fi, speaker, battery, clock, date
        // Just a small right-side padding placeholder
        Color.clear
            .frame(width: 8)
    }
}
