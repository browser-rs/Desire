import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
class ScreenshotStore: ObservableObject {
    @Published var phase: ScreenshotPhase = .idle
    @Published var currentTool: ScreenshotTool = .rect
    @Published var currentColor: NSColor = .red
    @Published var strokeWidth: CGFloat = 3

    var annotations: [ScreenshotAnnotation] = []
    var undoStack: [[ScreenshotAnnotation]] = []

    private(set) var capturedImage: NSImage?

    static let defaultSaveDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!

    var saveDirectory: URL {
        get {
            guard let bookmarkData = UserDefaults.standard.data(forKey: "screenshotSaveDirectoryBookmark") else {
                return Self.defaultSaveDirectory
            }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else {
                return Self.defaultSaveDirectory
            }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return url
        }
        set {
            let bookmarkData = try? newValue.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "screenshotSaveDirectoryBookmark")
        }
    }

    func startCapture() {
        phase = .selecting
    }

    func cancelCapture() {
        phase = .idle
        annotations = []
        undoStack = []
    }

    func capture(rect: CGRect) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let scale = screen.backingScaleFactor

        let scaledRect = CGRect(
            x: rect.minX * scale,
            y: (screenRect.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        Task {
            guard let cgImage = await captureScreenRect(scaledRect) else { return }
            let image = NSImage(cgImage: cgImage, size: rect.size)
            capturedImage = image
            annotations = []
            undoStack = []
            phase = .editing(image)
        }
    }

    private func captureScreenRect(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.showsCursor = false
            let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return fullImage.cropping(to: rect)
        } catch {
            return nil
        }
    }

    func pushUndo() {
        undoStack.append(annotations)
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        annotations = undoStack.removeLast()
    }

    func clearAnnotations() {
        pushUndo()
        annotations = []
    }

    func save() {
        guard let image = renderFinalImage() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "Screenshot_\(formatter.string(from: Date())).png"
        let url = saveDirectory.appendingPathComponent(filename)

        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try? png.write(to: url)
        phase = .idle
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    func copyToClipboard() {
        guard let image = renderFinalImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        phase = .idle
    }

    private func renderFinalImage() -> NSImage? {
        guard let image = capturedImage else { return nil }
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        image.draw(in: CGRect(origin: .zero, size: size))
        for ann in annotations {
            ann.draw(in: ctx)
        }
        result.unlockFocus()
        return result
    }
}
