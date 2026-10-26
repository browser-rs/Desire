import SwiftUI
import WebKit

/// 办公文档查看器（v0.8.12 旗舰 B，4+5）：docx/doc/rtf/rtfd/odt →
/// textutil 转 HTML（保结构：标题/列表/粗体）→ WKWebView 渲染。
/// ⌘F 文档内查找（JS 高亮计数）；标题大纲侧栏（h1-h3 解析，点击滚动）。
struct DocumentViewerView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var html: String?
    @State private var loadError: String?
    @State private var showOutline = false
    @State private var headings: [(id: String, level: Int, text: String)] = []
    @State private var findText = ""
    @State private var findCount = 0
    @State private var webViewRef: WKWebView?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if let loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(loadError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html {
                    findBar
                    documentWebView(html)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                statusBar
            }
            if showOutline {
                outlinePanel
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                showOutline.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showOutline ? appAccent : Color.secondary)
            .disabled(headings.isEmpty)
            .help(String(localized: "Outline (headings)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Find in document"), text: $findText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit { runFind() }
                    .onChange(of: findText) { _, _ in runFind() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            Text(findCount == 0 ? "" : "\(findCount)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func documentWebView(_ html: String) -> some View {
        DocumentWebView(html: wrappedHTML(html), onReady: { webView in
            webViewRef = webView
            extractOutline(webView)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outlinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
            Divider()
            if headings.isEmpty {
                Text(String(localized: "No headings found"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            ForEach(headings, id: \.id) { heading in
                Button {
                    jump(to: heading.id)
                } label: {
                    Text(heading.text)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(8 + heading.level * 12))
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(heading.level == 1 ? .primary : .secondary)
                Divider().opacity(0.3)
            }
            Spacer()
        }
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
    }

    private var statusBar: some View {
        HStack {
            Spacer()
            Text("Converted with textutil (structure preserved, layout approximate)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 加载

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            // -convert html 保结构（标题/列表/粗体）——txt 会摊平。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "html", "-stdout", fileURL.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try? process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8), !data.isEmpty else {
                    loadError = String(localized: "Could not convert this document.")
                    return
                }
                html = text
            }
        }
    }

    /// 包一层最小样式（白底黑字、限宽居中、图片自适应）。
    private func wrappedHTML(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; color: #1a1a1a;
               background: #fff; max-width: 720px; margin: 0 auto; padding: 28px 20px;
               font-size: 14px; line-height: 1.65; }
        h1,h2,h3 { line-height: 1.3; }
        img { max-width: 100%; height: auto; }
        table { border-collapse: collapse; } td,th { border: 1px solid #ccc; padding: 4px 8px; }
        mark { background: #ffe27a; }
        </style></head><body>\(body)</body></html>
        """
    }

    // MARK: - 查找 / 大纲

    private func runFind() {
        guard let webView = webViewRef else { return }
        let script = """
        (function(){
          var q = \(JSString.literal(findText.trimmingCharacters(in: .whitespaces)));
          window.__desireDocClear && window.__desireDocClear();
          if (!q) { return 0; }
          var count = 0;
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var idx = node.textContent.toLowerCase().indexOf(q.toLowerCase());
            if (idx < 0) continue;
            var range = document.createRange();
            range.setStart(node, idx);
            range.setEnd(node, idx + q.length);
            var mark = document.createElement('mark');
            mark.setAttribute('data-desire-find', '1');
            try { range.surroundContents(mark); count++; } catch (e) {}
          }
          window.__desireDocClear = function(){
            var marks = document.querySelectorAll('mark[data-desire-find]');
            for (var i = 0; i < marks.length; i++) {
              var parent = marks[i].parentNode;
              while (marks[i].firstChild) parent.insertBefore(marks[i].firstChild, marks[i]);
              parent.removeChild(marks[i]);
              parent.normalize();
            }
          };
          return count;
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            findCount = (result as? Int) ?? 0
        }
    }

    private func extractOutline(_ webView: WKWebView) {
        let script = """
        (function(){
          var out = [];
          var els = document.querySelectorAll('h1,h2,h3');
          for (var i = 0; i < els.length && out.length < 60; i++) {
            var el = els[i];
            el.id = el.id || ('doc-h-' + i);
            out.push({ id: el.id, level: parseInt(el.tagName[1]),
                       text: el.textContent.trim().slice(0, 80) });
          }
          return JSON.stringify(out);
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let list = try? JSONDecoder().decode([Heading].self, from: data) else { return }
            headings = list.map { ($0.id, $0.level, $0.text) }
        }
    }

    private struct Heading: Decodable {
        let id: String
        let level: Int
        let text: String
    }

    private func jump(to id: String) {
        webViewRef?.evaluateJavaScript(
            "document.getElementById(\(JSString.literal(id)))?.scrollIntoView({block:'start'});",
            completionHandler: nil)
    }
}

/// WKWebView 容器（NSViewRepresentable）+ 就绪回调。
private struct DocumentWebView: NSViewRepresentable {
    let html: String
    let onReady: (WKWebView) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: (WKWebView) -> Void
        init(onReady: @escaping (WKWebView) -> Void) { self.onReady = onReady }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onReady(webView)
        }
    }
}
