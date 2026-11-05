import AppKit
import PDFKit
import SwiftUI
import Translation

/// PDF 阅读器（v0.8.44）：书架里的 PDF 用 PDFKit 翻页阅读，进度/书签/目录/
/// 统计/文本层三大件（逐段朗读/翻译对照/搜索）/摘录批注与 EPUB 同待遇。
/// 语义映射：`lastChapterIndex` = 页索引（0 起，与 CBZ 漫画阅读器同口径），
/// `chapterProgress`/`progress` = 页码比例。
/// 批注持久化：用户高亮写在 `annotations.pdf`（书文件旁，外部阅读器兼容）；
/// 翻译/搜索临时标记（userName="desire-*"）不落盘，重开即清。
struct EbookPDFReaderView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let book: Ebook
    /// 深链起始页（0 起，`desire://books/<id>?chapter=N` 语义沿用）。
    var initialPage: Int?
    let onBack: () -> Void

    @State private var document: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var loading = true
    @State private var error: String?
    @State private var showTwoUp = false
    @State private var showTOC = false
    @State private var showBookmarks = false
    @State private var showSearch = false
    @State private var toc: [TOCEntry] = []
    @State private var bookmarks: [EbookBookmark] = []

    /// PDFView 句柄（NSViewRepresentable 创建时塞进来；跳页/切布局用）。
    @State private var box = PDFViewBox()

    // 阅读统计（口径同 EbookReaderModel：30s 一冲，页数另计）
    @State private var statsSessionStart: Date?
    @State private var statsPagesSinceFlush = 0
    @State private var statsTimer: Timer?

    // MARK: 文本层（批 2）

    @ObservedObject private var speech = ReaderSpeechService.shared
    /// 全书页文本缓存（首次朗读/搜索时抽取，之后复用）
    @State private var pageTexts: [PDFTextCore.PageText]?
    @State private var isExtracting = false

    // 搜索
    @State private var searchQuery = ""
    @State private var searchResults: [PDFTextCore.Hit] = []
    @State private var didSearch = false
    @State private var isSearching = false

    // 翻译对照（按页）：译文以 freeText 注解插在段落下沿
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationPhase: TranslationPhase = .idle
    @State private var translationProgress: Double = 0
    @State private var translationHidden = false
    @State private var translatingPage = -1
    @State private var translationParagraphs: [PDFTextCore.Paragraph] = []

    // 跳页
    @State private var showGoPage = false
    @State private var goPageText = ""
    @FocusState private var goPageFocused: Bool

    // 摘录/批注
    @State private var selectionText: String?
    @State private var annotationsDirty = false
    @State private var flashNote: String?

    enum TranslationPhase: Equatable {
        case idle, translating, done, failed(String)
    }

    nonisolated struct TOCEntry: Identifiable {
        let id = UUID()
        var title: String
        var level: Int
        var pageIndex: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let document {
                    PDFKitView(document: document,
                               initialPage: restoredPage,
                               twoUp: showTwoUp,
                               box: box,
                               onPageChange: { index in
                                   handlePageChange(index)
                               },
                               onSelection: { text in
                                   selectionText = text
                               })
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if isExtracting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                if let flashNote {
                    Text(flashNote)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .task { load() }
        .onDisappear {
            saveProgress()
            flushReadingTime()
            statsSessionStart = nil
            statsTimer?.invalidate()
            statsTimer = nil
            speech.onParagraphChange = nil
            speech.stop()
            persistAnnotationsIfNeeded()
        }
        .popover(isPresented: $showTOC) {
            tocPanel
        }
        .popover(isPresented: $showBookmarks) {
            bookmarksPanel
        }
        .sheet(isPresented: $showSearch) {
            searchSheet
        }
        .translationTask(translationConfig) { session in
            await translateCurrentPage(session: session)
        }
        .onChange(of: flashNote) { _, note in
            guard note != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                flashNote = nil
            }
        }
    }

    private var restoredPage: Int {
        if let initialPage { return max(0, initialPage) }
        return max(0, book.lastChapterIndex)
    }

    // MARK: - 头部/底栏

    private var header: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                Label(String(localized: "Library"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(book.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()

            // 文本层三大件（批 2）
            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(document == nil)
            .help(String(localized: "Search in book"))

            if let source = selectionText,
               !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    addExcerptFromSelection()
                } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Highlight selection"))
            }

            speechControls

            translationMenu

            Button {
                showBookmarks = true
            } label: {
                Image(systemName: isCurrentPageBookmarked
                      ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCurrentPageBookmarked ? appAccent : Color.secondary)
            .disabled(document == nil)
            .help(String(localized: "Bookmarks"))

            if !toc.isEmpty {
                Button {
                    showTOC = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Contents"))
            }

            Button {
                showTwoUp.toggle()
            } label: {
                Image(systemName: showTwoUp
                      ? "rectangle.righthalf.inset.filled"
                      : "rectangle.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showTwoUp ? "Single Page" : "Two Pages")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 朗读控件（逐段）：未在讲 = 喇叭开讲；在讲 = 上一段/计数/下一段 + 暂停/停止。
    @ViewBuilder
    private var speechControls: some View {
        if speech.isSpeaking {
            HStack(spacing: 4) {
                if speech.paragraphCount > 0 {
                    Button {
                        speech.speakParagraphJump(-1)
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .opacity(speech.canJumpPrevious ? 1 : 0.35)
                    .help("Previous Paragraph")

                    Text("\(speech.currentParagraphIndex.map { $0 + 1 } ?? 1)/\(speech.paragraphCount)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        speech.speakParagraphJump(1)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .opacity(speech.canJumpNext ? 1 : 0.35)
                    .help("Next Paragraph")
                }

                Button {
                    speech.togglePause()
                } label: {
                    Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(speech.isPaused ? "Resume Reading" : "Pause Reading")

                Button {
                    speech.stop()
                    speech.onParagraphChange = nil
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop Reading")
            }
            .foregroundStyle(appAccent)
        } else {
            Button {
                startSpeech()
            } label: {
                Image(systemName: "speaker.wave.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(document == nil)
            .help("Read Aloud")
        }
    }

    /// 翻译菜单（按页对照）：Translate Page / Hide / Show / Clear。
    @ViewBuilder
    private var translationMenu: some View {
        if translationPhase == .translating {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        }
        Menu {
            if translationPhase == .done || translationPhase == .idle,
               translatingPage >= 0 {
                Button(translationHidden
                       ? String(localized: "Show Translation")
                       : String(localized: "Hide Translation")) {
                    translationHidden.toggle()
                    setTranslationAnnotationsHidden(translationHidden)
                }
                Button(String(localized: "Clear Translation")) {
                    clearTranslationAnnotations()
                    translationPhase = .idle
                    translatingPage = -1
                    translationParagraphs = []
                }
            } else if translationPhase != .translating {
                Button(String(localized: "Translate")) {
                    startTranslation()
                }
            }
            if case .failed(let message) = translationPhase {
                Section {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Image(systemName: translationPhase == .done
                  ? "character.bubble.fill" : "character.bubble")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .disabled(document == nil)
        .help("Translation")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { go(to: pageIndex - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)
            Slider(value: Binding(
                get: { pageCount > 1 ? Double(pageIndex) / Double(pageCount - 1) : 0 },
                set: { value in
                    let target = Int((value * Double(pageCount - 1)).rounded())
                    go(to: target)
                }
            ), in: 0...1)
            .controlSize(.small)
            .frame(maxWidth: 460)
            Button { go(to: pageIndex + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(pageCount == 0 || pageIndex + 1 >= pageCount)
            Button {
                goPageText = pageCount > 0 ? "\(pageIndex + 1)" : ""
                showGoPage = true
            } label: {
                Text(verbatim: "\(pageCount == 0 ? 0 : pageIndex + 1)/\(pageCount)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showGoPage) {
                goPagePanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 跳页

    /// 页码输入（点击底栏"N/M"弹出；@FocusState 延迟置真——直接置真不生效）。
    private var goPagePanel: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Go to Page"))
                .font(.system(size: 11.5, weight: .semibold))
            TextField("1", text: $goPageText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 64)
                .focused($goPageFocused)
                .onSubmit { submitGoPage() }
            Button(String(localized: "Go")) { submitGoPage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                goPageFocused = true
            }
        }
    }

    private func submitGoPage() {
        guard let page = Int(goPageText.trimmingCharacters(in: .whitespaces)),
              page >= 1, page <= pageCount else { return }
        showGoPage = false
        go(to: page - 1)
    }

    // MARK: - 目录面板

    private var tocPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Contents"))
                .font(.system(size: 12.5, weight: .semibold))
                .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(toc) { entry in
                        Button {
                            showTOC = false
                            go(to: entry.pageIndex)
                        } label: {
                            Text(entry.title)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity,
                                       alignment: .leading)
                                .padding(.leading, CGFloat(12 + entry.level * 14))
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: 420)
    }

    // MARK: - 书签面板

    private var bookmarksPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Bookmarks"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button {
                    toggleBookmark()
                } label: {
                    Image(systemName: isCurrentPageBookmarked
                          ? "bookmark.slash" : "bookmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isCurrentPageBookmarked
                      ? String(localized: "Remove Bookmark")
                      : String(localized: "Add Bookmark"))
            }
            .padding(12)
            Divider()
            if bookmarks.isEmpty {
                Text(String(localized: "No bookmarks yet"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                showBookmarks = false
                                go(to: bookmark.chapterIndex)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(appAccent)
                                    if !bookmark.snippet.isEmpty {
                                        Text(bookmark.snippet)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(String(localized: "Remove Bookmark"),
                                       role: .destructive) {
                                    removeBookmark(bookmark.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 340, height: 420)
    }

    // MARK: - 搜索面板

    private var searchSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Search in book"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { showSearch = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Search in book"), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { runSearch() }
                Button(String(localized: "Search")) { runSearch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didSearch && searchResults.isEmpty {
                Text(String(localized: "No results"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(searchResults) { hit in
                            Button {
                                jump(to: hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "Page \(hit.pageIndex + 1)"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(appAccent)
                                    Text(hit.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 500, height: 540)
    }

    private func runSearch() {
        isSearching = true
        didSearch = false
        let query = searchQuery
        Task { @MainActor in
            let pages = await ensurePageTexts()
            searchResults = PDFTextCore.search(query: query, pages: pages)
            isSearching = false
            didSearch = true
        }
    }

    private func jump(to hit: PDFTextCore.Hit) {
        showSearch = false
        go(to: hit.pageIndex)
        markSearchHit(query: searchQuery, pageIndex: hit.pageIndex,
                      occurrence: hit.occurrence)
    }

    /// 在页面上标出第 occurrence 处命中并滚到该处（临时注解，不落盘）。
    private func markSearchHit(query: String, pageIndex target: Int, occurrence: Int) {
        guard let document,
              let page = document.page(at: target) else { return }
        // 清旧标记
        for old in page.annotations where old.userName == "desire-search-hit" {
            page.removeAnnotation(old)
        }
        let selections = document.findString(query, withOptions: [.caseInsensitive])
        let pageSelections = selections.filter {
            document.index(for: $0.pages.first ?? page) == target
        }
        guard pageSelections.indices.contains(occurrence) else { return }
        let selection = pageSelections[occurrence]
        let bounds = selection.bounds(for: page)
        let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        mark.color = NSColor(red: 0.96, green: 0.76, blue: 0.27, alpha: 0.6)
        mark.userName = "desire-search-hit"
        page.addAnnotation(mark)
        box.view?.go(to: selection)
    }

    // MARK: - 加载

    private func load() {
        loading = true
        bookmarks = EbookBookmarkStore.load(book.id)
        let sourceURL = EbookImporter.pdfFileURL(book)
        // 用户批注版本优先（annotations.pdf = 源文件 + 高亮，外部阅读器也认）
        let container = sourceURL.deletingLastPathComponent()
        let annotated = container.appendingPathComponent("annotations.pdf")
        let url = FileManager.default.fileExists(atPath: annotated.path)
            ? annotated : sourceURL
        let (loaded, entries, locked) = Self.openDocument(url: url)
        document = loaded
        toc = entries
        loading = false
        if let loaded {
            pageCount = loaded.pageCount
            pageIndex = min(max(restoredPage, 0), max(0, loaded.pageCount - 1))
            startStatsTimer()
        } else if locked {
            error = String(localized: "This PDF is password-protected and cannot be opened.")
        } else {
            error = String(localized: "This PDF could not be opened.")
        }
    }

    /// 打开并摊平目录（只留页索引，Sendable 安全）。同步在主线程做——
    /// 书架 PDF 是用户文件，打开成本与 Preview 相当；后台传 PDFDocument
    /// 反而要跨隔离域搬非 Sendable 对象。
    nonisolated private static func openDocument(
        url: URL) -> (PDFDocument?, [TOCEntry], Bool) {
        guard let document = PDFDocument(url: url) else { return (nil, [], false) }
        guard !document.isLocked else { return (nil, [], true) }
        var entries: [TOCEntry] = []
        func walk(_ outline: PDFOutline?, level: Int) {
            guard let outline, level < 6 else { return }
            for childIndex in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: childIndex) else { continue }
                if let destination = child.destination, let page = destination.page {
                    let index = document.index(for: page)
                    if index != NSNotFound, index >= 0 {
                        entries.append(TOCEntry(title: child.label ?? "",
                                                level: level, pageIndex: index))
                    }
                }
                walk(child, level: level + 1)
            }
        }
        walk(document.outlineRoot, level: 0)
        return (document, entries, false)
    }

    // MARK: - 翻页与进度

    private func handlePageChange(_ index: Int) {
        guard document != nil, index != pageIndex,
              index >= 0, index < max(pageCount, 1) else { return }
        pageIndex = index
        statsPagesSinceFlush += 1
        saveProgress()
    }

    private func go(to target: Int) {
        let clamped = min(max(target, 0), max(0, pageCount - 1))
        guard clamped != pageIndex else { return }
        pageIndex = clamped
        statsPagesSinceFlush += 1
        box.view?.go(to: PDFDestination(page: document?.page(at: clamped) ?? PDFPage(),
                                        at: .zero))
        saveProgress()
    }

    private func saveProgress() {
        guard pageCount > 0 else { return }
        let overall = Double(pageIndex) / Double(max(1, pageCount - 1))
        EbookLibraryStore.shared.updateProgress(
            book.id, chapterIndex: pageIndex, chapterProgress: overall, overall: overall)
    }

    // MARK: - 书签

    private var isCurrentPageBookmarked: Bool {
        bookmarks.contains { $0.chapterIndex == pageIndex }
    }

    private func toggleBookmark() {
        if let index = bookmarks.firstIndex(where: { $0.chapterIndex == pageIndex }) {
            let removed = bookmarks.remove(at: index)
            EbookBookmarkStore.save(bookmarks, for: book.id)
            EbookSyncStore.shared.noteBookmarkRemoved(
                bookHash: book.hash, bookmarkID: removed.id)
        } else {
            let pageText = document?.page(at: pageIndex)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = pageText.isEmpty
                ? String(localized: "Page \(pageIndex + 1)")
                : String(pageText.prefix(60))
            bookmarks.append(EbookBookmark(
                id: UUID(), chapterIndex: pageIndex, chapterProgress: 0,
                pageIndex: pageIndex,
                title: String(localized: "Page \(pageIndex + 1)"),
                snippet: snippet, createdAt: Date()))
            EbookBookmarkStore.save(bookmarks, for: book.id)
            EbookSyncStore.shared.bookmarkChanged()
        }
    }

    private func removeBookmark(_ id: UUID) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        bookmarks.removeAll { $0.id == id }
        EbookBookmarkStore.save(bookmarks, for: book.id)
        EbookSyncStore.shared.noteBookmarkRemoved(bookHash: book.hash, bookmarkID: id)
    }

    // MARK: - 文本层：页文本抽取

    /// 全书页文本（懒抽取，后台跑；PDFKit 文档说明 PDFDocument/PDFPage 可
    /// 跨线程访问，用 nonisolated(unsafe) 桥接严格并发）。
    private func ensurePageTexts() async -> [PDFTextCore.PageText] {
        if let pageTexts { return pageTexts }
        guard let document else { return [] }
        isExtracting = true
        defer { isExtracting = false }
        let count = document.pageCount
        nonisolated(unsafe) let doc = document
        let texts: [PDFTextCore.PageText] = await Task.detached(priority: .userInitiated) {
            (0..<count).map { index in
                PDFTextCore.PageText(index: index, text: doc.page(at: index)?.string ?? "")
            }
        }.value
        pageTexts = texts
        return texts
    }

    // MARK: - 逐段朗读

    /// 开讲：全书段落化（页锚点），段落切换时页面跟随跳页。
    private func startSpeech() {
        Task { @MainActor in
            let pages = await ensurePageTexts()
            let paragraphs = PDFTextCore.paragraphs(fromPages: pages)
            guard !paragraphs.isEmpty else {
                flashNote = String(localized: "This PDF has no readable text.")
                return
            }
            speech.onParagraphChange = { index in
                let target = paragraphs.indices.contains(index)
                    ? paragraphs[index].pageIndex : nil
                if let target, target != pageIndex {
                    go(to: target)
                }
            }
            speech.speakParagraphs(paragraphs.map(\.text))
        }
    }

    // MARK: - 翻译对照（按页）

    /// 当前页段落 → 批翻（8 段一批，批间渐进上屏）→ 段落下沿插入译文注解。
    private func startTranslation() {
        guard let document, let page = document.page(at: pageIndex) else { return }
        let raw = page.string ?? ""
        let paragraphs = PDFTextCore.paragraphs(
            fromPage: PDFTextCore.PageText(index: pageIndex, text: raw))
        guard !paragraphs.isEmpty else {
            flashNote = String(localized: "This page has no readable text.")
            return
        }
        translatingPage = pageIndex
        translationParagraphs = paragraphs
        translationProgress = 0
        translationHidden = false
        // 缓存命中直接回填（同语言）
        let source = ReaderTranslationModel.detectLanguage(
            paragraphs.prefix(3).map(\.text).joined(separator: " "))
        let target = ReaderTranslationModel.targetSpec(source: source)
        let cache = ReaderTranslationStore.load("pdf:\(book.hash)")
        if let cached = cache.translations(pageURL: "\(pageIndex)",
                                           language: target.cacheKey) {
            applyTranslationAnnotations(paragraphs: paragraphs,
                                        translations: cached)
            translationPhase = .done
            return
        }
        translationPhase = .translating
        var config = TranslationSession.Configuration(source: source,
                                                      target: target.language)
        config.invalidate()
        translationConfig = config
    }

    private func translateCurrentPage(session: TranslationSession) async {
        guard translationPhase == .translating,
              !translationParagraphs.isEmpty else { return }
        let paragraphs = translationParagraphs
        var result: [Int: String] = [:]
        let chunkSize = 8
        var cursor = 0
        do {
            while cursor < paragraphs.count {
                let chunk = Array(paragraphs[cursor..<min(cursor + chunkSize,
                                                          paragraphs.count)])
                let requests = chunk.map {
                    TranslationSession.Request(
                        sourceText: $0.text,
                        clientIdentifier: String($0.id))
                }
                let responses = try await session.translations(from: requests)
                for response in responses {
                    if let id = response.clientIdentifier.flatMap(Int.init) {
                        result[id] = response.targetText
                    }
                }
                cursor += chunkSize
                translationProgress = Double(min(cursor, paragraphs.count))
                    / Double(paragraphs.count)
                applyTranslationAnnotations(paragraphs: paragraphs,
                                            translations: result)
            }
            var cache = ReaderTranslationStore.load("pdf:\(book.hash)")
            cache.save(pageURL: "\(pageIndex)", language: currentTranslationLanguageKey(),
                       translations: result)
            ReaderTranslationStore.save(cache, for: "pdf:\(book.hash)")
            translationPhase = .done
        } catch {
            translationPhase = .failed(error.localizedDescription)
        }
    }

    /// 与 startTranslation 相同规则的目标语言缓存键（会话里拿不到，重算一次）。
    private func currentTranslationLanguageKey() -> String {
        let source = ReaderTranslationModel.detectLanguage(
            translationParagraphs.prefix(3).map(\.text).joined(separator: " "))
        return ReaderTranslationModel.targetSpec(source: source).cacheKey
    }

    /// 段落 → 页内锚点：取段落首行片段在 page.string 里定位选区 → bounds。
    private func paragraphBounds(_ paragraph: PDFTextCore.Paragraph,
                                 on page: PDFPage) -> CGRect? {
        guard let pageString = page.string else { return nil }
        // 段落文本是折行合并过的；锚定用"第一行"（第一个空格前的片段）
        let firstLine = paragraph.text
            .components(separatedBy: " ").first ?? paragraph.text
        let anchor = String(firstLine.prefix(40))
        guard !anchor.isEmpty else { return nil }
        let nsPage = pageString as NSString
        let range = nsPage.range(of: anchor, options: .caseInsensitive)
        guard range.location != NSNotFound else { return nil }
        guard let selection = page.selection(for: range) else { return nil }
        return selection.bounds(for: page)
    }

    /// 上屏译文：段落加浅黄高亮 + 下沿插 freeText 译文框。
    private func applyTranslationAnnotations(paragraphs: [PDFTextCore.Paragraph],
                                             translations: [Int: String]) {
        guard let document,
              let page = document.page(at: pageIndex),
              translations.isEmpty == false else { return }
        // 先清本轮旧译文注解（增量回填时重建）
        for old in page.annotations where old.userName == "desire-translation" {
            page.removeAnnotation(old)
        }
        let pageBounds = page.bounds(for: .cropBox)
        for paragraph in paragraphs {
            guard let translated = translations[paragraph.id], !translated.isEmpty else {
                continue
            }
            guard let bounds = paragraphBounds(paragraph, on: page) else { continue }
            // 段落高亮（浅黄，标记"这段有译文"）
            let highlight = PDFAnnotation(bounds: bounds, forType: .highlight,
                                          withProperties: nil)
            highlight.color = NSColor(red: 1, green: 0.85, blue: 0.35, alpha: 0.3)
            highlight.userName = "desire-translation"
            page.addAnnotation(highlight)
            // 译文框：段落正下方，宽度撑到页缘，高度 44pt（约两行小字）
            let boxWidth = max(80, pageBounds.width - bounds.minX - 36)
            let boxRect = CGRect(x: bounds.minX,
                                 y: max(pageBounds.minY, bounds.minY - 46),
                                 width: min(boxWidth, pageBounds.width - 24),
                                 height: 44)
            let note = PDFAnnotation(bounds: boxRect, forType: .freeText,
                                     withProperties: nil)
            note.contents = translated
            note.font = NSFont.systemFont(ofSize: 9)
            note.fontColor = .secondaryLabelColor
            note.backgroundColor = .clear
            note.isMultiline = true
            note.userName = "desire-translation"
            page.addAnnotation(note)
        }
    }

    private func setTranslationAnnotationsHidden(_ hidden: Bool) {
        // PDFKit 注解无隐藏属性——隐藏即移除（缓存还在，重新翻译页时回填）。
        if hidden {
            removeTranslationAnnotations()
        } else if translationPhase == .done, translatingPage == pageIndex {
            applyTranslationAnnotations(paragraphs: translationParagraphs,
                                        translations: cachedTranslationsForCurrentPage())
        }
    }

    private func cachedTranslationsForCurrentPage() -> [Int: String] {
        let source = ReaderTranslationModel.detectLanguage(
            translationParagraphs.prefix(3).map(\.text).joined(separator: " "))
        let key = ReaderTranslationModel.targetSpec(source: source).cacheKey
        return ReaderTranslationStore.load("pdf:\(book.hash)")
            .translations(pageURL: "\(pageIndex)", language: key) ?? [:]
    }

    private func clearTranslationAnnotations() {
        removeTranslationAnnotations()
        var cache = ReaderTranslationStore.load("pdf:\(book.hash)")
        cache.remove(pageURL: "\(pageIndex)")
        ReaderTranslationStore.save(cache, for: "pdf:\(book.hash)")
    }

    private func removeTranslationAnnotations() {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.userName == "desire-translation" {
                page.removeAnnotation(annotation)
            }
        }
    }

    // MARK: - 摘录与用户批注

    /// 划选 → 摘录库（pdfAnnotation 来源，excerpts 域同步）+ 页面高亮批注。
    private func addExcerptFromSelection() {
        guard let source = selectionText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty,
              let document,
              let page = document.page(at: pageIndex) else { return }
        _ = ExcerptStore.shared.add(
            kind: .pdfAnnotation, title: book.title,
            source: EbookImporter.pdfFileURL(book).path,
            content: source, bookHash: book.hash,
            chapterIndex: pageIndex,
            chapterTitle: String(localized: "Page \(pageIndex + 1)"))
        // 页面高亮（用户批注，随 annotations.pdf 落盘）
        if let pdfView = box.view,
           let selection = pdfView.currentSelection {
            for sub in selection.selectionsByLine() {
                let bounds = sub.bounds(for: page)
                guard bounds.width > 0 else { continue }
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight,
                                         withProperties: nil)
                mark.color = NSColor(red: 1, green: 0.9, blue: 0.35, alpha: 0.45)
                mark.userName = "desire-user-highlight"
                page.addAnnotation(mark)
            }
        }
        annotationsDirty = true
        selectionText = nil
        box.view?.currentSelection = nil
        flashNote = String(localized: "Saved to Excerpts")
    }

    /// 用户批注落盘（annotations.pdf；只写一次，dirty 才写）。
    private func persistAnnotationsIfNeeded() {
        guard annotationsDirty, let document else { return }
        // 剥掉临时标记（译文/搜索），只留用户高亮
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.userName == "desire-translation"
                || annotation.userName == "desire-search-hit" {
                page.removeAnnotation(annotation)
            }
        }
        let url = EbookImporter.pdfFileURL(book)
            .deletingLastPathComponent()
            .appendingPathComponent("annotations.pdf")
        document.write(to: url)
    }

    // MARK: - 阅读统计

    private func startStatsTimer() {
        guard statsSessionStart == nil else { return }
        statsSessionStart = Date()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.flushReadingTime()
            }
        }
    }

    private func flushReadingTime() {
        guard let start = statsSessionStart else { return }
        let seconds = Int(Date().timeIntervalSince(start).rounded())
        statsSessionStart = Date()
        let pages = statsPagesSinceFlush
        statsPagesSinceFlush = 0
        guard seconds > 0 || pages > 0 else { return }
        ReadingStatsStore.shared.add(bookID: book.id, seconds: seconds, pages: pages)
    }
}

/// PDFView 句柄（Representable 创建时注册；SwiftUI 侧跳页/查询用）。
@MainActor
final class PDFViewBox {
    weak var view: PDFView?
}

/// PDFKit 封装（NSViewRepresentable 例外：视图 + Coordinator 同文件）。
private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    let twoUp: Bool
    let box: PDFViewBox
    let onPageChange: (Int) -> Void
    let onSelection: (String?) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if document.pageCount > 0 {
            let index = min(max(initialPage, 0), document.pageCount - 1)
            if let page = document.page(at: index) {
                view.go(to: PDFDestination(page: page, at: .zero))
            }
        }
        box.view = view
        context.coordinator.parent = self
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged,
            object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        // 布局切换只换 displayMode，不动文档；文档变化（换书重载）才重挂。
        let mode: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode {
            view.displayMode = mode
        }
        if view.document !== document {
            view.document = document
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: PDFKitView

        init(parent: PDFKitView) {
            self.parent = parent
        }

        @objc func pageChanged() {
            guard let view = parent.box.view,
                  let document = view.document,
                  let current = view.currentPage else { return }
            let index = document.index(for: current)
            guard index != NSNotFound else { return }
            parent.onPageChange(index)
        }

        @objc func selectionChanged() {
            guard let view = parent.box.view else { return }
            parent.onSelection(view.currentSelection?.string)
        }
    }
}
