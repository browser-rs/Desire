//
//  ScreenshotCapture.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotCapture {
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func captureScreen(_ screen: NSScreen) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            // Match the requested NSScreen by its frame (point coords).
            guard let display = content.displays.first(where: {
                $0.frame.origin == screen.frame.origin && $0.frame.size == screen.frame.size
            }) ?? content.displays.first else {
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.scalesToFit = false
            config.showsCursor = true
            config.captureResolution = .best
            config.ignoreShadowsDisplay = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            // Create NSImage with explicit backing scale so the overlay
            // drawing and composite pipeline see the full Retina resolution.
            let image = NSImage(size: screen.frame.size)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = screen.frame.size
            image.addRepresentation(rep)
            return image
        } catch {
            return nil
        }
    }

    /// Crop an image to a rect in canvas coordinates (origin top-left, y down).
    static func cropImage(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let imagePixelWidth = CGFloat(cgImage.width)
        let imagePixelHeight = CGFloat(cgImage.height)
        let pointWidth = image.size.width
        let pointHeight = image.size.height

        let scaleX = imagePixelWidth / pointWidth
        let scaleY = imagePixelHeight / pointHeight

        // CGImage.cropping(to:) uses the image's own coordinate system, which
        // has its origin at the TOP-LEFT corner (y increases downward) — same
        // convention as our flipped canvas. So we scale rect directly without
        // any Y-flip. (CGContext.draw uses bottom-left origin and needs the
        // flip; that's handled separately in `composite`.)
        let cropRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    /// Composite the cropped image with all annotations baked in.
    /// Returns a new NSImage sized to selectionRect.size with annotations on top.
    static func composite(
        annotations: [ScreenshotAnnotation],
        onto image: NSImage,
        in selectionRect: CGRect,
        canvasSize: CGSize,
        scale: CGFloat,
        mosaicSource: NSImage?
    ) -> NSImage? {
        guard let cropped = cropImage(image, to: selectionRect) else { return nil }
        guard let croppedCG = cropped.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return cropped
        }

        let outputSize = selectionRect.size
        let pixelWidth = max(1, Int(outputSize.width * scale))
        let pixelHeight = max(1, Int(outputSize.height * scale))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }

        // Set up top-left coord system matching NSView with isFlipped=true.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        // Draw cropped base at origin.
        // CGContext.draw renders the image upside-down in a flipped CTM (image's top
        // row maps to rect.maxY in user space, which is the bottom of the view when y
        // goes down). Temporarily un-flip the y-axis to draw the image upright.
        context.saveGState()
        context.translateBy(x: 0, y: outputSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(croppedCG, in: CGRect(origin: .zero, size: outputSize))
        context.restoreGState()

        // Translate so canvas point (selectionRect.x, selectionRect.y) -> (0, 0)
        context.translateBy(x: -selectionRect.origin.x, y: -selectionRect.origin.y)

        // Set NSGraphicsContext so the renderer's NSString.draw() works in this offscreen ctx.
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsCtx

        // Draw annotations (in canvas absolute coords)
        for annotation in annotations {
            ScreenshotAnnotationRenderer.draw(
                annotation,
                in: context,
                canvasSize: canvasSize,
                mosaicSource: mosaicSource
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let composedCG = context.makeImage() else { return cropped }
        return NSImage(cgImage: composedCG, size: outputSize)
    }

    /// Build the downscaled-then-upscaled image used as the "ink" for mosaic strokes.
    static func buildMosaicSource(from image: NSImage) -> NSImage? {
        let scale: CGFloat = 0.1
        let originalSize = image.size
        let smallSize = NSSize(
            width: max(1, originalSize.width * scale),
            height: max(1, originalSize.height * scale)
        )

        let smallImage = NSImage(size: smallSize)
        smallImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: smallSize))
        smallImage.unlockFocus()

        let result = NSImage(size: originalSize)
        result.lockFocus()
        // Nearest-neighbor upscaling for the classic blocky mosaic look.
        NSGraphicsContext.current?.imageInterpolation = .none
        smallImage.draw(in: NSRect(origin: .zero, size: originalSize))
        result.unlockFocus()
        return result
    }

    /// Write an NSImage to disk as PNG. Encoding/compression runs on the
    /// current thread; the actual `write` is fast for typical screenshots
    /// but can hitch for full-page captures — callers on @MainActor should
    /// wrap in `Task.detached`.
    ///
    /// `nonisolated`: pure encode + file write with no app state, designed
    /// to run on whatever thread the caller chose (see `writePNGAsync`).
    nonisolated static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "ScreenshotCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
            )
        }
        try png.write(to: url)
    }

    /// Async variant that bounces the encode + write off the main actor.
    /// Prefer this on hot paths (screenshot-save button, NSSavePanel).
    static func writePNGAsync(_ image: NSImage, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try writePNG(image, to: url)
        }.value
    }

    /// Copy an NSImage to the system pasteboard.
    @MainActor
    static func copyToPasteboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Default filename like "Screenshot_2026-07-05_143012.png".
    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "Screenshot_\(timestamp).png"
    }
}
