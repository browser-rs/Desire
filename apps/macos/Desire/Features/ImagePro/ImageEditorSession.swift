import AppKit
import Combine
import CoreGraphics
import CoreImage
import SwiftUI

/// 编辑器会话（v0.8.46 画布重写）：持有文档 + 视口 + 工具设置，
/// 同时也是命令 API（AI/桥）的操作目标。一个编辑器实例 = 一个会话。
@MainActor
final class ImageEditorSession: ObservableObject {
    /// 当前活动编辑器（桥/Agent 命令入口）。弱引用，窗口关闭自动失效。
    static weak var active: ImageEditorSession?

    var fileURL: URL?
    var displayName: String
    let document: ImageEditorDocument
    let canvas = ImageCanvasModel()

    // MARK: 工具状态

    @Published var tool: ImageEditorTool = .brush
    @Published var shape: ImageEditorShape = .rectangle
    @Published var primaryColor: Color = .red
    @Published var secondaryColor: Color = .white
    @Published var brushSize: CGFloat = 30
    @Published var brushOpacity: Double = 1
    @Published var brushHardness: Double = 0.8
    @Published var lineWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 32
    @Published var textFontFamily: String?
    @Published var textWeight = "semibold"
    @Published var textAlignment = "left"
    @Published var textLineSpacing: Double = 1.2
    @Published var textStrokeWidth: CGFloat = 0
    @Published var textStrokeColor: Color = .black
    @Published var textShadow = false
    @Published var textBackground = false
    @Published var textBackgroundColor: Color = .black
    @Published var wandTolerance: Double = 32
    @Published var retouchMode: ImageRetouchMode = .clone
    @Published var retouchStrength: Double = 0.7
    @Published var cloneSample: CGPoint?
    @Published var gradientRadial = false
    @Published var cornerRadius: CGFloat = 0
    @Published var dashedStroke = false
    @Published var selectionFeather: Double = 0
    @Published var fillShapes = false
    @Published var marqueeEllipse = false
    @Published var cropAspect: CGFloat = 0

    // MARK: 面板

    @Published var showLayers = true
    @Published var showHistory = false
    @Published var showAdjustments = false

    // MARK: 状态

    @Published var statusNote: String?
    @Published var cursorBase: CGPoint?
    @Published var loadError: String?

    private var noteToken = 0
    private var keyMonitor: Any?

    // MARK: - 初始化

    init(fileURL: URL, name: String) {
        self.fileURL = fileURL
        let resolved = name.isEmpty ? fileURL.lastPathComponent : name
        self.displayName = resolved
        if let image = ImageTransforms.load(from: fileURL) {
            document = ImageEditorDocument(image: image, name: resolved)
        } else {
            document = ImageEditorDocument(
                image: ImageEditorRaster.transparent(size: CGSize(width: 800, height: 600))!,
                name: resolved)
            loadError = String(localized: "Could not load this image.")
        }
    }

    /// 空白文档（模板/新建）。
    init(blankCanvas size: CGSize, name: String) {
        self.fileURL = nil
        self.displayName = name
        let background = ImageEditorRaster.transparent(size: size)
            ?? ImageEditorRaster.transparent(size: CGSize(width: 800, height: 600))!
        document = ImageEditorDocument(image: background, name: name)
    }

    var isUntitled: Bool { fileURL == nil }

    /// 新建文档（模板）：重置当前编辑器内容。
    func newDocument(size: CGSize, name: String) {
        guard let blank = ImageEditorRaster.transparent(size: size) else { return }
        document.reset(image: blank, name: name)
        fileURL = nil
        displayName = name
        canvas.updateContent(display: size, base: size, ops: [])
        canvas.recomputeFit()
        flash(String(localized: "New document created"))
    }

    func activate() {
        ImageEditorSession.active = self
        installKeyMonitor()
    }

    /// 窗口级单键快捷键（工具/删除/Esc）：NSView 失去焦点（点过面板、刚提交文字）
    /// 后仍可用；正在编辑文本字段时不拦截。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  ImageEditorSession.active === self,
                  let window = event.window,
                  window == NSApp.keyWindow else { return event }
            if let responder = window.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }
            let blockers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(blockers).isEmpty,
                  let chars = event.charactersIgnoringModifiers, chars.count == 1
            else { return event }
            return self.handleKey(chars.lowercased()) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    var canvasSize: CGSize { document.canvasSize }
    var displayImage: CGImage? { document.composite() }

    // MARK: - 提示

    func flash(_ text: String) {
        statusNote = text
        noteToken += 1
        let token = noteToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.noteToken == token { self.statusNote = nil }
        }
    }

    // MARK: - 颜色

    var primaryCGColor: CGColor {
        ImageEditorRaster.color(from: NSColor(primaryColor))
    }

    func setPrimaryColor(_ cg: CGColor) {
        primaryColor = Color(nsColor: NSColor(cgColor: cg) ?? .red)
    }

    // MARK: - 保存 / 导出

    @discardableResult
    func saveInPlace() -> Bool {
        guard let fileURL else { return saveAs() }
        guard let output = document.flattened(over: nil) else {
            flash(String(localized: "Nothing to save"))
            return false
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                let backup = fileURL.deletingPathExtension()
                    .appendingPathExtension(fileURL.pathExtension + ".bak")
                try? fm.removeItem(at: backup)
                try? fm.copyItem(at: fileURL, to: backup)
            }
            try ImageTransforms.save(output, to: fileURL)
            document.markSaved()
            flash(String(localized: "Saved"))
            return true
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
            return false
        }
    }

    /// 另存为（无标题文档 / 手动导出）。
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".png"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let output = document.flattened(over: nil) else { return false }
        do {
            try ImageTransforms.save(output, to: url)
            fileURL = url
            displayName = url.lastPathComponent
            document.markSaved()
            flash(String(localized: "Saved"))
            return true
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
            return false
        }
    }

    func export(format: String, to url: URL, quality: Double = 0.92) -> Bool {
        guard let composite = document.composite() else { return false }
        let needsBackdrop = ["jpg", "jpeg"].contains(format.lowercased())
        let output = ImageEditorRaster.flattened(composite,
                                                 over: needsBackdrop ? CGColor(gray: 1, alpha: 1) : nil)
        guard let output else { return false }
        do {
            try ImageTransforms.save(output, to: url, quality: quality)
            flash(String(localized: "Exported"))
            return true
        } catch {
            flash(String(localized: "Export failed: \(error.localizedDescription)"))
            return false
        }
    }

    // MARK: - 键盘

    /// 单键快捷键（事件层直送）。返回是否消费。
    func handleKey(_ key: String) -> Bool {
        if let tool = ImageEditorTool.allCases.first(where: { $0.hotKey == key }),
           key.count == 1, key.first?.isLetter == true {
            self.tool = tool
            return true
        }
        switch key {
        case "\u{1b}":
            document.clearSelection()
            tool = tool == .crop ? .move : tool
            return true
        case "\u{7f}", "\u{8}":  // delete/backspace
            if !document.selection.isEmpty {
                deleteSelectionContents()
                return true
            }
            return false
        default:
            return false
        }
    }

    /// 删除选区内容（填充透明）。
    func deleteSelectionContents() {
        guard let bitmap = document.activeBitmap,
              let mask = document.selection.maskImage(canvasSize: document.canvasSize)
        else { return }
        guard let ctx = ImageEditorRaster.drawingContext(bitmap) else { return }
        ctx.setBlendMode(.destinationOut)
        // mask 是灰度：先转成 alpha 蒙版再裁切
        if let clip = ImageEditorRaster.alphaMask(from: mask) {
            ctx.clip(to: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height),
                     mask: clip)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        if let out = ctx.makeImage() {
            document.replaceActiveBitmap(out, title: "Clear Selection")
        }
    }

}
