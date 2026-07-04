import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 截图 Store。负责：
/// 1. 控制流程（idle → selecting → editing）
/// 2. 调 ScreenCaptureKit 抓选区
/// 3. 复制 / 保存
@MainActor
final class ScreenshotStore: ObservableObject {
    @Published var phase: ScreenshotPhase = .idle

    // MARK: - Flow

    func startCapture() {
        phase = .selecting
    }

    func cancelCapture() {
        phase = .idle
    }

    /// `rect` 来自 overlay 的 `convertToScreen(_:)`，是全局屏幕坐标
    /// （和 NSScreen.frame 同坐标系：左下原点、points）。
    /// `screen` 是 overlay 所在屏幕。
    func capture(rect: CGRect, on screen: NSScreen) {
        Task { @MainActor in
            await performCapture(rect: rect, on: screen)
        }
    }

    private func performCapture(rect: CGRect, on screen: NSScreen) async {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            phase = .idle
            return
        }
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                phase = .idle
                return
            }
            // rect 是全局屏幕坐标，SCK 的 sourceRect 要的是 display 局部坐标。
            // display.frame.origin 就是这个 display 在全局中的位置，减去即可。
            let localRect = CGRect(
                x: rect.minX - display.frame.minX,
                y: rect.minY - display.frame.minY,
                width: rect.width,
                height: rect.height
            )
            // 裁到 display 范围内（用户可能拖到屏幕外）
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            let clipped = localRect.intersection(bounds)
            guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else {
                phase = .idle
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = clipped
            // 按 display 实际 scale 输出原生分辨率（不做额外缩放）
            let scale = CGFloat(display.width) / display.frame.width
            config.width = Int(clipped.width * scale)
            config.height = Int(clipped.height * scale)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            phase = .editing(NSImage(cgImage: cgImage, size: size))
        } catch {
            NSLog("ScreenshotStore.capture failed: \(error)")
            phase = .idle
        }
    }

    // MARK: - Clipboard

    func copyToClipboard() {
        guard case .editing(let image) = phase else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    // MARK: - Save

    func save() {
        guard case .editing(let image) = phase else { return }
        guard let data = pngData(from: image) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        if let dir = savedDirectory() {
            panel.directoryURL = dir
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                self?.phase = .idle
            } catch {
                NSLog("ScreenshotStore.save failed: \(error)")
            }
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Screenshot \(f.string(from: Date())).png"
    }

    private func savedDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.saveDirKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private static let saveDirKey = "screenshotSaveDirectoryBookmark"
}
