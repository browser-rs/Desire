import AppKit
import PDFKit
import SwiftUI

/// PDF 阅读器（v0.8.44 批 1）：书架里的 PDF 用 PDFKit 翻页阅读，进度/书签/
/// 目录/统计与 EPUB 同待遇。语义映射：`lastChapterIndex` = 页索引（0 起，
/// 与 CBZ 漫画阅读器同口径），`chapterProgress`/`progress` = 页码比例。
/// 文本层三大件（逐段朗读/翻译对照/搜索）在批 2 接入。
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
    @State private var toc: [TOCEntry] = []
    @State private var bookmarks: [EbookBookmark] = []

    /// PDFView 句柄（NSViewRepresentable 创建时塞进来；跳页/切布局用）。
    @State private var box = PDFViewBox()

    // 阅读统计（口径同 EbookReaderModel：30s 一冲，页数另计）
    @State private var statsSessionStart: Date?
    @State private var statsPagesSinceFlush = 0
    @State private var statsTimer: Timer?

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
        }
        .popover(isPresented: $showTOC) {
            tocPanel
        }
        .popover(isPresented: $showBookmarks) {
            bookmarksPanel
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
            Text(verbatim: "\(pageCount == 0 ? 0 : pageIndex + 1)/\(pageCount)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - 加载

    private func load() {
        loading = true
        bookmarks = EbookBookmarkStore.load(book.id)
        let url = EbookImporter.pdfFileURL(book)
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
    }
}
