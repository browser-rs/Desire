import AppKit
import Foundation

/// Encoding helpers for user-attached images sent to vision models.
enum ImageAttachment {
    /// Maximum edge length for an attached image — matches the screenshot
    /// pipeline; vision models downscale internally anyway, and big pastes
    /// dominate the request payload.
    private static let maxDimension: CGFloat = 1024

    /// Converts an image to a JPEG data URI (`data:image/jpeg;base64,…`),
    /// downscaled so its longest edge is ≤ 1024px. Returns nil when the
    /// image can't be represented.
    static func dataURI(from image: NSImage) -> String? {
        var size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        size.width *= scale
        size.height *= scale

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// Extracts image data URIs from a pasteboard / drop payload.
    /// Accepts image data directly, or file URLs pointing at images.
    static func dataURIs(from providers: [NSItemProvider]) async -> [String] {
        var result: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.image") {
            if let uri = await loadImage(from: provider) {
                result.append(uri)
            }
        }
        return result
    }

    private static func loadImage(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                guard let data, let image = NSImage(data: data),
                      let uri = dataURI(from: image) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: uri)
            }
        }
    }
}
