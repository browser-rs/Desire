import AppKit
import WebKit

/// 白板离屏成图服务：一个隐藏 WKWebView 跑与面板同一份
/// `WhiteboardWebView.pageHTML` 双引擎（Mermaid/ECharts vendored），
/// 串行渲染整板并 takeSnapshot 全内容高 → NSImage。
/// `/panel/snapshot?name=whiteboard` 的成图来源——离屏 NSHostingView
/// 不驱动 webview，此前只能拍"块清单卡"，E2E 拿不到像素级成图证据。
/// 结果按 (spec 内容 + 宽度) 哈希缓存（同板重复拍不重渲）。
@MainActor
final class BoardRenderService {
    static let shared = BoardRenderService()

    struct Result {
        let image: NSImage
        let rendered: Int
        let errors: [String]
    }

    private var webview: WKWebView?
    private var cache: [String: Result] = [:]
    private var queue: [(spec: WhiteboardSpec, width: CGFloat, cont: CheckedContinuation<Result, Error>)] = []
    private var drainScheduled = false

    private init() {}

    func cachedResult(for spec: WhiteboardSpec, width: CGFloat) -> Result? {
        cache[key(spec, width: width)]
    }

    /// 渲染整板 → (成图, rendered, errors)。
    func render(_ spec: WhiteboardSpec, width: CGFloat = 520) async throws -> Result {
        let k = key(spec, width: width)
        if let hit = cache[k] { return hit }
        guard !spec.blocks.isEmpty else {
            throw NSError(domain: "BoardRender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "board is empty"])
        }
        return try await withCheckedThrowingContinuation { cont in
            queue.append((spec, width, cont))
            scheduleDrain()
        }
    }

    private func key(_ spec: WhiteboardSpec, width: CGFloat) -> String {
        let body = spec.title + "\u{1f}" + spec.blocks.map {
            "\($0.type)\u{1f}\($0.title ?? "")\u{1f}\($0.content)"
        }.joined(separator: "\u{1e}")
        return body.sha256Base36() + "@\(Int(width))"
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
        do {
            let webview = try await ensureWebView()
            while !queue.isEmpty {
                let item = queue.removeFirst()
                do {
                    let result = try await renderOn(webview, spec: item.spec, width: item.width)
                    cache[key(item.spec, width: item.width)] = result
                    trimCache()
                    item.cont.resume(returning: result)
                } catch {
                    item.cont.resume(throwing: error)
                }
            }
        } catch {
            // 引擎起不来：整队失败（continuation 必须恰好 resume 一次）
            queue.forEach { $0.cont.resume(throwing: error) }
            queue.removeAll()
        }
    }

    private func trimCache() {
        while cache.count > 8 {
            cache.removeValue(forKey: cache.keys.first!)
        }
    }

    // MARK: - 引擎与单次渲染

    private func ensureWebView() async throws -> WKWebView {
        if let webview { return webview }
        let webview = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 800))
        webview.isHidden = true
        if let app = NSApp.windows.first(where: { $0.isVisible }), let cv = app.contentView {
            // 挂到可见窗口才能保证布局/渲染管线活跃（同 MermaidRenderService）
            cv.addSubview(webview)
            webview.setFrameOrigin(NSPoint(x: -3000, y: 0))
        }
        if let base = Bundle.main.resourceURL {
            webview.loadHTMLString(WhiteboardWebView.pageHTML, baseURL: base)
        } else {
            webview.loadHTMLString(WhiteboardWebView.pageHTML, baseURL: nil)
        }
        self.webview = webview
        return webview
    }

    private func renderOn(_ webview: WKWebView, spec: WhiteboardSpec, width: CGFloat) async throws -> Result {
        // 等双引擎 + renderBoard 就绪（vendored mermaid 2.5MB 解析要一点时间）
        var ready = false
        for _ in 0..<100 {
            ready = (try? await webview.evaluateJavaScript(
                "typeof mermaid !== 'undefined' && typeof echarts !== 'undefined' && typeof renderBoard === 'function'")) as? Bool ?? false
            if ready { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready else {
            throw NSError(domain: "BoardRender", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "board engines failed to boot"])
        }
        // 宽度变化先落 frame（页面 resize 事件驱动 charts.resize 与重排）
        if abs(webview.frame.width - width) > 0.5 {
            webview.frame = NSRect(x: webview.frame.minX, y: webview.frame.minY, width: width, height: 800)
            try? await Task.sleep(for: .milliseconds(120))
        }
        // 渲染完成判据：post() 会写 __lastRenderStats.at（时间戳门控，
        // 只认本次 push 之后的统计）
        let gen = Int(Date().timeIntervalSince1970 * 1000)
        let json = (try? JSONEncoder().encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        _ = try? await webview.evaluateJavaScript(
            "window.__pendingSpec = \(json); (window.renderBoard || function(){})(window.__pendingSpec); 'pushed'")
        var stats: (rendered: Int, errors: [String])?
        for _ in 0..<150 {
            try? await Task.sleep(for: .milliseconds(100))
            if let value = try? await webview.evaluateJavaScript(
                "window.__lastRenderStats && window.__lastRenderStats.at > \(gen) ? JSON.stringify(window.__lastRenderStats) : null") as? String,
               let data = value.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                stats = (obj["rendered"] as? Int ?? 0, obj["errors"] as? [String] ?? [])
                break
            }
        }
        guard let stats else {
            throw NSError(domain: "BoardRender", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "board render timed out"])
        }
        // 全内容高快照（超出视口的部分 WebKit 照常渲染）
        let height = (try? await webview.evaluateJavaScript("document.body.scrollHeight")) as? Double ?? 0
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: min(max(height, 200), 12_000))
        let image: NSImage? = await withCheckedContinuation { cont in
            webview.takeSnapshot(with: config) { img, _ in cont.resume(returning: img) }
        }
        guard let image else {
            throw NSError(domain: "BoardRender", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "snapshot failed"])
        }
        return Result(image: image, rendered: stats.rendered, errors: stats.errors)
    }
}
