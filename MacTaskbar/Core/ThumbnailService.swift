import AppKit
import Foundation

@MainActor
class ThumbnailService: ObservableObject {
    static let shared = ThumbnailService()

    private var cache: [CGWindowID: NSImage] = [:]

    func thumbnail(for windowID: CGWindowID, size: CGSize) async -> NSImage? {
        // Use CGWindowListCreateImage for capture
        let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )

        guard let cg = cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        cache[windowID] = image
        return image
    }

    func cachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        cache[windowID]
    }

    func clearCache() {
        cache.removeAll()
    }
}
