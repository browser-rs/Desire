import Cocoa
import WebKit

/// Mermaid → SVG 的共享渲染服务：一个隐藏 WKWebView 跑 vendored
/// mermaid，按请求串行渲染，**结果按源码哈希缓存**（气泡与白板共享，
/// 同一段源码跨消息只渲一次）。供气泡内联图与导出使用。
@MainActor
final class MermaidRenderService {
    static let shared = MermaidRenderService()

    private var webview: WKWebView?
    private var cache: [String: String] = [:]      // sha(code) → svg
    private var imageCache: [String: NSImage] = [:]
    private var queue: [(code: String, cont: CheckedContinuation<String, Error>)] = []
    private var drainScheduled = false

    private init() {}

    func cachedSVG(for code: String) -> String? {
        cache[Self.key(code)]
    }

    func cachedImage(for code: String) -> NSImage? {
        imageCache[Self.key(code)]
    }

    func storeImage(_ image: NSImage, for code: String) {
        imageCache[Self.key(code)] = image
    }

    /// 渲染 Mermaid 源码 → SVG 字符串。串行队列保证 webview 单飞。
    func render(_ code: String) async throws -> String {
        let key = Self.key(code)
        if let svg = cache[key] { return svg }
        return try await withCheckedThrowingContinuation { cont in
            queue.append((code, cont))
            scheduleDrain()
        }
    }

    private static func key(_ code: String) -> String {
        String(code.sha256Base36())
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            self.drainScheduled = false
            await self.drain()
        }
    }

    private func drain() async {
        guard !queue.isEmpty else { return }
        let webview = ensureWebView()
        while !queue.isEmpty {
            let item = queue.removeFirst()
            do {
                let svg = try await renderOn(webview, code: item.code)
                cache[Self.key(item.code)] = svg
                item.cont.resume(returning: svg)
            } catch {
                item.cont.resume(throwing: error)
            }
        }
    }

    private func ensureWebView() -> WKWebView {
        if let webview { return webview }
        let webview = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        webview.isHidden = true
        if let app = NSApp.windows.first(where: { $0.isVisible }), let cv = app.contentView {
            // 挂到可见窗口才能保证布局/渲染管线活跃
            cv.addSubview(webview)
            webview.setFrameOrigin(NSPoint(x: -2000, y: 0))
        }
        let html = """
        <!DOCTYPE html><html><head><meta charset="UTF-8"><style>
        body { margin: 0; background: #fffdf7; }
        </style></head><body>
        <div id="out"></div>
        <script src="mermaid.min.js"></script>
        <script>
        mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "loose" });
        window.renderOne = async function (id, code) {
          var out = await mermaid.render(id, code);
          document.getElementById("out").innerHTML = out.svg;
          return out.svg;
        };
        </script></body></html>
        """
        if let base = Bundle.main.resourceURL {
            webview.loadHTMLString(html, baseURL: base)
        } else {
            webview.loadHTMLString(html, baseURL: nil)
        }
        self.webview = webview
        return webview
    }

    private func renderOn(_ webview: WKWebView, code: String) async throws -> String {
        // 等文档/引擎就绪（loadHTMLString 完成前 evaluate 会落在旧文档上）
        for _ in 0..<50 where !webview.isLoading {
            break
        }
        for _ in 0..<50 {
            let ready = (try? await webview.evaluateJavaScript("typeof mermaid !== 'undefined' && typeof renderOne === 'function'")) as? Bool
            if ready == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let id = "srv-" + String(code.sha256Base36().prefix(12))
        let js = "window.renderOne(\(Self.jsString(id)), \(Self.jsString(code)))"
        guard let svg = try await webview.evaluateJavaScript(js) as? String, !svg.isEmpty else {
            throw NSError(domain: "MermaidRender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "mermaid render returned empty"])
        }
        return svg
    }

    private static func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

extension String {
    /// 缓存键：FNV-1a → base36（非安全用途，短且稳定）。
    func sha256Base36() -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        var n = h
        let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        var out = ""
        repeat {
            out = String(digits[digits.index(digits.startIndex, offsetBy: Int(n % 36))]) + out
            n /= 36
        } while n > 0
        return "k" + out
    }
}
