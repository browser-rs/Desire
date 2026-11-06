import AppKit
import Combine
import CoreGraphics
import os
import CoreImage
import SwiftUI

/// 编辑器会话（v0.8.46 画布重写）：持有文档 + 视口 + 工具设置，
/// 同时也是命令 API（AI/桥）的操作目标。一个编辑器实例 = 一个会话。
@MainActor
final class ImageEditorSession: ObservableObject {
    /// 当前活动编辑器（桥/Agent 命令入口）。弱引用，窗口关闭自动失效。
    static weak var active: ImageEditorSession?

    /// 全部活着的编辑器会话（弱持有，NSHashTable 在对象释放时自动摘除）。
    /// 多窗口各开一个编辑器时，命令 API 靠 file/session 参数路由到指定会话，
    /// 缺省仍打 active（后激活者）。
    private static let registry = NSHashTable<ImageEditorSession>.weakObjects()

    static var liveSessions: [ImageEditorSession] {
        registry.objectEnumerator().allObjects.compactMap { $0 as? ImageEditorSession }
    }

    /// 命令路由：优先 body 里的 `session`（UUID）或 `file`（路径匹配）；两者都
    /// 没给才回落 active（后激活者）。**显式给了却没匹配到 → 返回 nil**，调用方
    /// 报错——宁可失败也不静默改错文档（多窗口时的 AI 事故面）。
    static func resolve(_ body: [String: Any]) -> ImageEditorSession? {
        let rawSession = (body["session"] as? String) ?? (body["session"] as? NSNumber)?.stringValue
        let rawFile = body["file"] as? String
        if let raw = rawSession, !raw.isEmpty, let uuid = UUID(uuidString: raw),
           let hit = liveSessions.first(where: { $0.id == uuid }) {
            return hit
        }
        if let file = rawFile, !file.isEmpty {
            let wanted = (file as NSString).standardizingPath
            if let hit = liveSessions.first(where: { $0.fileURL?.path == wanted }) {
                return hit
            }
        }
        if (rawSession?.isEmpty == false) || (rawFile?.isEmpty == false) {
            return nil
        }
        return active
    }

    /// 会话稳定标识（命令 API 定向路由用）。
    let id = UUID()

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
    @Published var showGrid = false
    @Published var showCenterGuides = true
    @Published var snapping = true
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
    private var draftTask: Task<Void, Never>?
    var draftSourceKey: String { fileURL?.path ?? "untitled" }

    // 修饰笔画期间的常驻上下文：戳记直接画进来，避免整图重建。
    var liveRetouchContext: CGContext?
    var liveRetouchBase: CGImage?
    var liveRetouchMask: CGImage?
    var liveRetouchRadius: CGFloat = 10
    private var keyMonitor: Any?

    // MARK: - 初始化

    init(fileURL: URL, name: String) {
        self.fileURL = fileURL
        let resolved = name.isEmpty ? fileURL.lastPathComponent : name
        self.displayName = resolved
        if let image = ImageTransforms.load(from: fileURL) {
            // 未保存草稿优先：编辑器视图随标签切换销毁（SelectedTabContent 只挂
            // 当前标签），切回来时若无草稿恢复，3 秒防抖之前的修改就静默丢了。
            // 保存与 Revert 都清草稿，草稿存在 = 有从未落盘的修改。
            if let draft = ImageEditorDraft.load(for: fileURL.path) {
                document = ImageEditorDocument(image: draft, name: resolved)
                pendingDraftNotice = true
            } else {
                document = ImageEditorDocument(image: image, name: resolved)
            }
        } else {
            document = ImageEditorDocument(
                image: ImageEditorRaster.transparent(size: CGSize(width: 800, height: 600))!,
                name: resolved)
            loadError = String(localized: "Could not load this image.")
        }
        Self.registry.add(self)
    }

    /// 空白文档（模板/新建）。
    init(blankCanvas size: CGSize, name: String) {
        self.fileURL = nil
        self.displayName = name
        let background = ImageEditorRaster.transparent(size: size)
            ?? ImageEditorRaster.transparent(size: CGSize(width: 800, height: 600))!
        document = ImageEditorDocument(image: background, name: name)
        Self.registry.add(self)
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

    /// init 里发现草稿时置位，activate（真正显示）时提示一次。
    private var pendingDraftNotice = false

    deinit {
        // 生命周期观测（2026-11-07 会话路由排障）：标签关闭后会话必须能释放，
        // 否则弱注册表里留下"可被 AI 寻址的幽灵编辑器"。
        let path = fileURL?.path ?? "untitled"
        Logger(subsystem: "me.siwi.Desire", category: "app").info(
            "imagepro session deinit \(path, privacy: .public)")
    }

    func activate() {
        ImageEditorSession.active = self
        // 幂等补注册（init 已注册；set 语义，无副作用）。曾试过"只在 activate
        // 注册"来躲视图 body 的僵尸会话——根因其实是"会话在视图里创建"，
        // 创建点挪到路由层后，init 注册即可覆盖后台标签的未激活会话。
        ImageEditorSession.registry.add(self)
        if pendingDraftNotice {
            pendingDraftNotice = false
            flash(String(localized: "Recovered unsaved changes from draft"))
        }
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

    /// 画布显示用（超大图降采样；坐标仍按 base 画布计算）。
    func canvasImage(maxSide: CGFloat = 4096) -> CGImage? {
        document.displayComposite(maxSide: maxSide)
    }

    // MARK: - 提示

    func flash(_ text: String) {
        statusNote = text
        noteToken += 1
        let token = noteToken
        // weak 捕获：强捕获会把"刚关闭的编辑器"在 2.5s 提示窗内继续钉活，
        // 弱注册表里留下可被 AI 寻址的幽灵会话（2026-11-07 路由 E2E 实测）。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.noteToken == token else { return }
            self.statusNote = nil
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
            ImageEditorDraft.remove(for: draftSourceKey)
            document.markSaved()
            flash(String(localized: "Saved"))
            return true
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
            return false
        }
    }

    /// 开始一次修饰笔画：创建与图层同尺寸的常驻上下文（y-down）。
    func beginLiveRetouch() {
        guard let base = document.activeBitmap else { return }
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        liveRetouchContext = ctx
        liveRetouchBase = base
        liveRetouchRadius = brushSize / 2
        let r = Int(max(1, liveRetouchRadius))
        guard let maskCtx = CGContext(data: nil, width: r * 2, height: r * 2,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1),
                      CGColor(gray: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 0.6, 1]) {
            maskCtx.drawRadialGradient(
                gradient, startCenter: CGPoint(x: r, y: r), startRadius: 0,
                endCenter: CGPoint(x: r, y: r), endRadius: CGFloat(r), options: [])
        }
        liveRetouchMask = maskCtx.makeImage()
    }

    func endLiveRetouch() {
        defer {
            liveRetouchContext = nil
            liveRetouchBase = nil
            liveRetouchMask = nil
        }
        guard let ctx = liveRetouchContext,
              let image = ctx.makeImage(),
              let id = document.activeLayer?.id else { return }
        document.setBitmapLive(id, image)
    }

    /// 编辑后 3s 防抖写草稿（崩溃/强杀后可恢复）。
    func scheduleDraftSave() {
        draftTask?.cancel()
        guard document.isDirty else { return }
        draftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, document.isDirty,
                  let image = document.flattened(over: nil) else { return }
            _ = ImageEditorDraft.save(image, for: draftSourceKey)
        }
    }

    /// 恢复草稿（仅像素）。
    @discardableResult
    func restoreDraft() -> Bool {
        guard let image = ImageEditorDraft.load(for: draftSourceKey) else { return false }
        document.reset(image: image, name: displayName)
        canvas.updateContent(display: CGSize(width: image.width, height: image.height),
                             base: CGSize(width: image.width, height: image.height), ops: [])
        canvas.recomputeFit()
        flash(String(localized: "Recovered from draft"))
        return true
    }

    /// 放弃未保存修改，重新从磁盘加载（文件不存在返回 false）。
    @discardableResult
    func revertToSaved() -> Bool {
        guard let fileURL, let image = ImageTransforms.load(from: fileURL) else { return false }
        // Revert = 用户明确放弃未保存修改：草稿必须清掉，否则下次打开
        // 又被自动恢复回来（等于 Revert 无效）。
        ImageEditorDraft.remove(for: draftSourceKey)
        document.reset(image: image, name: displayName)
        canvas.updateContent(display: CGSize(width: image.width, height: image.height),
                             base: CGSize(width: image.width, height: image.height),
                             ops: [])
        canvas.recomputeFit()
        flash(String(localized: "Reverted to saved file"))
        return true
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

    /// 复制当前合成到剪贴板（PNG）。
    @discardableResult
    func copyToClipboard() -> Bool {
        guard let composite = document.composite() else { return false }
        let nsImage = NSImage(cgImage: composite,
                              size: NSSize(width: composite.width, height: composite.height))
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        flash(String(localized: "Copied to clipboard"))
        return true
    }

    func export(format: String, to url: URL, quality: Double = 0.92,
                scale: Double = 1) -> Bool {
        guard let composite = document.composite() else { return false }
        var source = composite
        if scale != 1, scale > 0.05 {
            let w = max(1, Int((CGFloat(composite.width) * CGFloat(scale)).rounded()))
            let h = max(1, Int((CGFloat(composite.height) * CGFloat(scale)).rounded()))
            if let resized = ImageTransforms.resized(composite, width: w, height: h) {
                source = resized
            }
        }
        let needsBackdrop = ["jpg", "jpeg"].contains(format.lowercased())
        let output = ImageEditorRaster.flattened(source,
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
        case "x":
            let holder = primaryColor
            primaryColor = secondaryColor
            secondaryColor = holder
            return true
        case "d":
            primaryColor = .white
            secondaryColor = .black
            return true
        case "[":
            brushSize = max(1, brushSize - 2)
            retouchStrength = retouchStrength
            return true
        case "]":
            brushSize = min(300, brushSize + 2)
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
