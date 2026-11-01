import Combine
import Foundation
import WebKit

/// 翻页请求（v0.8.34 批次二）：由模型发出，WebView 协调器先拍快照再换页并做翻页动画。
struct EbookPageTurnRequest: Equatable, Identifiable {
    let id: UUID
    var target: Int
    var forward: Bool
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
        didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: Self.layoutKey) }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }
    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var showTOC = false

    private static let fontSizeKey = "ebook.fontSize"
    private static let themeKey = "ebook.theme"
    private static let layoutKey = "ebook.layout"
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
        self.layoutMode = LayoutMode(
            rawValue: UserDefaults.standard.string(forKey: Self.layoutKey) ?? "")
            ?? .paged
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
        pageIndex = 0
        pageCount = 1
        pageTurnRequest = nil
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

    /// 分页模式：下一页；章末自动进下一章。
    func nextPage() {
        guard layoutMode == .paged else { nextChapter(); return }
        guard pageIndex + 1 < pageCount else {
            nextChapter()
            return
        }
        let target = pageIndex + 1
        pageIndex = target
        updatePageProgress()
        pageTurnRequest = EbookPageTurnRequest(id: UUID(), target: target, forward: true)
        saveProgress(force: true)
    }

    /// 分页模式：上一页；章首回上一章末页。
    func previousPage() {
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
    }

    private func updatePageProgress() {
        chapterProgress = pageCount > 1
            ? Double(pageIndex) / Double(pageCount - 1)
            : 0
    }

    func jump(toChapter index: Int) {
        guard index != currentChapter else { return }
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
        guard layoutMode == .scroll, let ratio = restoreRatio else { return }
        restoreRatio = nil
        webView.evaluateJavaScript(
            "window.__desireScrollTo && window.__desireScrollTo(\(ratio));",
            completionHandler: nil)
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
          }
          window.__desireGoToPage=function(target, animate){
            var old=index;
            index=Math.max(0,Math.min(target,pages.length-1));
            if(old!==index && animate!==false)flip(old,index>old);
            apply();
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
        });
        </script>
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
        """
    }
}
