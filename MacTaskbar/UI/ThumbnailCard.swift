import SwiftUI
import AppKit

struct ThumbnailCard: View {
    let windowInfo: WindowInfo
    let onFocus: () -> Void
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @State private var isCloseHovered = false

    let cardWidth: CGFloat
    let cardHeight: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail or placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: cardWidth, height: cardHeight)

                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cardWidth, height: cardHeight)
                            .clipped()
                            .cornerRadius(6)
                    } else {
                        ProgressView()
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isHovered ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )

                // Close button
                if isHovered {
                    Button(action: onClose) {
                        ZStack {
                            Circle()
                                .fill(isCloseHovered ? Color.red : Color.black.opacity(0.7))
                                .frame(width: 18, height: 18)
                            Text("×")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .onHover { isCloseHovered = $0 }
                    .transition(.opacity)
                }
            }

            // Window title
            Text(windowInfo.title.isEmpty ? "Window" : windowInfo.title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .task {
            thumbnail = await ThumbnailService.shared.thumbnail(
                for: windowInfo.id,
                size: CGSize(width: cardWidth, height: cardHeight)
            )
        }
    }
}
