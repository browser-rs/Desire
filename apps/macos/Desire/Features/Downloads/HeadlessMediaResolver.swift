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
    /// **稳定窗**（v0.8.77 批 1）：首个正片候选出现后，这么久没有新候选就收——
    /// 多视频详情页的其余播放器要点击/滚动才加载，"见到第一个就返回"会把它们漏掉。
    static let settleSeconds: TimeInterval = 6
    /// 页面上只有一个播放器时的稳定窗（单视频页不明显变慢）。
    static let singlePlayerSettleSeconds: TimeInterval = 2

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
        // 只进解析真正需要的两个脚本（2026-11-14 收窄，此前全量复用应用内
        // 脚本）：嗅探 = 页面世界的 media-sniffer（mediaFound 一个 handler，
        // 自带 fetch/XHR 钩子）；DOM 扫描 = 隔离世界的 dom-tools
        // （__desireScanMedia，见 runScan）。其余脚本（network-monitor/
        // network-tools 猴补 fetch/XHR、yt-json-prune 包 fetch、
        // dpp-route-watch 包 history、video-speed 动播放……）都是全局补丁，
        // 会原样打进 CF 挑战页——挑战 JS 的指纹/一致性检查遇到被改过的全局
        // 就可能永远转圈（人工验证窗里"正在验证…"无限循环、无复选框可点、
        // 手动无从下手的形态）。挑战环境要尽量像真 Safari。
        let sniffer = UserScriptLoader.load("media-sniffer")
        if !sniffer.isEmpty {
            controller.addUserScript(WKUserScript(
                source: sniffer,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
        }
        controller.addUserScript(WKUserScript(
            source: UserScriptLoader.load("dom-tools"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: WebView.agentToolWorld))
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

    /// 人工验证阶段的**卡死挑战**（spinner 型 managed challenge，无复选框
    /// 可点）整页重载拿一份新挑战——CF 的 interstitial 常在重载后直接放行。
    /// 桥 didFinish，30s 兜底（挑战页黑洞也不拖死调用方）。
    func reloadForChallenge() async {
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.awaitReload() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw URLError(.timedOut)
            }
            _ = try? await group.next()
            group.cancelAll()
        }
    }

    /// reload 复用 loadContinuation 桥（didFinish 放行 / didFail 抛错）。
    private func awaitReload() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation?.resume(throwing: URLError(.cancelled))
            self.loadContinuation = continuation
            self.webView.reload()
        }
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
        // 稳定窗状态（见 ⑤）。
        var settleStarted = false
        var lastChangeAt = Date.distantPast
        var lastCandidateCount = 0
        var lastNudgeAt = Date.distantPast
        var singlePlayer = false

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

            // ⑤ **收集全部播放器**（v0.8.77 批 1）：首个正片候选出现后不立刻收工——
            //    进入稳定窗，期间分步滚动、逐个起播，等候选数不再变化再返回。
            //    候选里已经归并了分片、剔除了广告/预览，所以"数不变"指的是正片数。
            let count = BatchMediaPlan.contentCandidates(captured).candidates.count
            if count > 0 {
                if !settleStarted {
                    settleStarted = true
                    lastChangeAt = Date()
                    lastCandidateCount = count
                    lastNudgeAt = Date()
                    singlePlayer = await pageHasSingleVideoElement()
                    nudgePlayers()
                } else if count != lastCandidateCount {
                    lastCandidateCount = count
                    lastChangeAt = Date()
                }
                // 窗内每隔几秒再催一次（滚动后新出现的懒加载播放器）。
                if Date().timeIntervalSince(lastChangeAt) >= 2,
                   Date().timeIntervalSince(lastNudgeAt) >= 4 {
                    lastNudgeAt = Date()
                    if singlePlayer { singlePlayer = await pageHasSingleVideoElement() }
                    nudgePlayers()
                }
                let quiet = Date().timeIntervalSince(lastChangeAt)
                if quiet >= (singlePlayer ? Self.singlePlayerSettleSeconds : Self.settleSeconds) {
                    return .media(captured, pageTitle: webView.title ?? "")
                }
                continue
            }
        }
        if challengeActive { return .needsHuman }
        // 预算用尽：手上有正片候选就交出去（慢页面的稳定窗没走完），没有才算失败。
        if BatchMediaPlan.contentCandidates(captured).candidates.isEmpty {
            return .failed("no downloadable media detected within \(Int(budget))s")
        }
        return .media(captured, pageTitle: webView.title ?? "")
    }

    // MARK: - 页面内操作

    /// 跑一次 `__desireScanMedia` 并把结果并进 captured（去重）。
    private func runScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let body = "return await __desireScanMedia()"
            // dom-tools 只在隔离世界（页面世界不再注入）
            let payload = (try? await self.webView.callAsyncJavaScript(
                body, arguments: [:], in: nil, contentWorld: WebView.agentToolWorld
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

    /// 页面上是否只有一个 `<video>` 元素（稳定窗能否缩短）。只在已经有正片
    /// 候选之后调用——那时页面是真页面，不是挑战页。
    private func pageHasSingleVideoElement() async -> Bool {
        let count = (try? await webView.evaluateJavaScript(
            "(() => document.querySelectorAll('video').length)()")) as? Int
        return count == 1
    }

    /// 稳定窗内的"催播"：分步滚动到底再回顶（触发 IntersectionObserver 懒加载的
    /// 播放器），然后让页面上**所有**视频静音起播、点所有常见播放按钮
    /// （`clickPlayButtons` 只点每个选择器的第一个——单播放器时代够用）。
    /// 滚动距离设上限：无限滚动的列表页不能把解析器拖进无底洞。
    private func nudgePlayers() {
        let script = """
        (async () => {
            const step = Math.max(600, Math.floor(window.innerHeight * 0.9));
            const height = Math.max(document.documentElement.scrollHeight,
                                    document.body ? document.body.scrollHeight : 0);
            for (let y = 0; y < height + step && y < 20000; y += step) {
                window.scrollTo(0, y);
                await new Promise(r => setTimeout(r, 250));
            }
            window.scrollTo(0, 0);
            let n = 0;
            document.querySelectorAll('video').forEach(v => {
                try { v.muted = true; const p = v.play(); if (p && p.catch) p.catch(() => {}); n++; } catch (e) {}
            });
            const selectors = ['.vjs-big-play-button', '.ytp-large-play-button', '[class*="play-btn"]',
                               '[class*="playbutton"]', '[class*="play-button"]', 'button[aria-label*="play" i]'];
            for (const s of selectors) {
                document.querySelectorAll(s).forEach(el => { try { el.click(); n++; } catch (e) {} });
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
