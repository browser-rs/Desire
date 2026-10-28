import Combine
import CryptoKit
import Foundation
import PDFKit

/// PDF 工作台模型（v0.8.15 旗舰）：导航（页码/大纲/缩略图）、⌘F 查找、
/// 批注（高亮/下划线/便签/箭头/矩形）、页面管理（旋转/删除/重排/提取）。
/// v0.8.16 深水区：加密解锁、AcroForm 表单字段、阅读进度记忆、
/// 合并/提取静态管道（最近文件右键共用）。
/// View 层只渲染；PDFKit 操作全部收口在这里。
@MainActor
final class PDFWorkbenchModel: ObservableObject {

    let document: PDFDocument

    /// ⌘S 落点（另存面板默认名）。
    let suggestedName: String

    /// 打开时是否带密码锁（解锁前 PDFView 无内容可渲染）。
    var isLocked: Bool { document.isLocked }

    init(document: PDFDocument, fileName: String) {
        self.document = document
        self.suggestedName = (fileName as NSString).deletingPathExtension + ".pdf"
        annotationCount = Self.totalAnnotations(of: document)
        refreshOutline()
    }

    static func load(fileURL: URL, fileName: String) -> PDFWorkbenchModel? {
        guard let doc = PDFDocument(url: fileURL) else { return nil }
        return PDFWorkbenchModel(document: doc, fileName: fileName)
    }

    /// 解锁（v0.8.16）：成功后刷新批注计数与大纲。已解锁返回 true。
    func unlock(withPassword password: String) -> Bool {
        guard document.isLocked else { return true }
        guard document.unlock(withPassword: password) else { return false }
        annotationCount = Self.totalAnnotations(of: document)
        refreshOutline()
        return true
    }

    /// PDFKit 无全文档批注 API——逐页累加（页数量级小，可接受）。
    private static func totalAnnotations(of document: PDFDocument) -> Int {
        var count = 0
        for i in 0..<document.pageCount {
            count += document.page(at: i)?.annotations.count ?? 0
        }
        return count
    }

    // MARK: - 状态

    @Published private(set) var pageIndex: Int = 0
    @Published private(set) var annotationCount: Int = 0
    /// 有未保存改动（批注增删 / 页面操作）。
    @Published private(set) var hasUnsavedChanges = false
    @Published var statusNote: String?

    func updatePageIndex(_ index: Int) {
        guard index >= 0 else { return }
        pageIndex = index
    }

    // MARK: - 查找（⌘F）

    struct SearchState: Equatable {
        var query = ""
        var matches: [PDFSelection] = []
        var current = 0
        var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    @Published private(set) var search = SearchState()

    func runSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            search = SearchState()
            return
        }
        // 大小写不敏感；重跑同一关键字时保持当前命中位置附近（避免跳回首个）。
        let keep = search.query == trimmed ? search.current : 0
        let matches = document.findString(trimmed, withOptions: [.caseInsensitive])
        search = SearchState(query: trimmed, matches: matches, current: matches.isEmpty ? 0 : min(keep, matches.count - 1))
    }

    /// 跳到第 i 个命中（±按钮/回车循环）。
    func selectMatch(at index: Int) -> PDFSelection? {
        guard !search.matches.isEmpty else { return nil }
        let i = (index + search.matches.count) % search.matches.count
        search.current = i
        return search.matches[i]
    }

    // MARK: - 大纲

    struct OutlineItem: Identifiable {
        let id = UUID()
        let label: String
        let indent: Int
        let destination: PDFDestination?
    }

    /// 大纲树展平（indent 表示层级）；无大纲返回空。stored + refresh：
    /// 加密 PDF 解锁前 outlineRoot 拿不到——lazy 求值会把空结果定死。
    @Published private(set) var outlineItems: [OutlineItem] = []

    func refreshOutline() {
        guard !document.isLocked, let root = document.outlineRoot else {
            outlineItems = []
            return
        }
        var items: [OutlineItem] = []
        func walk(_ node: PDFOutline, indent: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                items.append(OutlineItem(label: child.label ?? "", indent: indent, destination: child.destination))
                walk(child, indent: indent + 1)
            }
        }
        walk(root, indent: 0)
        outlineItems = items
    }

    // MARK: - 缩略图（懒生成缓存）

    private var thumbnailCache: [Int: NSImage] = [:]
    private var thumbnailTaskInFlight: Set<Int> = []

    /// 取缩略图；未生成时在主线程串行补（PDFDocument/页面建议主线程使用，
    /// 逐页 Task 分摊不阻塞渲染），就绪后回调刷新。
    func thumbnail(for index: Int, width: CGFloat, onReady: @escaping () -> Void) -> NSImage? {
        if let cached = thumbnailCache[index] { return cached }
        guard index >= 0, index < document.pageCount,
              let page = document.page(at: index),
              !thumbnailTaskInFlight.contains(index) else { return nil }
        thumbnailTaskInFlight.insert(index)
        let renderSize = CGSize(width: width * 2, height: width * 2 * 4 / 3)   // 2x for Retina
        let displaySize = NSSize(width: width, height: width * 4 / 3)          // 竖版 A4 近似占位
        Task { @MainActor [weak self] in
            let image = page.thumbnail(of: renderSize, for: .mediaBox)
            image.size = displaySize
            self?.thumbnailCache[index] = image
            self?.thumbnailTaskInFlight.remove(index)
            onReady()
        }
        return nil
    }

    // MARK: - AcroForm 表单字段（v0.8.16，spike 已验证往返无损）

    struct FormFieldRef: Identifiable {
        let id = UUID()
        let annotation: PDFAnnotation
        let pageIndex: Int
        let name: String
        let value: String
        let isText: Bool   // v1 只可编辑文本字段；按钮/勾选只读展示
    }

    /// 全文档 widget 字段清单（type == "Widget" 是可靠标记）。
    func formFields() -> [FormFieldRef] {
        var out: [FormFieldRef] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" {
                let kind = a.widgetFieldType
                out.append(FormFieldRef(
                    annotation: a,
                    pageIndex: i,
                    name: a.fieldName ?? String(localized: "Untitled field"),
                    value: kind == .text ? (a.widgetStringValue ?? "") : (a.fieldName == nil ? "" : kindLabel(kind)),
                    isText: kind == .text))
            }
        }
        return out
    }

    private func kindLabel(_ kind: PDFAnnotationWidgetSubtype) -> String {
        switch kind {
        case .button: return String(localized: "Button")
        case .choice: return String(localized: "Choice")
        case .signature: return String(localized: "Signature")
        default: return String(localized: "Field")
        }
    }

    /// 写文本字段值（TextField 提交时调用）；落 markChanged 走 ⌘S 保存。
    func setFormValue(_ annotation: PDFAnnotation, value: String) {
        annotation.widgetStringValue = value
        markChanged()
    }

    // MARK: - 阅读进度记忆（v0.8.16：按路径哈希，列宽记忆同款键族）

    struct ReadingPosition: Codable {
        var page: Int
        var zoom: Double
    }

    private static func positionKey(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "viewer.pdf.position.\(hex)"
    }

    static func loadPosition(filePath: String) -> ReadingPosition? {
        guard let data = UserDefaults.standard.data(forKey: positionKey(for: filePath)),
              let pos = try? JSONDecoder().decode(ReadingPosition.self, from: data),
              pos.page >= 0 else { return nil }
        return pos
    }

    func savePosition(filePath: String) {
        let pos = ReadingPosition(page: pageIndex, zoom: Double(zoomValue))
        if let data = try? JSONEncoder().encode(pos) {
            UserDefaults.standard.set(data, forKey: Self.positionKey(for: filePath))
        }
    }

    /// 当前缩放（视图层经 attachView 同步进来——模型不知道 scaleFactor）。
    var zoomValue: Double = 1

    // MARK: - 合并 / 提取静态管道（v0.8.16：最近文件右键共用；
    // Agent mergePDFs/splitPDF 工具语义一致，互不依赖）

    /// 多 PDF 按序合并；返回总页数（失败 nil）。
    @discardableResult
    static func merge(files: [URL], to dest: URL) -> Int? {
        let out = PDFDocument()
        var inserted = 0
        for file in files {
            guard let doc = PDFDocument(url: file) else { continue }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: inserted)
                    inserted += 1
                }
            }
        }
        guard inserted > 0, out.write(to: dest) else { return nil }
        return inserted
    }

    /// 按页码范围提取（"1-3,5"，1-based，PageRangeParser）；返回提取页数。
    @discardableResult
    static func extractPages(from src: URL, spec: String, to dest: URL) -> Int? {
        guard let doc = PDFDocument(url: src),
              let indices = PageRangeParser.parse(spec, pageCount: doc.pageCount) else { return nil }
        let out = PDFDocument()
        for (offset, index) in indices.enumerated() {
            if let page = doc.page(at: index) {
                out.insert(page, at: offset)
            }
        }
        guard out.pageCount > 0, out.write(to: dest) else { return nil }
        return out.pageCount
    }

    // MARK: - 批注

    enum AnnotationTool: String, CaseIterable {
        case none, highlight, underline, note, arrow, rectangle

        var icon: String {
            switch self {
            case .none: return "cursorarrow"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .note: return "text.bubble"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            }
        }
    }

    @Published var tool: AnnotationTool = .none

    /// 选区驱动：把当前选区落成高亮/下划线批注（按行逐条）。
    func annotateSelection(_ selection: PDFSelection?) {
        guard let selection,
              tool == .highlight || tool == .underline else { return }
        let selections = selection.selectionsByLine()
        var added = 0
        for line in selections {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page)
            let annotation: PDFAnnotation
            if tool == .highlight {
                annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
            } else {
                annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
                annotation.color = NSColor.controlAccentColor
            }
            annotation.contents = line.string ?? ""
            page.addAnnotation(annotation)
            added += 1
        }
        if added > 0 {
            markChanged()
            flash(String(localized: "\(added) annotation(s) added"))
        }
    }

    /// 点击落文字便签（freeText）：弹输入层后由视图回调这里写入。
    func addNote(_ text: String, page: PDFPage, point: CGPoint) {
        let bounds = CGRect(x: point.x, y: point.y, width: 180, height: 44)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = .systemFont(ofSize: 11)
        annotation.color = NSColor.controlAccentColor.withAlphaComponent(0.12)
        annotation.fontColor = .labelColor
        page.addAnnotation(annotation)
        markChanged()
    }

    /// 拖拽绘制的箭头/矩形（起终点为页面坐标）。
    func addShape(_ tool: AnnotationTool, page: PDFPage, from: CGPoint, to: CGPoint) {
        let bounds = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                            width: abs(to.x - from.x), height: abs(to.y - from.y))
        guard bounds.width > 2 || bounds.height > 2 else { return }
        let annotation: PDFAnnotation
        if tool == .arrow {
            annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: from.x - bounds.minX, y: from.y - bounds.minY)
            annotation.endPoint = CGPoint(x: to.x - bounds.minX, y: to.y - bounds.minY)
            annotation.endLineStyle = .openArrow
        } else {
            annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        }
        annotation.color = NSColor.controlAccentColor
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        page.addAnnotation(annotation)
        markChanged()
    }

    /// 批注列表（跳过链接等系统注；带所在页码供跳转）。
    func allAnnotations() -> [(annotation: PDFAnnotation, pageIndex: Int)] {
        var result: [(PDFAnnotation, Int)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.type != "Link" {
                result.append((a, i))
            }
        }
        return result
    }

    func removeAnnotation(_ annotation: PDFAnnotation, pageIndex: Int) {
        guard let page = document.page(at: pageIndex) else { return }
        page.removeAnnotation(annotation)
        markChanged()
    }

    // MARK: - 页面管理

    /// 页面操作撤销栈（记录逆操作，上限 50）。
    private enum PageOp {
        case deleted(page: PDFPage, index: Int)
        case moved(from: Int, to: Int)
        case rotated(page: PDFPage, previousRotation: Int)
        case inserted(page: PDFPage, index: Int)
    }
    private var pageUndoStack: [PageOp] = []
    var canUndoPage: Bool { !pageUndoStack.isEmpty }

    var pageCount: Int { document.pageCount }

    func rotatePage(_ index: Int) {
        guard let page = document.page(at: index) else { return }
        let previous = page.rotation
        page.rotation = (previous + 90) % 360
        pageUndoStack.append(.rotated(page: page, previousRotation: previous))
        markChanged()
    }

    func deletePage(_ index: Int) {
        guard document.pageCount > 1, let page = document.page(at: index) else { return }
        document.removePage(at: index)
        pageUndoStack.append(.deleted(page: page, index: index))
        pageIndex = min(pageIndex, document.pageCount - 1)
        invalidateThumbnails(after: index)
        markChanged()
    }

    func movePage(from: Int, to: Int) {
        guard from != to, from >= 0, from < document.pageCount,
              to >= 0, to < document.pageCount,
              let page = document.page(at: from) else { return }
        document.removePage(at: from)
        document.insert(page, at: to)
        pageUndoStack.append(.moved(from: from, to: to))
        invalidateThumbnails()
        markChanged()
    }

    /// 提取单页为新 PDF（落面板选的位置）。
    func extractPage(_ index: Int, to url: URL) -> Bool {
        guard let page = document.page(at: index) else { return false }
        let out = PDFDocument()
        out.insert(page, at: 0)
        return out.write(to: url)
    }

    func undoPageOperation() {
        guard let op = pageUndoStack.popLast() else { return }
        switch op {
        case .deleted(let page, let index):
            document.insert(page, at: min(index, document.pageCount))
        case .moved(let from, let to):
            // 逆操作：把 now-at-to 的页面搬回 from。
            if let page = document.page(at: to) {
                document.removePage(at: to)
                document.insert(page, at: from)
            }
        case .rotated(let page, let previousRotation):
            page.rotation = previousRotation
        case .inserted(let page, let index):
            document.removePage(at: index)
            _ = page
        }
        invalidateThumbnails()
        markChanged()
    }

    private func invalidateThumbnails(after index: Int? = nil) {
        if let index {
            for key in thumbnailCache.keys where key >= index { thumbnailCache[key] = nil }
        } else {
            thumbnailCache.removeAll()
        }
    }

    // MARK: - 保存

    /// PDF 多来自临时下载文件，保存统一走另存面板（写回会落进临时目录拿不到）。
    func save(to url: URL) -> Bool {
        let ok = document.write(to: url)
        if ok {
            hasUnsavedChanges = false
            flash(String(localized: "Saved → \(url.lastPathComponent)"))
        } else {
            flash(String(localized: "Save failed"))
        }
        return ok
    }

    // MARK: - 视图指令通道（跳转/选区/便签落点——不经 NotificationCenter，
    // 多标签各开各的 PDF 时广播会串台；视图 attach 进来，指令直达自己的 PDFView）

    weak var attachedView: PDFWorkbenchMouseView?

    func requestGoToPage(_ index: Int) {
        attachedView?.goToPageInDocument(index)
    }

    func requestGoToDestination(_ destination: PDFDestination) {
        attachedView?.go(to: destination)
    }

    func requestSelect(_ selection: PDFSelection) {
        attachedView?.setCurrentSelection(selection, animate: true)
        attachedView?.go(to: selection)
    }

    /// 关掉查找时清掉选区高亮。
    func clearSearchSelection() {
        attachedView?.setCurrentSelection(nil, animate: false)
    }

    /// 当前选区文本 + 起始页号（选区上白板用；无选区返回 nil）。
    func currentSelectionWithPage() -> (text: String, pageIndex: Int)? {
        guard let selection = attachedView?.currentSelection,
              let text = selection.string, !text.isEmpty else { return nil }
        let page = selection.pages.first ?? attachedView?.currentPage
        let index = (page.flatMap { document.index(for: $0) }) ?? pageIndex
        return (text, index)
    }

    /// 便签落点（视图层点击 → 输入层 → addNote）。
    struct PendingNote: Equatable {
        let pageIndex: Int
        let point: CGPoint
    }
    @Published var pendingNote: PendingNote?

    // MARK: - 私有

    private func markChanged() {
        hasUnsavedChanges = true
        annotationCount = Self.totalAnnotations(of: document)
    }

    private func flash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.statusNote == text { self?.statusNote = nil }
        }
    }
}
