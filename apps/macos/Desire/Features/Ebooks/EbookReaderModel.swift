import Combine
import Foundation
import WebKit

/// EPUB/TXT 阅读器状态（v0.8.34 批次一）：章节加载、清洗/包装、进度、主题。
@MainActor
final class EbookReaderModel: ObservableObject {

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
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }
    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var showTOC = false

    private static let fontSizeKey = "ebook.fontSize"
    private static let themeKey = "ebook.theme"
    private weak var webView: WKWebView?
    private var restoreRatio: Double?
    private var lastSaved = Date.distantPast

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
            default:
                error = String(localized: "This format is not supported yet.")
            }
        } catch {
            self.error = error.localizedDescription
        }
        if error == nil {
            let start = min(max(book.lastChapterIndex, 0), chapterCount - 1)
            loadChapter(start, restoreRatio: book.chapterProgress)
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

    func loadChapter(_ index: Int, restoreRatio: Double? = nil) {
        let count = chapterCount
        guard count > 0 else { return }
        let target = min(max(index, 0), count - 1)
        currentChapter = target
        self.restoreRatio = restoreRatio
        do {
            let html: String
            if book.format == .epub {
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
                let temp = file.deletingLastPathComponent()
                    .appendingPathComponent(".__desire_reader_\(target).html")
                try Data(html.utf8).write(to: temp, options: .atomic)
                htmlFileURL = temp
            } else {
                guard txtChapters.indices.contains(target) else { return }
                let chapter = txtChapters[target]
                chapterTitle = chapter.title
                let body = "<h1>\(EbookCore.escapeHTML(chapter.title))</h1>"
                    + EbookCore.txtHTML(chapter.text)
                html = wrap(html: body, directory: bookRoot)
                let temp = bookRoot.appendingPathComponent(".__desire_reader_\(target).html")
                try Data(html.utf8).write(to: temp, options: .atomic)
                htmlFileURL = temp
            }
            chapterProgress = min(max(restoreRatio ?? 0, 0), 1)
            saveProgress(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func nextChapter() {
        guard currentChapter + 1 < chapterCount else { return }
        saveProgress(force: true)
        loadChapter(currentChapter + 1, restoreRatio: 0)
    }

    func previousChapter() {
        guard currentChapter > 0 else { return }
        saveProgress(force: true)
        loadChapter(currentChapter - 1, restoreRatio: 0)
    }

    func jump(toChapter index: Int) {
        guard index != currentChapter else { return }
        saveProgress(force: true)
        loadChapter(index, restoreRatio: 0)
    }

    func updateChapterProgress(_ ratio: Double) {
        chapterProgress = min(max(ratio, 0), 1)
        saveProgress()
    }

    func seek(to ratio: Double) {
        chapterProgress = min(max(ratio, 0), 1)
        webView?.evaluateJavaScript(
            "window.__desireScrollTo && window.__desireScrollTo(\(chapterProgress));",
            completionHandler: nil)
        saveProgress(force: true)
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
        if let ratio = restoreRatio {
            restoreRatio = nil
            webView.evaluateJavaScript(
                "window.__desireScrollTo && window.__desireScrollTo(\(ratio));",
                completionHandler: nil)
        }
    }

    func saveProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSaved) > 0.8 else { return }
        lastSaved = now
        EbookLibraryStore.shared.updateProgress(
            book.id, chapterIndex: currentChapter,
            chapterProgress: chapterProgress, overall: overallProgress)
    }

    private func reloadCurrent() {
        let ratio = chapterProgress
        loadChapter(currentChapter, restoreRatio: ratio)
    }

    // MARK: - HTML

    private func wrap(html: String, directory: URL) -> String {
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
        })();
        </script>
        """
        var document = html
        if let headEnd = document.range(of: "</head>", options: .caseInsensitive) {
            document.insert(contentsOf: injection, at: headEnd.lowerBound)
        } else if let bodyStart = document.range(of: "<body", options: .caseInsensitive) {
            document.insert(contentsOf: "<head>\(injection)</head>", at: bodyStart.lowerBound)
        } else {
            document = "<html><head>\(injection)</head><body>\(document)</body></html>"
        }
        _ = directory
        return document
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
        """
    }
}
