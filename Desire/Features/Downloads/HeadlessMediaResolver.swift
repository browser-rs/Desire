import AppKit
import WebKit

/// 批量下载的"隐藏解析器"：用一个**不进任何窗口**的 WKWebView 逐页加载
/// 详情页，等播放器起流后从嗅探/DOM 扫描里拿到真实媒体地址。
///
/// 与用户标签页的关系（整条设计的地基）：
/// - **共享 `WKWebsiteDataStore.default()`**——用户在正常标签页里过过的
///   Cloudflare，`cf_clearance` Cookie 对这里直接生效；在这里过掉的验证
///   也反哺所有标签页。
/// - **同一套桌面 Safari UA**（`BrowserState.applyDesktopSafariUA`，注释
///   里有它对 Cloudflare 的必要性）——`cf_clearance` 与 UA 绑定，两边必须
///   一致。
///
/// 反爬姿态是"**不绕过，等待**"：
/// - 非交互 JS 挑战（"Just a moment…"）由真 WebKit 自动放行——挑战页会
///   自己 reload 到真页面，这里轮询等待；
/// - 等不动的（交互式 Turnstile）返回 `.needsHuman`，由批量引擎把
///   webview 以小窗展示出来让用户亲手点（`BatchVerifyWindowController`），
///   引擎继续轮询挑战是否解除，再调 `awaitMedia()` 续跑（不重新加载）。
///
/// 解析梯度（预算内逐级升级）：等嗅探 → 周期性 DOM 扫描 → 点播放
/// （静音 + 常见播放按钮选择器）。懒加载播放器（IntersectionObserver 判
/// 不可见不初始化）是已知边界，点播放是主要缓解手段。
@MainActor
final class HeadlessMediaResolver: NSObject {
    enum Outcome {
        case media([MediaResource], pageTitle: String)
        case needsHuman
        case failed(String)
    }

    /// 挑战存活的容忍时长：超过它还没自己过去，才升级为需要人工。
    /// CF 的非交互挑战通常 3-8s 内自动 reload，10s 已很宽裕。
    static let challengeGraceSeconds: TimeInterval = 10
    /// 解析总预算（didFinish 后等待媒体的时间）。
    static let resolveBudgetSeconds: TimeInterval = 25
    /// 人工验证后继续等待媒体的预算。
    static let postVerifyBudgetSeconds: TimeInterval = 30

    let webView: WKWebView
    private var captured: [MediaResource] = []
    /// 最近一次挑战检测结果（轮询时更新）。
    private(set) var challengeActive = false
    /// 主框架加载失败的原因（awaitMedia 循环里即时失败用）。
    private var lastLoadError: String?
    /// `load()` 用导航委托桥接成 async：didFinish 放行 / didFail 抛错。
    private var loadContinuation: CheckedContinuation<Void, Error>?

    private var scanTask: Task<Void, Never>?

    init(dataStore: WKWebsiteDataStore? = nil) {
        let config = WKWebViewConfiguration()
        // 自动播放不要求手势：解析页里视频要"自己开始播"才会起流。
        config.mediaTypesRequiringUserActionForPlayback = []
        // 默认持久 cookie 池 = 与浏览标签页共享（cf_clearance 双向生效）；
        // 默认参数值不能调 MainActor 隔离的 `.default()`，在这里兜底。
        config.websiteDataStore = dataStore ?? .default()
        let controller = config.userContentController
        // 全量复用应用内脚本（嗅探/dom-tools/console…）。dom-tools 不发消息，
        // 嗅探只依赖 mediaFound 一个 handler。
        for script in UserScriptLoader.builtinScripts() {
            controller.addUserScript(script)
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        super.init()
        BrowserState.applyDesktopSafariUA(to: webView)
        webView.navigationDelegate = self
        // handler 注册在 super.init 之后（self 可用）；webview 刚建好，
        // 任何页面消息都晚于这一行。
        controller.add(self, name: "mediaFound")
    }

    // MARK: - 入口

    /// 加载详情页并解析。返回 `.needsHuman` 后由引擎等待人工验证，
    /// 验证解除后调 `awaitMedia()` 在**当前页面**上继续等媒体（不重新加载）。
    ///
    /// `WKWebView.load` 没有异步重载——用导航委托桥接成 async
    /// （didFinish 放行；挑战页 didFinish 在挑战页上，后续轮询处理）。
    func load(_ url: URL) async -> Outcome {
        resetCapture()
        do {
            // **页面加载必须有超时**：服务器黑洞 / 代理失联会让 didFinish 永远
            // 不来，串行解析队列在这里永久卡住——"一个卡住、全批卡住"
            //（2026-09-30 用户实测强退）。60s 与 URLSession 请求超时对齐；
            // 迟到的 didFinish 会 resume 掉挂着的续体（CONC-3 替换语义覆盖，
            // 无重复 resume）。
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.awaitPageLoad(url: url) }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw URLError(.timedOut)
                }
                try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch let error as URLError where error.code == .cancelled {
            return .failed("cancelled")
        } catch let error as URLError where error.code == .timedOut {
            return .failed("page load timed out (60s)")
        } catch {
            return .failed("page failed to load: \(error.localizedDescription)")
        }
        return await awaitMedia(budget: Self.resolveBudgetSeconds, allowNeedsHuman: true)
    }

    private func awaitPageLoad(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 二次 load 时若旧续体还挂着（teardown 摘了 delegate 后 didFinish
            // 永远不来），先以失败解除它——否则旧调用方永久挂起 + 续体泄漏
            //（CONC-3）。
            self.loadContinuation?.resume(throwing: URLError(.cancelled))
            self.loadContinuation = continuation
            self.webView.load(URLRequest(url: url))
        }
    }

    /// 人工验证解除后，在已加载的页面上继续等媒体。
    func awaitMedia() async -> Outcome {
        await awaitMedia(budget: Self.postVerifyBudgetSeconds, allowNeedsHuman: false)
    }

    /// 页面当前是否还卡在挑战（引擎以 2s 轮询驱动此检查）。
    func refreshChallengeState() async -> Bool {
        guard let dict = try? await evaluateChallengeState() else { return challengeActive }
        challengeActive = dict["challenge"] as? Bool ?? false
        return challengeActive
    }

    /// 挑战控件复选框的**窗口坐标**（自主点击用）：Turnstile 复选框在挑战
    /// iframe / `.cf-turnstile` 容器的左缘中点附近。webview 不在可见窗口
    /// （点击落不到真实事件管线）或找不到控件时返回 nil。
    ///
    /// 坐标换算与 `BrowserToolProvider.windowPoint` 同一套（pageZoom 缩放 +
    /// 翻转 + convert），视图翻转语义以 `webView.isFlipped` 为准。
    func challengeCheckboxWindowPoint() async -> CGPoint? {
        guard webView.window != nil, webView.window?.isVisible == true else { return nil }
        let script = """
        (() => {
            const el = document.querySelector('iframe[src*="challenges.cloudflare.com"], .cf-turnstile');
            if (!el) return null;
            const r = el.getBoundingClientRect();
            return {x: r.left, y: r.top, w: r.width, h: r.height};
        })()
        """
        guard let raw = try? await webView.evaluateJavaScript(script),
              let dict = raw as? [String: Any],
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let h = dict["h"] as? Double else { return nil }
        // 复选框：容器左缘往右 30px、垂直居中。
        let pagePoint = CGPoint(x: x + 30, y: y + h / 2)
        let zoom = CGFloat(webView.pageZoom)
        let viewPoint = CGPoint(x: pagePoint.x * zoom, y: pagePoint.y * zoom)
        let cocoaPoint = webView.isFlipped
            ? viewPoint
            : CGPoint(x: viewPoint.x, y: webView.bounds.height - viewPoint.y)
        return webView.convert(cocoaPoint, to: nil)
    }

    func teardown() {
        scanTask?.cancel()
        // 先解除挂起的 load 续体再摘 delegate——摘掉后 didFinish/didFail 不来，
        // 不解除的话调用方（批量引擎的 Task）永久挂起（CONC-3）。
        loadContinuation?.resume(throwing: URLError(.cancelled))
        loadContinuation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mediaFound")
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: - 等待媒体（load 与 awaitMedia 共用）

    private func awaitMedia(budget: TimeInterval, allowNeedsHuman: Bool) async -> Outcome {
        let deadline = Date().addingTimeInterval(budget)
        var challengeTicks = 0
        var lastScanAt = Date.distantPast
        var lastClickAt = Date.distantPast

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return .failed("cancelled") }

            // ① 主框架加载失败即时退出（挑战页自己 reload 也算一次"失败"后
            //    紧跟新导航，所以只在 evaluate 阶段无挑战时才信它）。
            if let failure = lastLoadError {
                return .failed("page failed to load: \(failure)")
            }

            // ② 挑战检查（有挑战就不做媒体判定——挑战页不会有真媒体）。
            challengeActive = await refreshChallengeState()
            if challengeActive {
                challengeTicks += 1
                if Double(challengeTicks) * 0.5 >= Self.challengeGraceSeconds && allowNeedsHuman {
                    return .needsHuman
                }
                continue
            }
            challengeTicks = 0

            // ③ DOM 扫描：每 2s 一次（嗅探是持续推送的，扫描要主动跑）。
            if Date().timeIntervalSince(lastScanAt) >= 2 {
                lastScanAt = Date()
                runScan()
            }

            // ④ 点播放：第 8s 起每 8s 一次（静音播放不影响嗅探）。
            if captured.isEmpty, Date().timeIntervalSince(lastClickAt) >= 8 {
                lastClickAt = Date()
                clickPlayButtons()
            }

            // ⑤ 有可下载媒体即成功。
            if BatchMediaPlan.pickBestResource(captured) != nil {
                return .media(captured, pageTitle: webView.title ?? "")
            }
        }
        if challengeActive { return .needsHuman }
        return .failed("no downloadable media detected within \(Int(budget))s")
    }

    // MARK: - 页面内操作

    /// 跑一次 `__desireScanMedia` 并把结果并进 captured（去重）。
    private func runScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let body = "return await __desireScanMedia()"
            let payload = (try? await self.webView.callAsyncJavaScript(
                body, arguments: [:], in: nil, contentWorld: .page
            ) as? String) ?? ""
            self.absorbScanPayload(payload)
        }
    }

    private func absorbScanPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return }
        for item in items {
            guard let url = item["url"] as? String, !url.isEmpty else { continue }
            let resource = MediaResource(
                url: url,
                kind: MediaResource.Kind(rawValue: item["kind"] as? String ?? "video") ?? .video,
                mime: item["mime"] as? String ?? "",
                sizeBytes: item["size"] as? Int ?? 0,
                source: item["source"] as? String ?? "dom",
                detectedAt: Date()
            )
            if !captured.contains(where: { $0.url == resource.url }) {
                captured.append(resource)
            }
        }
    }

    private func clickPlayButtons() {
        let script = """
        (() => {
            let n = 0;
            document.querySelectorAll('video, audio').forEach(v => {
                try { v.muted = true; const p = v.play(); if (p && p.catch) p.catch(() => {}); n++; } catch (e) {}
            });
            const selectors = ['.vjs-big-play-button', '.ytp-large-play-button', '[class*="play-btn"]',
                               '[class*="playbutton"]', '[class*="play-button"]', 'button[aria-label*="play" i]'];
            for (const s of selectors) {
                const el = document.querySelector(s);
                if (el) { try { el.click(); n++; } catch (e) {} }
            }
            return n;
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func evaluateChallengeState() async throws -> [String: Any] {
        let script = """
        (() => {
            const title = (document.title || '').toLowerCase();
            const cfFrame = !!document.querySelector(
                'iframe[src*="challenges.cloudflare.com"], #challenge-form, .cf-turnstile, #challenge-error-text');
            const markers = ['just a moment', 'attention required', 'checking your browser',
                             'verify you are human', '请稍候', '请完成验证', '确认您是真人'];
            return { title: document.title || '', challenge: cfFrame || markers.some(m => title.includes(m)) };
        })()
        """
        let result = try await webView.evaluateJavaScript(script)
        return (result as? [String: Any]) ?? ["challenge": false]
    }

    private func resetCapture() {
        captured = []
        lastLoadError = nil
        challengeActive = false
        scanTask?.cancel()
        scanTask = nil
    }
}

// MARK: - 嗅探接收（mediaFound）与导航事件

extension HeadlessMediaResolver: WKScriptMessageHandler, WKNavigationDelegate {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "mediaFound", let dict = message.body as? [String: Any],
              let url = dict["url"] as? String, !url.isEmpty else { return }
        let resource = MediaResource(
            url: url,
            kind: MediaResource.Kind(rawValue: dict["kind"] as? String ?? "video") ?? .video,
            mime: dict["mime"] as? String ?? "",
            sizeBytes: dict["size"] as? Int ?? 0,
            source: dict["source"] as? String ?? "network",
            detectedAt: Date()
        )
        if !captured.contains(where: { $0.url == resource.url }) {
            captured.append(resource)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // 允许一切导航（挑战页会自己 reload；站内跳转对解析无害——
        // 最终以"当前页面有没有媒体"说话）。
        .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume(returning: ())
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
        recordLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
        recordLoadFailure(error)
    }

    private func recordLoadFailure(_ error: Error) {
        let code = (error as NSError?).map { $0.code } ?? 0
        // 主框架取消（上一页导航被新导航顶掉）不算失败。
        guard code != NSURLErrorCancelled, code != WKError.Code.webContentProcessTerminated.rawValue else { return }
        lastLoadError = error.localizedDescription
    }
}
