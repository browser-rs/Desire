import Combine
import Foundation
import WebKit

/// 翻页请求（v0.8.34 批次二）：由模型发出，WebView 协调器先拍快照再换页并做翻页动画。
struct EbookPageTurnRequest: Equatable, Identifiable {
    let id: UUID
    var target: Int
    var forward: Bool
}

struct EbookSelection: Equatable, Sendable {
    var id = UUID()
    var text: String
    var rect: CGRect
    /// 章节内文本偏移（UTF-16）；-1 = JS 未取到，只能按 quote 兜底。
    var startOffset: Int = -1
    var endOffset: Int = -1
}

/// 新增高亮的结果：是否新建、是否新写入摘录（false = 摘录去重命中）。
struct EbookHighlightCreation {
    let highlight: EbookHighlight
    let isNew: Bool
    let excerptAdded: Bool
}

/// EPUB/TXT 阅读器状态（v0.8.34）：章节加载、清洗/包装、进度、主题、滚动/分页。
@MainActor
final class EbookReaderModel: ObservableObject {

    enum LayoutMode: String, CaseIterable, Identifiable {
        case scroll, paged
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .scroll: return String(localized: "Scroll")
            case .paged: return String(localized: "Paged")
            }
        }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case paper, sepia, dark, night
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .paper: return String(localized: "Paper")
            case .sepia: return String(localized: "Sepia")
            case .dark: return String(localized: "Dark")
            case .night: return String(localized: "Night")
            }
        }
        var background: String {
            switch self {
            case .paper: return "#FFFFFF"
            case .sepia: return "#F6EEDD"
            case .dark: return "#1E1E1E"
            case .night: return "#000000"
            }
        }
        var foreground: String {
            switch self {
            case .paper: return "#1A1A1A"
            case .sepia: return "#3A2E1F"
            case .dark: return "#D8D8D8"
            case .night: return "#B8B8B8"
            }
        }
        var link: String {
            switch self {
            case .paper: return "#8B5E34"
            case .sepia: return "#7A4E2D"
            case .dark: return "#E0A96D"
            case .night: return "#C9A227"
            }
        }
    }

    let book: Ebook
    let bookRoot: URL

    @Published private(set) var chapters: [EbookCore.Chapter] = []
    @Published private(set) var txtChapters: [EbookCore.TXTChapter] = []
    @Published private(set) var toc: [EbookCore.TOCItem] = []
    @Published private(set) var currentChapter = 0
    @Published private(set) var chapterTitle = ""
    @Published private(set) var htmlFileURL: URL?
    @Published var chapterProgress: Double = 0
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    @Published var pageTurnRequest: EbookPageTurnRequest?
    @Published var layoutMode: LayoutMode {
        didSet {
            UserDefaults.standard.set(layoutMode.rawValue, forKey: Self.layoutKey)
            UserDefaults.standard.set(layoutMode.rawValue, forKey: settingsPrefix + "layout")
        }
    }
    @Published var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey)
            UserDefaults.standard.set(fontSize, forKey: settingsPrefix + "fontSize")
        }
    }
    @Published var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
            UserDefaults.standard.set(theme.rawValue, forKey: settingsPrefix + "theme")
        }
    }
    @Published var showTOC = false
    @Published private(set) var bookmarks: [EbookBookmark] = []
    /// 书内高亮/笔记（v0.8.35）：全书列表，渲染时只注入当前章。
    @Published private(set) var highlights: [EbookHighlight] = []
    /// 当前章的译文语言（nil = 未显示译文，v0.8.36）。
    @Published private(set) var translationLanguage: String?
    @Published var showNotes = false
    @Published var focusedHighlightID: UUID?
    @Published private(set) var searchResults: [EbookSearchCore.Hit] = []
    @Published var searchQuery = ""
    @Published private(set) var isSearching = false
    @Published var showSearch = false
    @Published var selection: EbookSelection?

    private static let fontSizeKey = "ebook.fontSize"
    private static let themeKey = "ebook.theme"
    private static let layoutKey = "ebook.layout"
    private weak var webView: WKWebView?
    private var restoreRatio: Double?
    /// 深链指定起始章（`desire://books/<id>?chapter=N`）；load() 消费一次。
    var initialChapter: Int?
    /// 全库搜索跳转时要高亮的关键词；load() 消费一次。
    var initialSearchQuery: String?
    private var lastSaved = Date.distantPast
    private var statsSessionStart: Date?
    private var statsPagesSinceFlush = 0
    private var statsTimer: Timer?
    private var lastSpeechSeek = Date.distantPast
    private var chapterTextCache: [EbookSearchCore.ChapterText]?
    private var pendingSearchQuery: String?
    private var pendingRevealHighlightID: UUID?
    private var loadGeneration = 0
    private var webViewReadyGeneration = -1
    private var bookmarkKey: String { "ebook.bookmarks.\(book.id.uuidString)" }
    private var settingsPrefix: String { "ebook.settings.\(book.id.uuidString)." }
    private var translationCache: EbookTranslationCache
    private var translationAuto = false
    private var lastTranslationLanguage: String?

    var chapterCount: Int {
        max(1, chapters.isEmpty ? txtChapters.count : chapters.count)
    }

    var overallProgress: Double {
        min(1, max(0, (Double(currentChapter) + chapterProgress) / Double(chapterCount)))
    }

    init(book: Ebook) {
        self.book = book
        self.bookRoot = EbookImporter.rootDirectory
            .appendingPathComponent(book.containerDirectory, isDirectory: true)
        let storedSize = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = storedSize >= 12 && storedSize <= 32 ? storedSize : 19
        self.theme = Theme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "")
            ?? .paper
        self.layoutMode = LayoutMode(
            rawValue: UserDefaults.standard.string(forKey: Self.layoutKey) ?? "")
            ?? .paged
        // 按书覆写（v0.8.35）：这本书上次用过的排版优先于全局默认。
        let prefix = "ebook.settings.\(book.id.uuidString)."
        if let size = UserDefaults.standard.object(forKey: prefix + "fontSize") as? Double,
           size >= 12, size <= 32 {
            self.fontSize = size
        }
        if let raw = UserDefaults.standard.string(forKey: prefix + "theme"),
           let value = Theme(rawValue: raw) {
            self.theme = value
        }
        if let raw = UserDefaults.standard.string(forKey: prefix + "layout"),
           let value = LayoutMode(rawValue: raw) {
            self.layoutMode = value
        }
        self.bookmarks = DiskStore.load([EbookBookmark].self,
                                        key: "ebook.bookmarks.\(book.id.uuidString)") ?? []
        self.highlights = EbookHighlightStore.load(book.id)
        self.translationCache = EbookTranslationStore.load(book.id)
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            switch book.format {
            case .epub:
                try loadEPUB()
            case .txt:
                try loadTXT()
            case .markdown:
                try loadMarkdown()
            case .html:
                try loadHTMLBook()
            default:
                error = String(localized: "This format is not supported yet.")
            }
        } catch {
            self.error = error.localizedDescription
        }
        if error == nil {
            let requested = initialChapter ?? book.lastChapterIndex
            let ratio = initialChapter == nil ? book.chapterProgress : 0
            initialChapter = nil
            let start = min(max(requested, 0), chapterCount - 1)
            loadChapter(start, restoreRatio: ratio)
            if let query = initialSearchQuery?
                .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                searchQuery = query
                pendingSearchQuery = query
            }
            initialSearchQuery = nil
        }
        isLoading = false
    }

    private func loadEPUB() throws {
        let containerURL = bookRoot.appendingPathComponent("META-INF/container.xml")
        let containerData = try Data(contentsOf: containerURL)
        guard let rootfile = EbookCore.rootfilePath(container: containerData) else {
            throw EbookImporter.ImportError.invalidEPUB
        }
        let opfData = try Data(contentsOf: bookRoot.appendingPathComponent(rootfile))
        guard let package = EbookCore.parseOPF(opfData, opfPath: rootfile) else {
            throw EbookImporter.ImportError.invalidEPUB
        }
        chapters = package.chapters
        var tocItems: [EbookCore.TOCItem] = []
        if let navHref = package.navHref,
           let data = try? Data(contentsOf: bookRoot.appendingPathComponent(navHref)) {
            tocItems = EbookCore.parseNav(data, opfDirectory: package.opfDirectory)
        }
        if tocItems.isEmpty, let ncxHref = package.ncxHref,
           let data = try? Data(contentsOf: bookRoot.appendingPathComponent(ncxHref)) {
            tocItems = EbookCore.parseNCX(data, opfDirectory: package.opfDirectory)
        }
        if tocItems.isEmpty {
            tocItems = chapters.map {
                EbookCore.TOCItem(title: $0.title, href: $0.href, level: 0,
                                  chapterIndex: $0.index)
            }
        }
        toc = EbookCore.applyingTOC(tocItems, to: chapters)
    }

    private func loadTXT() throws {
        let data = try Data(contentsOf: EbookLibraryStore.shared.contentURL(for: book))
        guard let text = EbookCore.decodeTXT(data) else {
            throw EbookImporter.ImportError.emptyText
        }
        txtChapters = EbookCore.splitTXT(text)
        guard !txtChapters.isEmpty else {
            throw EbookImporter.ImportError.emptyText
        }
        chapters = []
        toc = txtChapters.map { chapter in
            EbookCore.TOCItem(title: chapter.title, href: "", level: 0,
                              chapterIndex: chapter.index)
        }
    }

    private func loadMarkdown() throws {
        let data = try Data(contentsOf: EbookLibraryStore.shared.contentURL(for: book))
        guard let text = EbookCore.decodeTXT(data) else {
            throw EbookImporter.ImportError.emptyText
        }
        txtChapters = EbookCore.splitMarkdown(text)
        guard !txtChapters.isEmpty else {
            throw EbookImporter.ImportError.emptyText
        }
        chapters = []
        toc = txtChapters.map { chapter in
            EbookCore.TOCItem(title: chapter.title, href: "", level: 0,
                              chapterIndex: chapter.index)
        }
    }

    private func loadHTMLBook() throws {
        let data = try Data(contentsOf: EbookLibraryStore.shared.contentURL(for: book))
        guard let text = EbookCore.decodeTXT(data),
              !EbookSearchCore.plainText(fromHTML: text)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EbookImporter.ImportError.emptyText
        }
        chapters = [EbookCore.Chapter(index: 0, title: book.title, href: book.fileName)]
        txtChapters = []
        toc = [EbookCore.TOCItem(title: book.title, href: book.fileName, level: 0,
                                 chapterIndex: 0)]
    }

    func loadChapter(_ index: Int, restoreRatio: Double? = nil) {
        let count = chapterCount
        guard count > 0 else { return }
        let target = min(max(index, 0), count - 1)
        currentChapter = target
        loadGeneration += 1
        self.restoreRatio = restoreRatio
        pageIndex = 0
        pageCount = 1
        pageTurnRequest = nil
        pendingRevealHighlightID = nil
        translationLanguage = nil
        do {
            let html: String
            if book.format == .epub || book.format == .html {
                guard chapters.indices.contains(target) else { return }
                let chapter = chapters[target]
                chapterTitle = chapter.title
                let file = bookRoot.appendingPathComponent(chapter.href)
                let data = try Data(contentsOf: file)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                html = wrap(html: EbookCore.sanitizeHTML(text),
                            directory: file.deletingLastPathComponent())
                htmlFileURL = try writeReaderHTML(html, in: file.deletingLastPathComponent(),
                                                  index: target)
            } else if book.format == .markdown {
                guard txtChapters.indices.contains(target) else { return }
                let chapter = txtChapters[target]
                chapterTitle = chapter.title
                let body = "<h1>\(EbookCore.escapeHTML(chapter.title))</h1>"
                    + MarkdownHTMLCore.html(chapter.text)
                html = wrap(html: body, directory: bookRoot)
                htmlFileURL = try writeReaderHTML(html, in: bookRoot, index: target)
            } else {
                guard txtChapters.indices.contains(target) else { return }
                let chapter = txtChapters[target]
                chapterTitle = chapter.title
                let body = "<h1>\(EbookCore.escapeHTML(chapter.title))</h1>"
                    + EbookCore.txtHTML(chapter.text)
                html = wrap(html: body, directory: bookRoot)
                htmlFileURL = try writeReaderHTML(html, in: bookRoot, index: target)
            }
            chapterProgress = min(max(restoreRatio ?? 0, 0), 1)
            saveProgress(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 每次重载用唯一临时文件名——同一路径不会触发 WKWebView 重新加载
    /// （主题/字号/布局/搜索跳转重载同一章时曾整章不刷新）。
    private func writeReaderHTML(_ html: String, in directory: URL,
                                 index: Int) throws -> URL {
        let manager = FileManager.default
        if let existing = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix(".__desire_reader_\(index)-") {
                try? manager.removeItem(at: url)
            }
        }
        let url = directory.appendingPathComponent(
            ".__desire_reader_\(index)-\(UUID().uuidString).html")
        try Data(html.utf8).write(to: url, options: .atomic)
        return url
    }

    func nextChapter() {
        guard currentChapter + 1 < chapterCount else { return }
        stopSpeechForNavigation()
        saveProgress(force: true)
        loadChapter(currentChapter + 1, restoreRatio: 0)
    }

    func previousChapter() {
        guard currentChapter > 0 else { return }
        stopSpeechForNavigation()
        saveProgress(force: true)
        loadChapter(currentChapter - 1, restoreRatio: 0)
    }

    /// 分页模式：下一页；章末自动进下一章。
    func nextPage() {
        clearSelection()
        stopSpeechForNavigation()
        guard layoutMode == .paged else { nextChapter(); return }
        guard pageIndex + 1 < pageCount else {
            nextChapter()
            return
        }
        let target = pageIndex + 1
        pageIndex = target
        updatePageProgress()
        pageTurnRequest = EbookPageTurnRequest(id: UUID(), target: target, forward: true)
        notePageTurned()
        saveProgress(force: true)
    }

    /// 分页模式：上一页；章首回上一章末页。
    func previousPage() {
        clearSelection()
        stopSpeechForNavigation()
        guard layoutMode == .paged else { previousChapter(); return }
        guard pageIndex > 0 else {
            guard currentChapter > 0 else { return }
            saveProgress(force: true)
            loadChapter(currentChapter - 1, restoreRatio: 1)
            return
        }
        let target = pageIndex - 1
        pageIndex = target
        updatePageProgress()
        pageTurnRequest = EbookPageTurnRequest(id: UUID(), target: target, forward: false)
        saveProgress(force: true)
    }

    /// WebView 报告分页结果（首屏/字体加载/旋转后）。
    func updatePages(count: Int, index: Int) {
        pageCount = max(1, count)
        pageIndex = min(max(index, 0), pageCount - 1)
        if layoutMode == .paged, let ratio = restoreRatio {
            restoreRatio = nil
            let target = pageCount > 1
                ? Int((ratio * Double(pageCount - 1)).rounded()) : 0
            if target != pageIndex {
                pageIndex = min(max(target, 0), pageCount - 1)
                webView?.evaluateJavaScript(
                    "window.__desireGoToPage && window.__desireGoToPage(\(pageIndex), false);",
                    completionHandler: nil)
            }
        }
        updatePageProgress()
        saveProgress()
        revealPendingHighlight()
        highlightSearchIfNeeded()
    }

    private func updatePageProgress() {
        chapterProgress = pageCount > 1
            ? Double(pageIndex) / Double(pageCount - 1)
            : 0
    }

    func jump(toChapter index: Int) {
        clearSelection()
        guard index != currentChapter else { return }
        stopSpeechForNavigation()
        saveProgress(force: true)
        loadChapter(index, restoreRatio: 0)
    }

    func updateChapterProgress(_ ratio: Double) {
        guard layoutMode == .scroll else { return }
        chapterProgress = min(max(ratio, 0), 1)
        saveProgress()
    }

    func seek(to ratio: Double) {
        if layoutMode == .paged {
            guard pageCount > 1 else { return }
            let target = Int((min(max(ratio, 0), 1) * Double(pageCount - 1)).rounded())
            guard target != pageIndex else { return }
            let forward = target > pageIndex
            pageIndex = target
            updatePageProgress()
            pageTurnRequest = EbookPageTurnRequest(id: UUID(), target: target, forward: forward)
            saveProgress(force: true)
            return
        }
        chapterProgress = min(max(ratio, 0), 1)
        webView?.evaluateJavaScript(
            "window.__desireScrollTo && window.__desireScrollTo(\(chapterProgress));",
            completionHandler: nil)
        saveProgress(force: true)
    }

    func applyLayoutMode(_ mode: LayoutMode) {
        guard layoutMode != mode else { return }
        layoutMode = mode
        reloadCurrent()
    }

    func applyTheme(_ theme: Theme) {
        guard self.theme != theme else { return }
        self.theme = theme
        reloadCurrent()
    }

    func applyFontSize(_ size: Double) {
        let clamped = min(max(size, 12), 32)
        guard fontSize != clamped else { return }
        fontSize = clamped
        reloadCurrent()
    }

    func webViewReady(_ webView: WKWebView) {
        self.webView = webView
        webViewReadyGeneration = loadGeneration
        applyHighlights()
        restoreTranslationIfNeeded()
        guard layoutMode == .scroll else {
            revealPendingHighlight()
            highlightSearchIfNeeded()
            return
        }
        if let ratio = restoreRatio {
            restoreRatio = nil
            webView.evaluateJavaScript(
                "window.__desireScrollTo && window.__desireScrollTo(\(ratio));",
                completionHandler: nil)
        }
        revealPendingHighlight()
        highlightSearchIfNeeded()
    }

    func saveProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSaved) > 0.8 else { return }
        lastSaved = now
        EbookLibraryStore.shared.updateProgress(
            book.id, chapterIndex: currentChapter,
            chapterProgress: chapterProgress, overall: overallProgress)
        updateSession()
    }

    private func updateSession() {
        EbookReaderSession.shared.update(
            book: book, chapterIndex: currentChapter, chapterTitle: chapterTitle,
            chapterCount: chapterCount, progress: overallProgress)
    }

    // MARK: - 阅读统计

    func startReadingSession() {
        updateSession()
        guard statsSessionStart == nil else { return }
        statsSessionStart = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushReadingTime()
            }
        }
        statsTimer = timer
    }

    func flushReadingTime() {
        guard let start = statsSessionStart else { return }
        let seconds = Int(Date().timeIntervalSince(start).rounded())
        statsSessionStart = Date()
        let pages = statsPagesSinceFlush
        statsPagesSinceFlush = 0
        guard seconds > 0 || pages > 0 else { return }
        ReadingStatsStore.shared.add(bookID: book.id, seconds: seconds, pages: pages)
    }

    func endReadingSession() {
        flushReadingTime()
        statsSessionStart = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func notePageTurned() {
        statsPagesSinceFlush += 1
    }

    // MARK: - 整章朗读

    private func stopSpeechForNavigation() {
        NotificationCenter.default.post(name: Notification.Name("readerSpeechStop"),
                                        object: nil)
    }

    /// 当前章纯文本（EPUB/HTML 从文件剥标签，TXT 直接取，Markdown 先转 HTML 再剥）。
    var chapterPlainText: String {
        switch book.format {
        case .txt, .markdown:
            guard txtChapters.indices.contains(currentChapter) else { return "" }
            let raw = txtChapters[currentChapter].text
            if book.format == .markdown {
                return EbookSearchCore.plainText(fromHTML: MarkdownHTMLCore.html(raw))
            }
            return raw
        case .epub, .html:
            guard chapters.indices.contains(currentChapter) else { return "" }
            let file = bookRoot.appendingPathComponent(chapters[currentChapter].href)
            guard let data = try? Data(contentsOf: file) else { return "" }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            return EbookSearchCore.plainText(fromHTML: html)
        default:
            return ""
        }
    }

    var hasNextChapter: Bool {
        currentChapter + 1 < chapterCount
    }

    /// 朗读进度 → 翻页/滚动位置（节流，避免逐词触发大量重排）。
    func speechProgress(location: Int, total: Int) {
        guard total > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpeechSeek) > 0.5 else { return }
        lastSpeechSeek = now
        seek(to: Double(location) / Double(total))
    }

    /// 整章读完：进下一章（调用方随后重新朗读）。
    @discardableResult
    func speechAdvanceChapter() -> Bool {
        guard hasNextChapter else { return false }
        nextChapter()
        return true
    }

    // MARK: - 书签

    var isCurrentBookmarked: Bool {
        bookmarks.contains { bookmark in
            guard bookmark.chapterIndex == currentChapter else { return false }
            if layoutMode == .paged {
                return bookmark.pageIndex == pageIndex
            }
            return abs(bookmark.chapterProgress - chapterProgress) < 0.015
        }
    }

    func toggleBookmark() {
        if let index = bookmarks.firstIndex(where: { bookmark in
            guard bookmark.chapterIndex == currentChapter else { return false }
            if layoutMode == .paged { return bookmark.pageIndex == pageIndex }
            return abs(bookmark.chapterProgress - chapterProgress) < 0.015
        }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(EbookBookmark(
                id: UUID(), chapterIndex: currentChapter,
                chapterProgress: chapterProgress, pageIndex: pageIndex,
                title: chapterTitle,
                snippet: layoutMode == .paged
                    ? "\(pageIndex + 1)/\(pageCount)"
                    : "\(Int(chapterProgress * 100))%",
                createdAt: Date()))
        }
        saveBookmarks()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    func jumpToBookmark(_ bookmark: EbookBookmark) {
        stopSpeechForNavigation()
        pendingSearchQuery = nil
        loadChapter(bookmark.chapterIndex, restoreRatio: bookmark.chapterProgress)
        if layoutMode == .paged {
            pendingSearchQuery = nil
        }
    }

    private func saveBookmarks() {
        DiskStore.save(bookmarks, key: bookmarkKey)
    }

    // MARK: - 高亮与笔记

    /// 收录一条高亮（同时进摘录库）；同章同位置重复收录只返回已有条目。
    func addHighlight(from selection: EbookSelection, note: String?,
                      color: EbookHighlightColor = .yellow) -> EbookHighlightCreation? {
        let quote = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate: EbookHighlight? = selection.startOffset >= 0
            && selection.endOffset > selection.startOffset
            ? highlights.first {
                $0.chapterIndex == currentChapter
                    && $0.startOffset == selection.startOffset
                    && $0.endOffset == selection.endOffset
            }
            : highlights.first {
                $0.chapterIndex == currentChapter && $0.quote == quote
            }
        if var existing = duplicate {
            if let note = trimmedNote, !note.isEmpty, note != existing.trimmedNote {
                setHighlightNote(existing.id, note: note)
                existing.note = note
            }
            return EbookHighlightCreation(highlight: existing, isNew: false,
                                          excerptAdded: false)
        }
        let highlight = EbookHighlight(
            chapterIndex: currentChapter,
            chapterTitle: chapterTitle,
            chapterProgress: chapterProgress,
            quote: quote,
            startOffset: selection.startOffset,
            endOffset: selection.endOffset,
            color: color,
            note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote)
        highlights.append(highlight)
        saveHighlights()
        applyHighlights()
        let excerptAdded = ExcerptStore.shared.add(
            kind: .readerHighlight, title: book.title, source: bookRoot.path,
            content: quote, note: highlight.trimmedNote)
        return EbookHighlightCreation(highlight: highlight, isNew: true,
                                      excerptAdded: excerptAdded)
    }

    func setHighlightNote(_ id: UUID, note: String?) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        highlights[index].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveHighlights()
        if let excerptID = ExcerptStore.shared.excerptID(
            kind: .readerHighlight, source: bookRoot.path,
            content: highlights[index].quote) {
            ExcerptStore.shared.updateNote(id: excerptID, note: highlights[index].note)
        }
    }

    func setHighlightColor(_ id: UUID, _ color: EbookHighlightColor) {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              highlights[index].color != color else { return }
        highlights[index].color = color
        saveHighlights()
        applyHighlights()
    }

    /// 删除高亮只删书内标记；摘录库里的那条默认保留（侧栏有"已存摘录"语义）。
    func removeHighlight(_ id: UUID) {
        guard highlights.contains(where: { $0.id == id }) else { return }
        highlights.removeAll { $0.id == id }
        if focusedHighlightID == id { focusedHighlightID = nil }
        saveHighlights()
        applyHighlights()
    }

    /// 点正文高亮：打开笔记侧栏并定位。
    func openHighlight(_ id: UUID) {
        guard highlights.contains(where: { $0.id == id }) else { return }
        focusedHighlightID = id
        showNotes = true
    }

    /// 从侧栏跳回正文：换章后按偏移滚/翻到标记处。
    func jumpToHighlight(_ highlight: EbookHighlight) {
        showNotes = false
        focusedHighlightID = highlight.id
        if highlight.chapterIndex != currentChapter {
            stopSpeechForNavigation()
            loadChapter(highlight.chapterIndex, restoreRatio: highlight.chapterProgress)
        }
        pendingRevealHighlightID = highlight.id
        revealPendingHighlight()
    }

    private var currentChapterHighlights: [EbookHighlight] {
        highlights.filter { $0.chapterIndex == currentChapter }
    }

    private func saveHighlights() {
        EbookHighlightStore.save(highlights, for: book.id)
    }

    private func applyHighlights() {
        guard webViewReadyGeneration == loadGeneration else { return }
        let payload = EbookHighlightJS.payload(currentChapterHighlights)
        webView?.evaluateJavaScript(
            "window.__desireSetHighlights && window.__desireSetHighlights(\(payload));",
            completionHandler: nil)
    }

    private func revealPendingHighlight() {
        guard let id = pendingRevealHighlightID,
              webViewReadyGeneration == loadGeneration else { return }
        let literal = Self.jsString(id.uuidString.lowercased())
        webView?.evaluateJavaScript(
            "window.__desireRevealHighlight && window.__desireRevealHighlight(\(literal));"
        ) { [weak self] result, _ in
            guard let self else { return }
            Task { @MainActor in
                if (result as? Bool) == true {
                    self.pendingRevealHighlightID = nil
                }
            }
        }
    }

    // MARK: - 整章翻译

    var hasTranslation: Bool { translationLanguage != nil }

    func cachedTranslation(language: String) -> [Int: String]? {
        translationCache.translations(chapter: currentChapter, language: language)
    }

    /// 当前章可翻译的块（p/h1-h4/li，不含译文与代码块）。
    func translationBlocks() async -> [EbookTranslationBlock] {
        for attempt in 0..<2 {
            if let raw = try? await webView?.evaluateJavaScript(
                "window.__desireBlocks && window.__desireBlocks()") as? String,
               let data = raw.data(using: .utf8),
               let blocks = try? JSONDecoder().decode(
                [EbookTranslationBlock].self, from: data),
               !blocks.isEmpty {
                return blocks
            }
            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
        return []
    }

    func applyTranslation(_ translations: [Int: String], language: String) {
        translationCache.save(chapter: currentChapter, language: language,
                              translations: translations)
        EbookTranslationStore.save(translationCache, for: book.id)
        translationLanguage = language
        lastTranslationLanguage = language
        translationAuto = true
        let json = EbookTranslationJS.payload(translations)
        webView?.evaluateJavaScript(
            "window.__desireSetTranslations && window.__desireSetTranslations(\(json));",
            completionHandler: nil)
    }

    func clearTranslation() {
        translationLanguage = nil
        translationAuto = false
        webView?.evaluateJavaScript(
            "window.__desireClearTranslations && window.__desireClearTranslations();",
            completionHandler: nil)
    }

    /// 切章/重载后，如果之前开着翻译且有该章缓存，自动恢复。
    private func restoreTranslationIfNeeded() {
        guard translationAuto, let language = lastTranslationLanguage,
              let cached = translationCache.translations(
                chapter: currentChapter, language: language) else { return }
        translationLanguage = language
        let json = EbookTranslationJS.payload(cached)
        webView?.evaluateJavaScript(
            "window.__desireSetTranslations && window.__desireSetTranslations(\(json));",
            completionHandler: nil)
    }

    // MARK: - 书内搜索

    func search(_ query: String) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        if chapterTextCache == nil {
            let root = bookRoot
            let chapters = chapters
            let txt = txtChapters
            let epub = book.format == .epub || book.format == .html
            let texts: [EbookSearchCore.ChapterText]? = await Task.detached(
                priority: .userInitiated
            ) {
                if epub {
                    return chapters.compactMap { chapter -> EbookSearchCore.ChapterText? in
                        let url = root.appendingPathComponent(chapter.href)
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        let html = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .isoLatin1) ?? ""
                        return EbookSearchCore.ChapterText(
                            index: chapter.index, title: chapter.title,
                            text: EbookSearchCore.plainText(fromHTML: html))
                    }
                }
                return txt.map {
                    EbookSearchCore.ChapterText(index: $0.index, title: $0.title,
                                                text: $0.text)
                }
            }.value
            chapterTextCache = texts
        }
        let results = EbookSearchCore.search(
            query: needle, chapters: chapterTextCache ?? [])
        searchResults = results
        searchQuery = needle
    }

    func jump(to hit: EbookSearchCore.Hit) {
        showSearch = false
        clearSelection()
        stopSpeechForNavigation()
        pendingSearchQuery = searchQuery
        loadChapter(hit.chapterIndex, restoreRatio: 0)
    }

    func clearSearch() {
        searchResults = []
        searchQuery = ""
        pendingSearchQuery = nil
    }

    private func highlightSearchIfNeeded() {
        guard webViewReadyGeneration == loadGeneration,
              let query = pendingSearchQuery, !query.isEmpty else { return }
        let literal = Self.jsString(query)
        webView?.evaluateJavaScript(
            "window.__desireFind && window.__desireFind(\(literal));",
            completionHandler: nil)
    }

    private static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    func setSelection(_ selection: EbookSelection) {
        self.selection = selection
    }

    func clearSelection() {
        selection = nil
        webView?.evaluateJavaScript(
            "window.getSelection && window.getSelection().removeAllRanges();",
            completionHandler: nil)
    }

    private func reloadCurrent() {
        let ratio = chapterProgress
        loadChapter(currentChapter, restoreRatio: ratio)
    }

    // MARK: - HTML

    private func wrap(html: String, directory: URL) -> String {
        _ = directory
        switch layoutMode {
        case .scroll: return wrapScroll(html: html)
        case .paged: return wrapPaged(html: html)
        }
    }

    private func wrapScroll(html: String) -> String {
        let injection = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'self' data:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'">
        <style>\(readerCSS)</style>
        <script>
        (function(){
          function send(){
            var d=document.documentElement,b=document.body;
            var h=Math.max(d.scrollHeight,b.scrollHeight);
            var max=h-window.innerHeight;
            var r=max>0?Math.min(1,Math.max(0,window.scrollY/max)):0;
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookProgress){
              window.webkit.messageHandlers.ebookProgress.postMessage(r);
            }
          }
          window.addEventListener('scroll',send,{passive:true});
          window.addEventListener('resize',send);
          window.addEventListener('load',send);
          window.__desireScrollTo=function(r){
            var d=document.documentElement,b=document.body;
            var h=Math.max(d.scrollHeight,b.scrollHeight);
            var max=h-window.innerHeight;
            window.scrollTo(0,max*Math.max(0,Math.min(1,r)));
          };
          window.__desireFind=function(q){
            if(!q)return false;
            var needle=q.toLowerCase();
            var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);
            var nodes=[],node;
            while(node=walker.nextNode()){nodes.push(node);}
            var first=null;
            for(var i=0;i<nodes.length;i++){
              var textNode=nodes[i];
              var text=textNode.nodeValue||"";
              var idx=text.toLowerCase().indexOf(needle);
              if(idx<0)continue;
              try{
                var range=document.createRange();
                range.setStart(textNode,idx);
                range.setEnd(textNode,idx+needle.length);
                var mark=document.createElement('mark');
                mark.className='desire-search-hit';
                mark.style.background='#F6C344';
                mark.style.color='#1A1A1A';
                range.surroundContents(mark);
                if(!first)first=mark;
              }catch(e){}
            }
            if(first){first.scrollIntoView({block:'center'});return true;}
            return false;
          };
          document.addEventListener('mouseup', function(){
            setTimeout(function(){
              var sel=window.getSelection();
              if(!sel||sel.isCollapsed)return;
              var text=sel.toString().trim();
              if(!text)return;
              var range=sel.getRangeAt(0);
              var rect=range.getBoundingClientRect();
              if(rect.width<=0&&rect.height<=0)return;
              var anchor=window.__desireSelectionOffsets?window.__desireSelectionOffsets(range):null;
              if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookSelection){
                window.webkit.messageHandlers.ebookSelection.postMessage({
                  text:text,x:rect.left,y:rect.top,w:rect.width,h:rect.height,
                  s:anchor?anchor.s:-1,e:anchor?anchor.e:-1
                });
              }
            },0);
          });
        })();
        </script>
        <script>\(EbookHighlightJS.script(currentChapterHighlights))</script>
        <script>\(EbookTranslationJS.script())</script>
        """
        var document = html
        if let headEnd = document.range(of: "</head>", options: .caseInsensitive) {
            document.insert(contentsOf: injection, at: headEnd.lowerBound)
        } else if let bodyStart = document.range(of: "<body", options: .caseInsensitive) {
            document.insert(contentsOf: "<head>\(injection)</head>", at: bodyStart.lowerBound)
        } else {
            document = "<html><head>\(injection)</head><body>\(document)</body></html>"
        }
        return document
    }

    /// 分页：把正文装进固定高度多列容器；每页 = 一个列宽，横向位移翻页。
    private func wrapPaged(html: String) -> String {
        let parts = splitHeadBody(html)
        let injection = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'self' data:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'">
        <style>\(pagedCSS)</style>
        <script>
        document.addEventListener('DOMContentLoaded', function(){
          var flow=document.getElementById('desire-flow');
          var source=document.getElementById('desire-source');
          if(!flow||!source)return;
          var originalHTML=source.innerHTML;
          var index=0,pages=[];
          function post(){
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookPages){
              window.webkit.messageHandlers.ebookPages.postMessage({count:pages.length,index:index});
            }
          }
          function apply(){
            if(!flow)return;
            flow.style.transform='translateX('+(-index*flow.clientWidth)+'px)';
            post();
          }
          function flip(oldIndex, forward){
            var page=pages[oldIndex];
            if(!page)return;
            var rect=page.getBoundingClientRect();
            var clone=page.cloneNode(true);
            clone.classList.add('desire-turn-page');
            clone.style.position='fixed';
            clone.style.left=rect.left+'px';
            clone.style.top=rect.top+'px';
            clone.style.width=rect.width+'px';
            clone.style.height=rect.height+'px';
            clone.style.boxSizing='border-box';
            clone.style.zIndex='9999';
            clone.style.pointerEvents='none';
            clone.style.backfaceVisibility='hidden';
            clone.style.transformStyle='preserve-3d';
            clone.style.transformOrigin=forward?'left center':'right center';
            clone.style.boxShadow='0 0 22px rgba(0,0,0,.35)';
            document.body.appendChild(clone);
            clone.getBoundingClientRect();
            requestAnimationFrame(function(){
              clone.style.transition='transform .42s ease-in-out, opacity .42s ease-in-out';
              clone.style.transform=forward
                ? 'perspective(1400px) rotateY(-90deg)'
                : 'perspective(1400px) rotateY(90deg)';
              clone.style.opacity='0.25';
            });
            setTimeout(function(){clone.remove();},480);
          }
          function createPage(){
            var page=document.createElement('div');
            page.className='desire-page';
            flow.appendChild(page);
            return page;
          }
          function significantChildren(page){
            return Array.prototype.filter.call(page.childNodes,function(node){
              return !(node.nodeType===3 && !node.textContent.trim());
            });
          }
          function paginate(){
            source.innerHTML=originalHTML;
            if(window.__desireApplyTranslationsTo)window.__desireApplyTranslationsTo(source);
            flow.innerHTML='';
            pages=[];
            var page=createPage();
            pages.push(page);
            var nodes=Array.prototype.slice.call(source.childNodes);
            for(var i=0;i<nodes.length;i++){
              var node=nodes[i];
              if(node.nodeType===3 && !node.textContent.trim())continue;
              page.appendChild(node);
              if(page.scrollHeight>page.clientHeight+2 && significantChildren(page).length>1){
                page.removeChild(node);
                page=createPage();
                pages.push(page);
                page.appendChild(node);
              }
            }
            if(pages.length===0)pages.push(createPage());
            if(index>=pages.length)index=pages.length-1;
            apply();
            if(window.__desireApplyHighlights)window.__desireApplyHighlights();
          }
          window.__desireGoToPage=function(target, animate){
            var old=index;
            index=Math.max(0,Math.min(target,pages.length-1));
            if(old!==index && animate!==false)flip(old,index>old);
            apply();
          };
          function highlightIn(root,q){
            var needle=q.toLowerCase();
            var walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null);
            var nodes=[],node;
            while(node=walker.nextNode()){nodes.push(node);}
            var first=null;
            for(var i=0;i<nodes.length;i++){
              var textNode=nodes[i];
              var text=textNode.nodeValue||"";
              var idx=text.toLowerCase().indexOf(needle);
              if(idx<0)continue;
              try{
                var range=document.createRange();
                range.setStart(textNode,idx);
                range.setEnd(textNode,idx+needle.length);
                var mark=document.createElement('mark');
                mark.className='desire-search-hit';
                mark.style.background='#F6C344';
                mark.style.color='#1A1A1A';
                range.surroundContents(mark);
                if(!first)first=mark;
              }catch(e){}
            }
            return first;
          }
          window.__desireFind=function(q){
            if(!q)return false;
            var needle=q.toLowerCase();
            for(var i=0;i<pages.length;i++){
              if(pages[i].textContent.toLowerCase().indexOf(needle)>=0){
                index=i;
                highlightIn(pages[i],q);
                apply();
                return true;
              }
            }
            return false;
          };
          window.__desireMeasurePages=paginate;
          function schedule(){
            setTimeout(paginate,40);
            setTimeout(paginate,260);
            setTimeout(paginate,800);
          }
          window.addEventListener('load',schedule);
          if(document.fonts&&document.fonts.ready){document.fonts.ready.then(schedule);}
          setTimeout(paginate,60);
          document.addEventListener('mouseup', function(){
            setTimeout(function(){
              var sel=window.getSelection();
              if(!sel||sel.isCollapsed)return;
              var text=sel.toString().trim();
              if(!text)return;
              var range=sel.getRangeAt(0);
              var rect=range.getBoundingClientRect();
              if(rect.width<=0&&rect.height<=0)return;
              var anchor=window.__desireSelectionOffsets?window.__desireSelectionOffsets(range):null;
              if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookSelection){
                window.webkit.messageHandlers.ebookSelection.postMessage({
                  text:text,x:rect.left,y:rect.top,w:rect.width,h:rect.height,
                  s:anchor?anchor.s:-1,e:anchor?anchor.e:-1
                });
              }
            },0);
          });
        });
        </script>
        <script>\(EbookHighlightJS.script(currentChapterHighlights))</script>
        <script>\(EbookTranslationJS.script())</script>
        """
        return """
        <!doctype html><html><head>\(parts.head)\(injection)</head>
        <body>
        <div class="desire-viewport"><div class="desire-flow" id="desire-flow"></div></div>
        <div id="desire-source" style="display:none">\(parts.body)</div>
        </body></html>
        """
    }

    private func splitHeadBody(_ html: String) -> (head: String, body: String) {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                let match = regex.firstMatch(in: html,
                                             range: NSRange(html.startIndex..., in: html)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        let head = capture("<head\\b[^>]*>([\\s\\S]*?)</head>") ?? ""
        let body = capture("<body\\b[^>]*>([\\s\\S]*?)</body>") ?? html
        return (head, body)
    }

    private var readerCSS: String {
        """
        html, body { background: \(theme.background) !important; color: \(theme.foreground) !important; }
        body {
          font-family: -apple-system, "Songti SC", "Noto Serif SC", serif !important;
          font-size: \(Int(fontSize))px !important;
          line-height: 1.85 !important;
          margin: 0 auto !important;
          padding: 34px 18px 56px !important;
          max-width: 780px !important;
          text-align: left;
          word-wrap: break-word;
        }
        p { margin: 0 0 1.05em 0 !important; }
        h1, h2, h3, h4 { color: \(theme.foreground) !important; line-height: 1.35; }
        h1 { font-size: 1.55em; margin: 1.2em 0 0.7em; }
        h2 { font-size: 1.3em; margin: 1.2em 0 0.6em; }
        a { color: \(theme.link) !important; }
        img, svg, video { max-width: 100% !important; height: auto !important; }
        blockquote { border-left: 3px solid \(theme.link); margin-left: 0; padding-left: 1em; opacity: 0.9; }
        pre, code { white-space: pre-wrap; word-wrap: break-word; }
        ::selection { background: \(theme.link)55; }
        mark[data-ebook-highlight] { border-radius: 2px; }
        mark.desire-highlight-flash { outline: 2px solid #FF9F0A; outline-offset: 1px; }
        .desire-translation {
          display: block; font-size: 0.86em; line-height: 1.5;
          opacity: 0.72; margin-top: 0.35em; padding-left: 0.55em;
          border-left: 2px solid currentColor;
        }
        """
    }

    private var pagedCSS: String {
        """
        html, body { margin: 0; padding: 0; height: 100%; overflow: hidden;
          background: \(theme.background) !important; color: \(theme.foreground) !important; }
        body {
          font-family: -apple-system, "Songti SC", "Noto Serif SC", serif;
          font-size: \(Int(fontSize))px;
          line-height: 1.85;
        }
        .desire-viewport {
          position: fixed; inset: 0;
          display: flex; justify-content: center;
          background: \(theme.background);
          overflow: hidden;
        }
        .desire-flow {
          display: flex; flex-direction: row;
          height: 100%; width: min(100vw, 900px);
          transform: translateX(0); will-change: transform;
          color: \(theme.foreground);
        }
        .desire-page {
          flex: 0 0 100%; width: 100%; height: 100%;
          overflow: hidden; box-sizing: border-box;
          padding: 42px 52px 34px;
          background: \(theme.background);
          word-wrap: break-word;
        }
        .desire-page p { margin: 0 0 1.05em 0 !important; }
        .desire-page h1, .desire-page h2, .desire-page h3, .desire-page h4 {
          color: \(theme.foreground) !important; line-height: 1.35;
        }
        .desire-page h1 { font-size: 1.65em; margin: 0 0 0.8em; }
        .desire-page h2 { font-size: 1.35em; margin: 1em 0 0.6em; }
        .desire-page a { color: \(theme.link) !important; }
        .desire-page img, .desire-page svg, .desire-page video {
          max-width: 100% !important; max-height: 100% !important;
          height: auto !important;
        }
        .desire-page blockquote {
          border-left: 3px solid \(theme.link); margin-left: 0;
          padding-left: 1em; opacity: 0.9;
        }
        .desire-page pre, .desire-page code { white-space: pre-wrap; word-wrap: break-word; }
        ::selection { background: \(theme.link)55; }
        mark[data-ebook-highlight] { border-radius: 2px; }
        mark.desire-highlight-flash { outline: 2px solid #FF9F0A; outline-offset: 1px; }
        .desire-translation {
          display: block; font-size: 0.86em; line-height: 1.5;
          opacity: 0.72; margin-top: 0.35em; padding-left: 0.55em;
          border-left: 2px solid currentColor;
        }
        """
    }
}
