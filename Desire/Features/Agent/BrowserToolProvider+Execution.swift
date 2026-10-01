import AppKit
import UniformTypeIdentifiers
import WebKit

/// 页面媒体候选（嗅探 + DOM 扫描合并后的一条）。
/// `fromSniffer` 决定 listPageVideos 的输出形态（嗅探带 mime/size 元信息，
/// 扫描带来源），批量工具只消费 url/kind/isBlob。
struct PageMediaCandidate {
    let url: String
    let kind: String
    let mime: String
    let source: String
    let isBlob: Bool
    let displaySize: String?
    let fromSniffer: Bool
}

/// Tool dispatcher: resolves a single tool call against the `surface`.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + small helpers. The `surface` is guarded at the top of `execute`.
extension BrowserToolProvider {
    /// 把任意 JS 结果**转成可返回给模型的字符串**：DOM 节点给 outerHTML、类数组给
    /// 长度 + 前几项预览、对象走 JSON（失败退 String）。`executeJS` 遇到"返回结果的
    /// 类型不受支持"时用它重跑——那正是把模型逼去 runCommand（再超时 120s）的源头。
    /// - Parameter expressionForm: true = 代码按**表达式**包裹 `(code)`（裸表达式
    ///   如 `document.title` 能直接取值）；false = 按**语句块**包裹 `{ code }`
    ///   （`return x` / `var x=1` 等语句走这里，return 值照常拿到）。
    static func jsStringifyScript(_ code: String, expressionForm: Bool = false) -> String {
        let wrapped = expressionForm ? "( " + code + " )" : "{ " + code + " }"
        return """
        function __desirePreview(value) {
            if (value === undefined) return 'undefined';
            if (value === null) return 'null';
            const type = typeof value;
            if (type === 'string') return value;
            if (type === 'number' || type === 'boolean') return String(value);
            if (value.nodeType === 1) return String(value.outerHTML || value).slice(0, 4000);
            if (value.nodeType === 3) return String(value.nodeValue || '');
            if (typeof value.length === 'number' && typeof value !== 'function') {
                const parts = [];
                for (let i = 0; i < Math.min(value.length, 20); i++) {
                    const item = value[i];
                    if (item && item.nodeType === 1) parts.push('<' + item.tagName.toLowerCase() + '>');
                    else if (typeof item === 'string') parts.push(JSON.stringify(item.slice(0, 40)));
                    else parts.push(String(item).slice(0, 40));
                }
                return '[' + value.length + ' items] ' + parts.join(', ');
            }
            try { const s = JSON.stringify(value); if (s !== undefined && s !== null) return s.slice(0, 4000); } catch (e) {}
            try { return String(value).slice(0, 4000); } catch (e) { return '[unserializable]'; }
        }
        let __desireValue;
        try {
            __desireValue = await (async () => __DESIRE_CODE__)();
        } catch (e) {
            return 'Error: ' + (e && e.message ? e.message : String(e));
        }
        return __desirePreview(__desireValue);
        """
        .replacingOccurrences(of: "__DESIRE_CODE__", with: wrapped)
    }

    /// executeJS 的单次执行结果。parseFailed 只在**表达式形态解析失败**
    /// （整个 body 未执行）时出现——调用方据此回退语句形态。
    enum JSRunOutcome {
        case value(String)
        case parseFailed(String)
    }

    /// `executeJS` 的单次执行：callAsyncJavaScript 跑包装器（预览转换 +
    /// 异常带 message），解析失败区分为 parseFailed，运行时失败按失败约定返回。
    func runJSOnce(_ webView: WKWebView, code: String, expressionForm: Bool) async -> JSRunOutcome {
        do {
            let out = try await webView.callAsyncJavaScript(
                Self.jsStringifyScript(code, expressionForm: expressionForm),
                arguments: [:], in: nil, contentWorld: .page
            ) as? String
            return .value(out?.isEmpty == false ? out! : "Executed (no return value)")
        } catch {
            let ns = error as NSError
            let detail = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String
                ?? error.localizedDescription
            if expressionForm, detail.contains("SyntaxError") {
                return .parseFailed(detail)
            }
            return .value(Self.fail("JS exception — \(detail)"))
        }
    }

    /// 工具失败的**统一约定**：失败一律返回 `Error: ` 前缀的文本。
    ///
    /// 谁在消费它：① `runMechanicalVerification` 的"本轮所有工具都失败"硬判据；
    /// ② 轨迹里每步的 `threwError` 标记；③ 模型自己（`Error:` 是它识别失败、换路
    /// 重试的信号）。**口径**：动作没能执行（参数缺失/非法、目标不存在、前置不满足、
    /// 操作出错）才算失败；**查询成功但结果为空**（"No bookmarks"、"No history
    /// entries"…）不是失败 —— 那是工具给出的正常答案。
    static func fail(_ message: String) -> String { "Error: " + message }

    /// 合并"网络嗅探 + DOM/meta 扫描"的页面媒体候选。listPageVideos 与
    /// downloadAllPageVideos 共用同一份采集（顺序：嗅探在前，扫描去重追加）。
    func pageMediaCandidates(_ webView: WKWebView) async -> [PageMediaCandidate] {
        let sniffed = surface?.tabManager?.tabs
            .first(where: { $0.browser.webView === webView })?
            .browser.detectedMedia ?? []
        let scan = await callAsync(webView, function: "__desireScanMedia", args: [:])
        var scanned: [(url: String, kind: String, mime: String, source: String, isBlob: Bool)] = []
        if let data = scan.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let items = obj["items"] as? [[String: Any]] {
            for item in items {
                guard let url = item["url"] as? String else { continue }
                scanned.append((
                    url,
                    item["kind"] as? String ?? "video",
                    item["mime"] as? String ?? "",
                    item["source"] as? String ?? "dom",
                    item["isBlob"] as? Bool ?? false
                ))
            }
        }

        var candidates: [PageMediaCandidate] = []
        var seen = Set<String>()
        for entry in sniffed where !seen.contains(entry.url) {
            seen.insert(entry.url)
            candidates.append(PageMediaCandidate(
                url: entry.url, kind: entry.kind.rawValue, mime: entry.mime,
                source: entry.source, isBlob: false,
                displaySize: entry.displaySize, fromSniffer: true
            ))
        }
        for entry in scanned where !seen.contains(entry.url) {
            seen.insert(entry.url)
            candidates.append(PageMediaCandidate(
                url: entry.url, kind: entry.kind, mime: entry.mime,
                source: entry.source, isBlob: entry.isBlob,
                displaySize: nil, fromSniffer: false
            ))
        }
        return candidates
    }

    func execute(_ call: AgentToolCall, in webView: WKWebView) async -> String {
        let result = await executeBody(call, in: webView)
        // 页面感知回证（0.3.2）：动作类工具执行后自动截视口快照，
        // 面板工具条目内联展示"点完之后"的画面。
        if AgentEvidenceStore.evidenceTools.contains(call.function.name) {
            AgentEvidenceStore.shared.captureEvidence(for: call.id, in: webView)
        }
        return result
    }

    private func executeBody(_ call: AgentToolCall, in webView: WKWebView) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
        // Tools resolve their store targets through the surface. If it isn't
        // attached yet, only the pure-webview tools (which don't touch a
        // store) would work — fail fast for the rest with a clear message.
        guard let surface else {
            return Self.fail("Tool surface not configured")
        }
        // ARCH-2：按域拆分——先「页面/数据」域，再「DOM/系统」域，最后本文件
        // 的 Utilities 尾段（wait/waitForElement/executeJS/fillLogin 等）。
        // 域返回 nil = 不认识该工具，继续往下问。
        if let handled = await executePageTools(call, args: args, surface: surface, in: webView) { return handled }
        if let handled = await executeDOMAndSystemTools(call, args: args, surface: surface, in: webView) { return handled }
        switch call.function.name {
        // --- Utilities ---
        case "wait":
            // Capped so a misbehaving plan can't stall the loop for minutes.
            let ms = min(args["ms"] as? Int ?? 1000, 60_000)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { return "[Cancelled]" }
            return "Waited \(ms)ms"

        case "waitForElement":
            let sel = args["selector"] as? String ?? ""
            let timeout = min(args["timeout"] as? Int ?? 5000, 60_000)
            return await callAsync(webView, function: "__desireWaitForElement", args: ["selector": sel, "timeout": timeout])

        // 0.3.7 批注：当前页高亮（页面实时收集，含未持久化的）。
        case "getPageHighlights":
            let raw = await callAsync(webView, function: "__desireCollectHighlights", args: [:])
            guard let data = raw.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !list.isEmpty else {
                return "No highlights on this page"
            }
            let colors = ["yellow", "green", "blue", "pink"]
            return list.enumerated().map { i, h -> String in
                let text = h["text"] as? String ?? ""
                let ci = (h["colorIndex"] as? Int ?? 0)
                return "[\(i + 1)] (\(colors[min(ci, colors.count - 1)])) \(text)"
            }.joined(separator: "\n")

        // 0.3.6 智能登录：填存档凭据（dangerous 级——gate 已在上游拦截）。
        case "fillLogin":
            guard let host = webView.url?.host, !host.isEmpty else {
                return "No page loaded"
            }
            let entries = surface.passwordStore.find(domain: host)
            guard let cred = entries.first else {
                return "No stored credential for \(host)"
            }
            let submit = args["submit"] as? Bool ?? false
            let result = await callAsync(webView, function: "__desireFillLogin",
                                         args: ["user": cred.username, "pass": cred.password,
                                                "submit": submit])
            return result + (submit ? " (submitted)" : "")

        // 0.3.2 页面感知：统一等待原语——替代盲 sleep。
        case "waitFor":
            let timeout = min(args["timeout"] as? Int ?? 8000, 60_000)
            if let text = args["text"] as? String, !text.isEmpty {
                return await callAsync(webView, function: "__desireWaitForText",
                                       args: ["text": text, "timeout": timeout])
            }
            if let sel = args["selector"] as? String, !sel.isEmpty {
                return await callAsync(webView, function: "__desireWaitForElement",
                                       args: ["selector": sel, "timeout": timeout])
            }
            let quiet = min(args["quietMs"] as? Int ?? 500, 5000)
            return await callAsync(webView, function: "__desireWaitForNetworkIdle",
                                   args: ["timeout": timeout, "quietMs": quiet])

        case "executeJS":
            // 失败约定：这里曾是裸 "Missing code"，机械核验按 `Error: ` 前缀
            // 统计认不出它（BUG-4）。
            guard let code = args["code"] as? String else { return Self.fail("Missing code") }
            // **单次执行**：工具代码可能带副作用（点击/提交/改 DOM）——旧实现
            // 在失败回退时把同一份代码再跑 1-2 次（包装器重跑拿可序列化值 +
            // 裸跑拿异常信息），副作用翻倍。现在只跑一次：
            //  · 表达式形态优先（裸表达式 `document.title` 直接取值；DOM 节点等
            //    不可序列化结果由包装器转字符串——曾把模型逼去 runCommand 超时）；
            //  · 表达式形态报 **SyntaxError** = 解析期失败、**尚未执行任何代码**，
            //    回退语句形态安全（`return x` 等语句代码走这里）；
            //  · 运行时错误绝不重跑——异常信息经包装器 catch 直接带出
            //    （WKJavaScriptExceptionMessage 的拿法保留在这一条路径里）。
            switch await runJSOnce(webView, code: code, expressionForm: true) {
            case .value(let text):
                return text
            case .parseFailed:
                // 表达式形态解析失败（尚未执行任何代码）→ 语句形态。
                switch await runJSOnce(webView, code: code, expressionForm: false) {
                case .value(let text):
                    return text
                case .parseFailed(let message):
                    return Self.fail("JS exception — \(message)")
                }
            }
        default:
            // MCP-bridged tools ride the same dispatch path with the same
            // approval gating as built-ins.
            if call.function.name.hasPrefix("mcp_") {
                return await MCPStore.shared.callTool(defName: call.function.name,
                                                      argumentsJSON: call.function.arguments)
            }
            return Self.fail("Unknown tool: \(call.function.name)")
        }
    }

    /// Resolves the target (selector / snapshot ref / visible text — the
    /// same resolution the JS fallback uses) to its center point in
    /// window-base coordinates (what `NSEvent.mouseEvent(location:)`
    /// expects) after scrolling the element into view. Returns nil when the
    /// webview has no window, the element is missing, or it has no
    /// on-screen geometry — callers then fall back to the in-page JS path.
    func clickablePoint(selector: String?, ref: String?, text: String?, in webView: WKWebView) async -> CGPoint? {
        guard webView.window != nil else { return nil }
        let raw = await callAsync(webView, function: "__desireElementRect",
                                  args: ["selector": selector ?? "", "ref": ref ?? "", "text": text ?? ""])
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = obj["x"], let y = obj["y"],
              let w = obj["w"], let h = obj["h"], w > 0, h > 0 else { return nil }

        // The JS rect is CSS px, top-left origin; the NSView pipeline wants
        // view/base-window px, bottom-left origin. pageZoom scales CSS px
        // into view px; `isFlipped` covers whichever orientation WKWebView
        // reports.
        return windowPoint(fromViewportX: x + w / 2, y: y + h / 2, in: webView)
    }

    /// Converts a viewport CSS-pixel point (the coordinate space of
    /// `getBoundingClientRect` and screenshots) into window-base coordinates
    /// for synthetic event dispatch. Accounts for page zoom and view flip.
    func windowPoint(fromViewportX x: Double, y: Double, in webView: WKWebView) -> CGPoint {
        let zoom = CGFloat(webView.pageZoom)
        let viewPoint = CGPoint(x: CGFloat(x) * zoom, y: CGFloat(y) * zoom)
        let cocoaPoint = webView.isFlipped
            ? viewPoint
            : CGPoint(x: viewPoint.x, y: webView.bounds.height - viewPoint.y)
        return webView.convert(cocoaPoint, to: nil)
    }
}

// MARK: - 批量任务 id 解析

extension BrowserToolProvider {
// MARK: - 批量任务 id 解析

/// 批次/条目 id 解析：完整 UUID 或大小写不敏感**前缀**。启动摘要与
/// listBatchDownloads 只展示 8 位短 id——模型能拿到的就是它；此前严格
/// UUID 解析让 manageBatchDownloads 永远失败（用户实测"批量任务根本
/// 无法管理，一直报错"）。
static func resolveBatch(
    _ rawID: String, in batches: [BatchMediaBatch]
) -> (batch: BatchMediaBatch?, error: String?) {
    if let uuid = UUID(uuidString: rawID), let b = batches.first(where: { $0.id == uuid }) {
        return (b, nil)
    }
    let lowered = rawID.lowercased()
    guard lowered.count >= 4 else {
        return (nil, "batchId too short — call listBatchDownloads and copy the [#xxxxxxxx] id")
    }
    let hits = batches.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
    switch hits.count {
    case 1: return (hits[0], nil)
    case 0: return (nil, "No batch matches '\(rawID)' — call listBatchDownloads and copy the [#xxxxxxxx] id")
    default: return (nil, "'\(rawID)' matches \(hits.count) batches — use a longer prefix")
    }
}

static func resolveItem(
    _ rawID: String, in batch: BatchMediaBatch
) -> (item: BatchMediaItem?, error: String?) {
    if let uuid = UUID(uuidString: rawID), let it = batch.items.first(where: { $0.id == uuid }) {
        return (it, nil)
    }
    let lowered = rawID.lowercased()
    let hits = batch.items.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
    switch hits.count {
    case 1: return (hits[0], nil)
    case 0: return (nil, "No item matches '\(rawID)' — call listBatchDownloads and copy the item's [#xxxxxxxx] id")
    default: return (nil, "'\(rawID)' matches \(hits.count) items — use a longer prefix")
    }
}
}
