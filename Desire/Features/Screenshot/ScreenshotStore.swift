import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenshotStore: ObservableObject {
    @Published var phase: ScreenshotPhase = .idle
    @Published var currentTool: ScreenshotTool = .rect
    @Published var currentColor: NSColor = .red
    @Published var strokeWidth: CGFloat = 3

    var annotations: [ScreenshotAnnotation] = []
    var undoStack: [[ScreenshotAnnotation]] = []
    var redoStack: [[ScreenshotAnnotation]] = []

    private(set) var capturedImage: NSImage?

    static let defaultSaveDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!

    private static let saveDirectoryBookmarkKey = "screenshotSaveDirectoryBookmark"

    /// 计算当前保存目录 URL。如果 bookmark 存在则解析（不解锁，留给 save 时再解锁）。
    /// 注意：Security-Scoped Bookmark 必须在写文件前 start，写完后 stop，
    /// 提前在 getter 里 start + defer stop 会导致真正的写入被沙箱拒绝。
    var saveDirectory: URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.saveDirectoryBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return Self.defaultSaveDirectory
    }

    func startCapture() {
        phase = .selecting
    }

    func cancelCapture() {
        phase = .idle
        annotations = []
        undoStack = []
        redoStack = []
        capturedImage = nil
    }

    /// `rect` 来自 ScreenshotSelectionOverlay，在 NSView 的本地坐标里（AppKit 默认左下原点），
    /// 又因为 SelectionView 的 frame = screen.frame，所以本地坐标 == NSScreen 全局坐标（左下原点）。
    /// `screen` 参数由 Overlay 透传过来，确保 NSScreen.main 在 select/capture 之间不会漂移
    /// （例如 overlay 期间点开别处会改变 key window，从而改变 NSScreen.main）。
    func capture(rect: CGRect, on screen: NSScreen? = nil) {
        let targetScreen = screen ?? NSScreen.main
        guard let screen = targetScreen else { return }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
        let scale = screen.backingScaleFactor
        // 转成 CGImage 期望的像素 + 左上原点（cgImage.cropping(to:) 用这个空间）
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: (screen.frame.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        Task { [weak self] in
            guard let self else { return }
            guard let cgImage = await self.captureDisplay(id: displayID, pixelRect: pixelRect) else { return }
            let pointSize = NSSize(width: rect.width, height: rect.height)
            let image = NSImage(cgImage: cgImage, size: pointSize)
            self.capturedImage = image
            self.annotations = []
            self.undoStack = []
            self.redoStack = []
            self.phase = .editing(image)
        }
    }

    private func captureDisplay(id: CGDirectDisplayID, pixelRect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // 抓全屏 + 用 cropping(to:) 裁剪，行为可预期：
            //  - config.width/height 是输出像素，必须等于 display 原生像素才能 1:1 裁剪
            //  - pixelRect 已是左上原点像素，可直接交给 cgImage.cropping(to:)
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.showsCursor = false
            let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let safeRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height))
            guard !safeRect.isNull, safeRect.width > 0, safeRect.height > 0 else { return nil }
            return fullImage.cropping(to: safeRect)
        } catch {
            NSLog("ScreenshotStore.captureDisplay failed: \(error)")
            return nil
        }
    }

    func pushUndo() {
        undoStack.append(annotations)
        redoStack = []
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        redoStack.append(annotations)
        annotations = undoStack.removeLast()
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(annotations)
        annotations = redoStack.removeLast()
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations = []
    }

    func deleteAnnotation(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        pushUndo()
        annotations.remove(at: index)
    }

    /// 把 currentImage + annotations 合成 PNG Data。Copy 和 Save 共用，渲染发生在主线程同步块内。
    func renderFinalPNGData() -> Data? {
        guard let image = capturedImage else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 切到普通左下原点
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))

        // 注释的 draw 基于左下原点，把 ctx 再翻一次以保持视觉一致
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        for ann in annotations {
            ann.draw(in: ctx)
        }

        guard let finalCGImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: finalCGImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// 写文件 + 沙箱作用域管理：仅当 URL 是 security-scoped 时才 start/stop，
    /// defaultSaveDirectory 是 sandbox 容器路径（受 App Sandbox 写权限保护），不需要额外操作。
    func save() {
        guard let png = renderFinalPNGData() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "Screenshot_\(formatter.string(from: Date())).png"

        let target = saveDirectory
        let didStart = target.startAccessingSecurityScopedResource()
        defer { if didStart { target.stopAccessingSecurityScopedResource() } }

        let url = target.appendingPathComponent(filename)
        do {
            try png.write(to: url)
        } catch {
            NSLog("ScreenshotStore.save failed: \(error)")
            return
        }
        phase = .idle
        capturedImage = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard() {
        guard let png = renderFinalPNGData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 用 PNG Data 写，比直接传 NSImage 更稳：避免 NSImage 在 pasteboard 上转码失败
        pasteboard.setData(png, forType: .png)
        phase = .idle
        capturedImage = nil
    }
}
