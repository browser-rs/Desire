import AppKit
import WebKit
import os

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
                // **先落 frame 再渲染**（v8）：ReactFlow/markmap 在初始化时
                // 测量容器尺寸，加载后才改宽会让它们按 0 宽初始化（节点/导图
                // 全部不可见——实测）。帧尺寸必须在引擎 boot 前就位。
                if abs(webview.frame.width - item.width) > 0.5 {
                    webview.frame = NSRect(x: 0, y: 0, width: item.width, height: 800)
                }
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
        // **不能 isHidden / 屏幕外偏移**：ReactFlow 的 viewport 是 3D transform
        // 合成层——隐藏或窗口外的视图，合成层 takeSnapshot 不渲染（实测节点
        // DOM 在、截图全空；markmap 无 3D 层所以能出图，差异即铁证）。
        // 正解：挂到可见窗口**最底层**（被页面内容盖住，用户看不见），
        // 合成管线完整活跃。
        webview.isHidden = false
        if let app = NSApp.windows.first(where: { $0.isVisible }), let cv = app.contentView {
            cv.addSubview(webview, positioned: .below, relativeTo: nil)
        }
        if let base = Bundle.main.resourceURL {
            // v8：与 WhiteboardWebView 同源——React 前端产物优先，缺失回退兜底页。
            let indexHTML = base.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexHTML.path) {
                webview.loadFileURL(indexHTML, allowingReadAccessTo: base)
            } else {
                webview.loadHTMLString(WhiteboardWebView.legacyFallbackHTML, baseURL: base)
            }
        } else {
            webview.loadHTMLString(WhiteboardWebView.legacyFallbackHTML, baseURL: nil)
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
            // 失败时细分哪个环节没就绪（React bundle 加载失败 / vendored 脚本缺失）。
            let detail = (try? await webview.evaluateJavaScript(
                "JSON.stringify({mermaid: typeof mermaid, echarts: typeof echarts, renderBoard: typeof renderBoard, href: location.href})"
            )) as? String ?? "?"
            Log.agent.error("board engines boot detail: \(detail, privacy: .public)")
            throw NSError(domain: "BoardRender", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "board engines failed to boot: \(detail)"])
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
        // v8 调试探针：ReactFlow/markmap 的 DOM 状态（节点数/容器尺寸）
        if let probe = try? await webview.evaluateJavaScript(
            "JSON.stringify({rfNodes: document.querySelectorAll('.react-flow__node').length, n1: (function(){var n=document.querySelector('.react-flow__node'); if(!n) return null; var r=n.getBoundingClientRect(); var cs=getComputedStyle(n); return [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height), cs.display, cs.visibility, cs.opacity, n.style.transform];})(), vp: (function(){var v=document.querySelector('.react-flow__viewport'); return v ? v.style.transform : null})()})"
        ) as? String {
            Log.agent.info("board DOM probe: \(probe, privacy: .public)")
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
