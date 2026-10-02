import AppKit
import SwiftUI
import WebKit

/// ARCH-2 拆分：executeBody 的「DOM 交互/录制/系统命令与技能」域。
/// 纯搬运（case 体零改动）；返回 nil = 本域不认识该工具。
extension BrowserToolProvider {

    func executeDOMAndSystemTools(_ call: AgentToolCall, args: [String: Any], surface: any BrowserToolSurface, in webView: WKWebView) async -> String? {
        switch call.function.name {
        // --- DOM interaction ---
        // These tools invoke page-world functions (UserScripts/dom-tools.js)
        // via callAsyncJavaScript, passing parameters as native values.
        // NO string interpolation: model-controlled selectors/values cannot
        // break out into code. See docs/ARCHITECTURE.md (L2 JS Bridge).
        //
        // Targeting modes, resolved in-page in this order: ref (snapshot
        // id) > text (visible label) > CSS selector.
        case "click":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return Self.fail("Provide one of: ref (from getPageSnapshot), text (visible label), or selector")
            }
            // Prefer a real (isTrusted=true) mouse click through the AppKit
            // event pipeline — untrusted `element.click()` is a bot signal
            // for anti-automation systems (Turnstile) and can get the user's
            // session challenged. The JS fallback keeps the tool working
            // when the webview has no window (suspended/background tab) or
            // the element resolves to no on-screen geometry.
            if let point = await clickablePoint(selector: sel, ref: ref, text: text, in: webView) {
                await SyntheticInput.click(at: point, in: webView)
                return "Clicked (trusted mouse event)"
            }
            return await callAsync(webView, function: "__desireClick",
                                   args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])

        case "clickAt":
            // Vision-loop primitive: pairs with the screenshot tool. x/y are
            // CSS pixels of the viewport (the coordinate space getPageSnapshot
            // reports), dispatched as a REAL mouse event.
            guard let x = args["x"] as? Double, let y = args["y"] as? Double else {
                return Self.fail("Missing x or y (viewport CSS pixels)")
            }
            guard webView.window != nil else {
                return Self.fail("No window attached — coordinate clicks need a visible webview")
            }
            let point = windowPoint(fromViewportX: x, y: y, in: webView)
            await SyntheticInput.click(at: point, in: webView)
            return "Clicked at (\(Int(x)), \(Int(y)))"

        case "highlight":
            // Agent visibility: scroll to the element and flash an orange
            // outline so the user can SEE what is about to be acted on.
            // Pairs naturally before click/fill in narrated tasks.
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return Self.fail("Provide one of: ref, text, or selector")
            }
            let result = await callAsync(webView, function: "__desireHighlight",
                                         args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])
            return result.isEmpty ? "Element not found" : result

        case "getPageLinks":
            // Navigation planning: the page's visible links as {text, href}.
            let maxItems = args["maxItems"] as? Int ?? 50
            return await callAsync(webView, function: "__desireGetLinks",
                                   args: ["maxItems": maxItems])

        case "listPageVideos":
            // Merge two detection paths: the network sniffer (real CDN URLs
            // behind blob: players, accumulated in the owning tab's
            // BrowserState) and the on-demand DOM/meta scan.
            let candidates = await pageMediaCandidates(webView)
            var lines: [String] = []
            for entry in candidates {
                var line = "[\(entry.kind)] \(entry.url)"
                if entry.fromSniffer {
                    var meta: [String] = []
                    if !entry.mime.isEmpty { meta.append("type: \(entry.mime)") }
                    if let size = entry.displaySize { meta.append(size) }
                    if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                } else if entry.isBlob {
                    line += " (blob: only usable inside the page — look for the stream/mp4 entries instead)"
                } else {
                    line += " (via \(entry.source))"
                }
                lines.append(line)
            }

            if lines.isEmpty {
                return "No video/audio resources detected on this page. Try playing the video first — the network sniffer records the stream as it loads."
            }
            return "\(lines.count) media resource(s):\n" + lines.joined(separator: "\n")

        case "downloadAllPageVideos":
            // 喂食流批量（模式 A）：当前页嗅探到的媒体全部入队——去重/过滤
            // （blob/DASH/纯音频）在规划层（BatchMediaPlan）做。逐页解析的
            // 列表用 downloadVideoList。
            let candidates = await pageMediaCandidates(webView)
            guard !candidates.isEmpty else {
                return "No video/stream resources detected on this page. If each list item links to a separate detail page, collect those URLs and use downloadVideoList instead."
            }
            let requestedFolder = (args["folderName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitDirectory = (args["directory"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 未指定文件夹时**自动垫站点域名子夹**：换站不混装（2026-09-30
            // 用户定案恢复——曾误删，"下载换个网站就错乱了"）。**但只垫给
            // 默认流**——用户指定了 directory 时该路径就是根目录，绝不再垫
            // host 垫层无视已指定的 directory（用户实测：指定目录下
            // 又被垫出一层同名子夹，"位置搞错了"）。
            let folderName: String?
            if requestedFolder?.isEmpty == false {
                folderName = requestedFolder
            } else if explicitDirectory == nil || explicitDirectory!.isEmpty || explicitDirectory! == "/" {
                folderName = webView.url?.host
            } else {
                folderName = nil
            }
            let batch = BatchMediaExportStore.shared.startPageBatch(
                candidates: candidates.map { ($0.url, $0.kind, $0.mime, $0.isBlob) },
                referer: webView.url,
                userAgent: webView.customUserAgent,
                folderName: folderName,
                naming: args["naming"] as? String,
                force: (args["force"] as? Bool) ?? false,
                directory: args["directory"] as? String,
                splitEvery: args["splitEvery"] as? Int
            )
            let downloading = batch.items.filter { $0.state == .pending }.count
            let skipped = batch.items.filter { $0.state == .skipped }
            let dest = batch.saveRoot ?? (BatchMediaPreferences.baseDirectory ?? NSHomeDirectory() + "/Downloads")
            let leaf = batch.folderName.isEmpty ? "" : "/" + batch.folderName
            var reply = """
            Batch \(batch.id.uuidString.prefix(8)) started: \(downloading) video(s) into \(dest)\(leaf) (≤2 concurrent). \
            Failed items are retried automatically in the same batch/folder — do NOT fall back to downloadMedia for them. \
            Do NOT wait or poll in a loop — listBatchDownloads reports progress, and the user is notified when the batch finishes.
            """
            if !skipped.isEmpty {
                let names = skipped.prefix(8).map { "\($0.title) (\($0.summary ?? ""))" }.joined(separator: "; ")
                reply += "\nSkipped \(skipped.count): \(names)"
            }
            return reply

        case "downloadVideoList":
            // 列表批量（模式 B）：详情页地址逐个交给隐藏解析器。长任务立刻
            // 返回批次 id——回合不能阻塞在几十页的解析上。
            guard let urls = args["urls"] as? [String], !urls.isEmpty else {
                return Self.fail("Missing urls (array of detail-page URLs)")
            }
            guard urls.count <= BatchMediaExportStore.maxItemsPerBatch else {
                return Self.fail("Too many urls (\(urls.count)); cap is \(BatchMediaExportStore.maxItemsPerBatch) per batch")
            }
            let requestedFolder = (args["folderName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitDirectory = (args["directory"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // host 垫层只给默认流（同 downloadAllPageVideos）；指定 directory
            // = 根目录直落，绝不嵌套（同名子夹嵌套事故）。
            let folderName: String?
            if requestedFolder?.isEmpty == false {
                folderName = requestedFolder
            } else if explicitDirectory == nil || explicitDirectory!.isEmpty || explicitDirectory! == "/" {
                folderName = URL(string: urls[0])?.host
            } else {
                folderName = nil
            }
            if let mc = args["maxConcurrent"] as? Int, (1...4).contains(mc) {
                BatchMediaPreferences.maxConcurrent = mc
            }
            let batch = BatchMediaExportStore.shared.startListBatch(
                pageURLs: urls,
                userAgent: webView.customUserAgent,
                folderName: folderName,
                naming: args["naming"] as? String,
                force: (args["force"] as? Bool) ?? false,
                directory: args["directory"] as? String,
                splitEvery: args["splitEvery"] as? Int
            )
            let queued = batch.items.filter { $0.state == .pending }.count
            let skipped = batch.items.filter { $0.state == .skipped }
            let dest = batch.saveRoot ?? (BatchMediaPreferences.baseDirectory ?? NSHomeDirectory() + "/Downloads")
            let leaf = batch.folderName.isEmpty ? "" : "/" + batch.folderName
            var reply = """
            Batch \(batch.id.uuidString.prefix(8)) started: \(queued) page(s) queued → \(dest)\(leaf). Each page is loaded in a hidden browser \
            (serialized, paced with the download slots so signed URLs never expire), the stream is captured and downloaded (≤2 concurrent). \
            Cloudflare checks pass automatically; an interactive one is clicked with real mouse events, and only falls back to waiting for the \
            user in a popup window if that fails. Failed items are retried automatically in the SAME batch/folder — do NOT fall back to \
            downloadMedia for them. Do NOT wait or poll in a loop — listBatchDownloads reports progress, and the user is notified when the batch finishes.
            """
            if !skipped.isEmpty {
                let names = skipped.prefix(8).map { "\($0.title) (\($0.summary ?? ""))" }.joined(separator: "; ")
                reply += "\nSkipped \(skipped.count): \(names)"
            }
            return reply

        case "retryBatchDownloads":
            // 失败项重试：复用原批次与原文件夹（模型此前手动开新批次，文件
            // 散落三个目录——工具描述已禁止，这里给出规范入口）。
            let batches = BatchMediaExportStore.shared.batches
            let target: BatchMediaBatch?
            if let rawID = args["batchId"] as? String, !rawID.isEmpty {
                let (resolved, error) = Self.resolveBatch(rawID, in: batches)
                if let error { return Self.fail(error) }
                target = resolved
            } else {
                target = batches.first(where: { $0.state == .finished })
            }
            guard let batch = target else {
                return Self.fail("No matching finished batch (pass the [#xxxxxxxx] batchId from listBatchDownloads)")
            }
            let failedCount = batch.items.filter { $0.state == .failed }.count
            guard failedCount > 0 else {
                return "Batch \(batch.folderName) has no failed items to retry."
            }
            BatchMediaExportStore.shared.retryFailed(batch.id)
            return "Retrying \(failedCount) failed item(s) in batch \(batch.folderName) (same folder as before). listBatchDownloads reports progress."

        case "listBatchDownloads":
            let store = BatchMediaExportStore.shared
            let batches = store.batches
            guard !batches.isEmpty else { return "No batch downloads." }
            var lines: [String] = []
            for batch in batches.prefix(10) {
                // 落点按批次**实际**的 saveRoot/folder 拼接（此前写死默认目录，
                // 用户指定 directory 时列表显示的是错误位置）。
                let dest = batch.saveRoot ?? (BatchMediaPreferences.baseDirectory ?? NSHomeDirectory() + "/Downloads")
                let leaf = batch.folderName.isEmpty ? "" : "/" + batch.folderName
                var line = "[#\(batch.id.uuidString.prefix(8).lowercased())] [\(batch.state.rawValue)] \(batch.folderName.isEmpty ? "(directory itself)" : batch.folderName) (\(batch.mode.rawValue)) — \(batch.finishedCount)/\(batch.items.count) done → \(dest)\(leaf)"
                if let split = batch.splitEvery, split > 0 { line += " — rolling archive: every \(split) files → archivedNNN subfolder" }
                if store.isPaused(batch.id) { line += " — PAUSED (resume with manageBatchDownloads)" }
                if let reason = store.suspensionReason(batch.id) {
                    line += " — SUSPENDED: \(reason) (auto-resumes when space recovers)"
                }
                let needsHuman = batch.items.filter { $0.state == .needsHuman }
                if !needsHuman.isEmpty {
                    line += " — WAITING FOR HUMAN VERIFICATION (\(needsHuman.count)) — automatic clicking already failed; tell the user to finish the check in the popup window"
                }
                lines.append(line)
                for item in batch.items.prefix(30) {
                    var itemLine = "  · [#\(item.id.uuidString.prefix(8).lowercased())] [\(item.state.rawValue)] \(item.title.isEmpty ? item.sourceURL.absoluteString : item.title)"
                    if let progress = store.progress(for: item.id) {
                        itemLine += " (\(progress.done)/\(progress.total) \(progress.unit.rawValue))"
                    }
                    if item.attempts > 1 { itemLine += " (attempt \(item.attempts))" }
                    if let summary = item.summary, [.failed, .skipped].contains(item.state) {
                        itemLine += " — \(summary)"
                    }
                    lines.append(itemLine)
                }
                if batch.items.count > 30 {
                    lines.append("  … \(batch.items.count - 30) more items")
                }
            }
            return lines.joined(separator: "\n")

        case "manageBatchDownloads":
            guard let rawID = args["batchId"] as? String, !rawID.isEmpty else {
                return Self.fail("Missing batchId — call listBatchDownloads and copy the [#xxxxxxxx] id")
            }
            let store = BatchMediaExportStore.shared
            let (resolvedBatch, batchError) = Self.resolveBatch(rawID, in: store.batches)
            guard let batch = resolvedBatch else {
                return Self.fail(batchError ?? "invalid batchId")
            }
            let batchID = batch.id
            guard let action = (args["action"] as? String)?.lowercased() else {
                return Self.fail("Missing action (pause/resume/skip/add/remove)")
            }
            switch action {
            case "pause":
                store.pause(batchID: batchID)
                return "Batch paused. Resume with manageBatchDownloads action=resume."
            case "resume":
                store.resume(batchID: batchID)
                return "Batch resumed."
            case "skip":
                guard let rawItem = args["itemId"] as? String, !rawItem.isEmpty else {
                    return Self.fail("skip needs itemId — the [#xxxxxxxx] id of an item in listBatchDownloads")
                }
                let (resolvedItem, itemError) = Self.resolveItem(rawItem, in: batch)
                guard let item = resolvedItem else {
                    return Self.fail(itemError ?? "invalid itemId")
                }
                store.skip(batchID: batchID, itemID: item.id)
                return "Item skipped (removed from the queue)."
            case "add":
                guard let urls = args["urls"] as? [String], !urls.isEmpty else {
                    return Self.fail("add needs urls (array)")
                }
                guard urls.count <= BatchMediaExportStore.maxItemsPerBatch else {
                    return Self.fail("Too many urls; cap is \(BatchMediaExportStore.maxItemsPerBatch)")
                }
                let mode = store.batches.first(where: { $0.id == batchID })?.mode ?? .list
                let result = store.addItems(
                    batchID: batchID,
                    pageURLs: mode == .list ? urls : [],
                    mediaURLs: mode == .page ? urls : [],
                    referer: webView.url
                )
                return result.added == 0
                    ? "Nothing added (\(result.duplicates) duplicate/invalid URL(s) — they may already be in this batch)."
                    : "Added \(result.added) task(s) to the batch (\(result.duplicates) duplicates ignored). Numbering continues from the existing items."
            case "remove":
                store.removeSettled(batchID: batchID)
                return store.batches.contains(where: { $0.id == batchID })
                    ? Self.fail("Batch is still running — cancel it first (no remove action for running batches; pause then remove works)")
                    : "Batch removed from the panel."
            default:
                return Self.fail("Unknown action '\(action)' (pause/resume/skip/add/remove)")
            }

        case "downloadMedia":
            // 后台导出：直接文件流式落盘；HLS（m3u8）解析分片、按 Referer +
            // Safari UA 抓取（对付防盗链）、AES-128 解密后拼成可播放文件。
            // **不再阻塞这一轮**：HLS 导出动辄几分钟，等它结束会让整轮对话卡住
            // （用户实测"一直在等待"）。现在立刻返回任务 id，完成后写会话备注 +
            // 发系统通知，进度用 listMediaExports 查。
            guard let urlString = args["url"] as? String, let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else {
                return Self.fail("Invalid url (http/https only)")
            }
            let jobID = MediaExportStore.shared.start(
                url: url,
                referer: webView.url,
                userAgent: webView.customUserAgent,
                fileNameHint: args["fileName"] as? String
            )
            return """
            Export started in the background (job \(jobID.uuidString.prefix(8))). It keeps running while \
            you continue working — do NOT wait for it and do not retry it. The file lands in \
            ~/Downloads; the user is notified when it finishes, and listMediaExports reports progress.
            """

        case "findAdCandidates":
            // 广告候选：返回带理由的候选清单（**不删任何东西**），由模型挑。
            let script = UserScriptLoader.load("ad-candidates")
            guard !script.isEmpty else { return Self.fail("ad-candidates script missing") }
            do {
                let raw = try await webView.callAsyncJavaScript(
                    script,
                    arguments: ["maxItems": 25],
                    in: nil,
                    contentWorld: .page
                ) as? String
                guard let raw, let data = raw.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = payload["candidates"] as? [[String: Any]] else {
                    return "No candidates could be read from this page."
                }
                if candidates.isEmpty {
                    return "No ad-like elements found on this page (scanned \(payload["scanned"] ?? 0) elements)."
                }
                var lines: [String] = ["\(candidates.count) ad candidate(s) — pick the ones to block, then call blockElements with their selectors:"]
                for (index, item) in candidates.enumerated() {
                    let reasons = (item["reasons"] as? [String] ?? []).joined(separator: ",")
                    let text = (item["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    let src = item["src"] as? String ?? ""
                    lines.append("[\(index + 1)] \(item["tag"] ?? "?") \(item["width"] ?? 0)x\(item["height"] ?? 0) — \(reasons)"
                                 + "\n    selector: \(item["selector"] ?? "")"
                                 + (text.isEmpty ? "" : "\n    text: \(text.prefix(60))")
                                 + (src.isEmpty ? "" : "\n    src: \(src)"))
                }
                return lines.joined(separator: "\n")
            } catch {
                return Self.fail("Failed to scan for ads: \(error.localizedDescription)")
            }

        case "blockElements":
            // 批量屏蔽：写进 ElementBlockStore（按 host 生效、下次导航自动注入），
            // 同时立刻把隐藏 CSS 注进当前页面（用户当场就能看到效果）。
            guard let selectors = args["selectors"] as? [String], !selectors.isEmpty else {
                return Self.fail("Missing selectors array (use findAdCandidates first, then pass the selectors you want to hide)")
            }
            let host = webView.url?.host ?? ""
            let pattern = (args["urlPattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlPattern = (pattern?.isEmpty == false ? pattern! : (host.isEmpty ? "*" : host))
            var applied: [String] = []
            var skipped: [String] = []
            for selector in selectors.prefix(40) {
                let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if surface.elementBlockStore.rules.contains(where: { $0.cssSelector == trimmed && $0.urlPattern == urlPattern }) {
                    skipped.append(trimmed)
                    continue
                }
                surface.elementBlockStore.add(cssSelector: trimmed, urlPattern: urlPattern)
                applied.append(trimmed)
            }
            if !applied.isEmpty {
                let css = applied.map { "\($0) { display: none !important; }" }.joined()
                let escaped = css
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: " ")
                _ = try? await webView.callAsyncJavaScript("""
                (function() {
                    var style = document.getElementById('desire-blocked-selectors') || document.createElement('style');
                    style.id = 'desire-blocked-selectors';
                    style.textContent = (style.textContent || '') + '\(escaped)';
                    if (!style.parentNode) document.head.appendChild(style);
                    return 'ok';
                })();
                """, arguments: [:], in: nil, contentWorld: .page)
            }
            // 可选的网络层拦截（广告域名/路径）。
            var blockedRequests: [String] = []
            if let requests = args["blockRequests"] as? [String] {
                for filter in requests.prefix(20) where !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                    InterceptStore.shared.add(urlFilter: filter, kind: .block, payload: nil)
                    blockedRequests.append(filter)
                }
            }
            var report = applied.isEmpty
                ? "Nothing new to block"
                : "Blocked \(applied.count) element(s) on \(urlPattern) (hidden now and on every future load of this host)"
            if !skipped.isEmpty { report += "; \(skipped.count) already blocked" }
            if !blockedRequests.isEmpty { report += "; \(blockedRequests.count) request filter(s) added" }

            // **学习闭环**：站点广告画像沉淀进长期记忆（同一 host 旧画像被
            // 替换，不堆积）。AI 下次在该站工作时会从记忆里"想起"这个站的
            // 广告结构；记忆随云同步 → 跨设备共享学到的经验。host 为通配符
            // "*" 时不沉淀（无站点语义）。
            if urlPattern != "*", !applied.isEmpty {
                let profile = "Site ads profile: \(urlPattern) — blocked selectors: "
                    + applied.prefix(6).joined(separator: " ; ")
                AgentMemoryStore.shared.removeFacts(containing: "Site ads profile: \(urlPattern)")
                // scope=站点 host：promptBlock 只在该站点命中时注入——
                // 此前存 global 导致广告结构经验全站注入（占上下文且易误用）。
                AgentMemoryStore.shared.addFact(
                    content: profile, category: "fact", scope: urlPattern)
            }
            return report

        case "listMediaExports":
            let jobs = MediaExportStore.shared.jobs
            guard !jobs.isEmpty else { return "No media exports have been started." }
            return jobs.suffix(10).map { job -> String in
                var line = "\(job.state.rawValue) \(job.title)"
                if let summary = job.summary { line += " — \(summary)" }
                return line
            }.joined(separator: "\n")

        case "updatePlan":
            // Visible task checklist: the model maintains the step list and
            // the panel renders it live (Claude-TodoWrite style).
            guard let items = args["steps"] as? [[String: Any]] else {
                return Self.fail("Missing steps array")
            }
            var steps: [AgentPlanStep] = []
            for item in items.prefix(12) {
                guard let content = item["content"] as? String, !content.isEmpty else { continue }
                var status = item["status"] as? String ?? "pending"
                if !["pending", "in_progress", "done"].contains(status) { status = "pending" }
                steps.append(AgentPlanStep(content: String(content.prefix(120)), status: status))
            }
            guard !steps.isEmpty else { return Self.fail("No valid steps") }
            // 计划归属发起回合的会话（面板按各自会话读取，不互相污染）。
            AgentPlanStore.shared.set(
                steps,
                conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
            let done = steps.filter { $0.status == "done" }.count
            return "Plan updated: \(done)/\(steps.count) done"

        case "setUploadFile":
            // Arms a local file so the NEXT page file-picker auto-submits
            // it (the open panel is intercepted in the UI delegate). This
            // is the upload primitive behind platform publishing skills.
            if args["clear"] as? Bool == true {
                UploadIntent.shared.arm([])
                return "Upload intent cleared"
            }
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
                return Self.fail("Missing path (or clear=true to disarm)")
            }
            let expanded = (rawPath as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return Self.fail("File not found: \(fileURL.path)")
            }
            UploadIntent.shared.arm([fileURL])
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
            let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return "Armed '\(fileURL.lastPathComponent)'\(sizeText.isEmpty ? "" : " (\(sizeText))"). Clicking the page's upload button now auto-submits it (consumed once)."

        case "renderDiagram":
            // Built-in canvas: render Mermaid (mindmap/flowchart/sequence/…)
            // on a canvas page served by the preview server.
            guard let source = args["source"] as? String, !source.isEmpty else { return Self.fail("Missing source (Mermaid syntax)") }
            let title = args["title"] as? String ?? "Diagram"
            let safeSource = source.replacingOccurrences(of: "</script>", with: "<\\/script>")
            let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;")
            let safeFile = title.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "/", with: "-")
            let page = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(safeTitle)</title>
            <style>
              body{font-family:-apple-system,sans-serif;margin:20px}
              #bar{display:flex;gap:6px;margin-bottom:12px}
              #bar button{font:12px -apple-system;padding:4px 10px;border-radius:6px;
                border:1px solid #ccc;background:#fff;cursor:pointer}
              .mermaid{transform-origin:top left;display:inline-block;min-width:100%}
              .error{color:#c00;font-family:monospace;white-space:pre-wrap}
            </style></head>
            <body>
            <div id="bar">
              <button onclick="zoom(-0.1)">−</button>
              <button onclick="zoom(0.1)">＋</button>
              <button onclick="resetZoom()">1:1</button>
              <button onclick="exportSVG()">导出 SVG</button>
              <button onclick="exportPNG()">导出 PNG</button>
            </div>
            <h1>\(safeTitle)</h1>
            <pre class="mermaid">\(safeSource)</pre>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <script>
            const dark = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches;
            if (dark) document.body.style.background = '#1e1e1e';
            let scale = 1;
            function applyScale(){ const el = document.querySelector('.mermaid');
              el.style.transform = 'scale(' + scale + ')'; el.style.transformOrigin = 'top left'; }
            function zoom(d){ scale = Math.min(4, Math.max(0.2, scale + d)); applyScale(); }
            function resetZoom(){ scale = 1; applyScale(); }
            function svgNode(){ return document.querySelector('.mermaid svg'); }
            function exportSVG(){ const svg = svgNode(); if (!svg) return alert('尚未渲染完成');
              const blob = new Blob([svg.outerHTML], {type:'image/svg+xml'});
              const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
              a.download = '\(safeFile).svg'; a.click(); }
            function exportPNG(){ const svg = svgNode(); if (!svg) return alert('尚未渲染完成');
              const xml = new XMLSerializer().serializeToString(svg);
              const img = new Image();
              img.onload = function(){ const w = svg.viewBox.baseVal.width || 1000;
                const h = svg.viewBox.baseVal.height || 600;
                const c = document.createElement('canvas'); c.width = w; c.height = h;
                const ctx = c.getContext('2d'); ctx.fillStyle = '#fff';
                ctx.fillRect(0,0,w,h); ctx.drawImage(img,0,0,w,h);
                const a = document.createElement('a'); a.href = c.toDataURL('image/png');
                a.download = '\(safeFile).png'; a.click(); };
              img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml); }
            mermaid.initialize({ startOnLoad:true, theme: dark ? 'dark' : 'default' });
            mermaid.run({ querySelector:'.mermaid' }).then(applyScale).catch(function(e){
              document.body.insertAdjacentHTML('beforeend',
                '<p class="error">渲染失败：'+e.message+'</p><pre class="error">'+
                document.querySelector('.mermaid').textContent+'</pre>'); });
            </script></body></html>
            """
            let dir = AgentWorkspace.shared.directory.appendingPathComponent("canvas", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileName = "canvas/diagram-\(Int(Date().timeIntervalSince1970)).html"
            let fileURL = AgentWorkspace.shared.directory.appendingPathComponent(fileName)
            try? page.write(to: fileURL, atomically: true, encoding: .utf8)
            let base = PreviewServer.ensureRunning()
            let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            let url = base.appendingPathComponent(encoded)
            webView.load(URLRequest(url: url))
            return "Diagram rendered at \(url.absoluteString) (Mermaid syntax — edit the file at \(fileURL.path) to iterate)"

        case "askUser":
            // Mid-task clarification: pauses the loop until the user answers
            // in the panel. The question card IS the interaction (readonly).
            guard let question = args["question"] as? String, !question.isEmpty else {
                return Self.fail("Missing question")
            }
            let answer = await UserPromptCenter.shared.ask(question)
            return answer

        case "writeFile":
            // Save agent-produced content to a local file. Restricted to the
            // user's folders (Downloads/Documents/Desktop) + app support.
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else { return Self.fail("Missing path") }
            let content = args["content"] as? String ?? ""
            switch AgentWorkspace.shared.resolve(rawPath, write: true) {
            case .denied(let reason):
                return reason
            case .granted(let fileURL):
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                    return "Wrote \(content.count) chars → \(fileURL.path)"
                } catch {
                    return Self.fail("Write failed: \(error.localizedDescription)")
                }
            }

        case "readFile":
            // Text file read from the workspace / user folders. Binary
            // files are reported instead of dumped.
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else { return Self.fail("Missing path") }
            switch AgentWorkspace.shared.resolve(rawPath, write: false) {
            case .denied(let reason):
                return reason
            case .granted(let fileURL):
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return Self.fail("File not found: \(fileURL.path)")
                }
                guard let data = FileManager.default.contents(atPath: fileURL.path) else {
                    return Self.fail("Could not read \(fileURL.path)")
                }
                if data.contains(0) {
                    return "Binary file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))) — not shown as text"
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                return text.count > 60_000 ? String(text.prefix(60_000)) + "…[truncated]" : text
            }

        case "listDirectory":
            let raw = args["path"] as? String ?? ""
            let target: URL
            switch AgentWorkspace.shared.resolve(raw, write: false) {
            case .denied(let reason):
                return reason
            case .granted(let url):
                target = raw.isEmpty ? AgentWorkspace.shared.directory : url
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
                return Self.fail("Could not list \(target.path)")
            }
            var lines: [String] = ["\(target.path)"]
            for entry in entries.prefix(200) {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let kind = isDir ? "dir " : "file"
                let sizeText = isDir ? "" : "  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
                lines.append("- [\(kind)] \(entry.lastPathComponent)\(sizeText)")
            }
            return lines.joined(separator: "\n")

        // --- Recording ---
        case "startRecording":
            // Records THIS window (the whole browser window, chat included —
            // perfect for "watch me work" demos). First call triggers the
            // macOS Screen Recording permission dialog.
            guard let window = webView.window else { return Self.fail("No window attached") }
            do {
                let url = try await WindowRecorder.shared.start(window: window)
                return "Recording started → \(url.lastPathComponent). Perform the steps now; call stopRecording when finished."
            } catch {
                return Self.fail("Could not start recording: \(error.localizedDescription)")
            }

        case "stopRecording":
            guard WindowRecorder.shared.isRecording else { return Self.fail("Not recording") }
            guard let url = await WindowRecorder.shared.stop() else {
                return Self.fail("Recording stopped but the file could not be finalized")
            }
            let duration: String
            if let started = WindowRecorder.shared.startedAt {
                duration = String(format: "%.0f", Date().timeIntervalSince(started)) + "s"
            } else {
                duration = "?"
            }
            return "Recording saved: \(url.path) (\(duration))"

        // --- Agent host: system CLI + skills ---
        case "runCommand":
            // Allowlisted binary, argv-only (no shell). ToolRisk marks this
            // DANGEROUS: every call prompts with the exact command line
            // unless the user enabled FULL ACCESS.
            guard let tool = args["tool"] as? String, !tool.isEmpty else {
                return Self.fail("Missing tool (allowlisted: \(SystemCommandStore.shared.allowedBinaries.sorted().joined(separator: ", ")))")
            }
            let commandArgs = args["args"] as? [String] ?? []
            let timeout = args["timeoutSec"] as? Double ?? 120
            let result = await SystemCommandStore.shared.run(
                tool: tool, args: commandArgs, timeout: timeout,
                workDirectory: AgentWorkspace.shared.directory
            )
            // 非零退出 / 超时是最常见的一类工具失败，必须进统一约定：
            // 否则机械核验与模型都看不出这条命令没成功（grep 无匹配的 exit 1 也算）。
            let output = "runCommand \(result.summary)\n\(result.stdout)\(result.stderr == "" ? "" : "\n\(result.stderr)")"
            return (result.exitCode == 0 && !result.timedOut) ? output : Self.fail(output)

        case "useSkill":
            // Progressive disclosure: the name+description list rides in the
            // prompt; this loads the FULL instructions into the conversation.
            guard let name = args["name"] as? String, !name.isEmpty else {
                return Self.fail("Missing skill name. Available: \(SkillStore.shared.skills.map(\.name).joined(separator: ", "))")
            }
            guard let skill = SkillStore.shared.skills.first(where: { $0.name == name }),
                  let body = SkillStore.shared.body(for: name) else {
                return Self.fail("Skill not found: \(name). Available: \(SkillStore.shared.skills.map(\.name).joined(separator: ", "))")
            }
            var output = "Skill '\(name)' loaded. Follow these instructions:\n\(body)"
            // 多文件 skill：附属文件清单（readFile 按需读取）。
            if let directory = skill.directory {
                let companions = SkillStore.companionFiles(in: directory)
                if !companions.isEmpty {
                    output += "\n\nCompanion files (read with readFile when needed):\n"
                    output += companions.map { "- \($0.absolute) (\($0.relative))" }.joined(separator: "\n")
                }
            }
            return output

        case "listSkills":
            let skills = SkillStore.shared.skills
            if skills.isEmpty { return "No skills installed (drop .md files into Application Support/Desire/skills)" }
            return "Installed skills:\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        case "downloadFile":
            // Store-owned download: lands in the downloads panel with
            // pause/resume; fires downloadStarted/Completed bridge events.
            guard let urlText = args["url"] as? String, !urlText.isEmpty,
                  let url = URL(string: urlText), url.scheme != nil else {
                return Self.fail("Missing or invalid url")
            }
            let filename = (args["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? url.lastPathComponent
            guard let store = DownloadStore.live else { return Self.fail("Downloads store unavailable") }
            store.startURLSessionDownload(sourceURL: url, filename: filename)
            return "Download started: \(filename) — tracked in the downloads panel."

        case "scheduleTask":
            // 定时任务: persist a recurring prompt. Runs fire only while
            // the app is open; overdue tasks catch up once on launch.
            guard let name = args["name"] as? String, !name.isEmpty,
                  let prompt = args["prompt"] as? String, !prompt.isEmpty else {
                return Self.fail("Missing name or prompt")
            }
            let recurrence: AgentScheduler.ScheduledTask.Recurrence
            if let dailyAt = args["dailyAt"] as? String {
                let parts = dailyAt.split(separator: ":")
                guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                      (0...23).contains(hour), (0...59).contains(minute) else {
                    return Self.fail("Invalid dailyAt — expected \"HH:MM\" (24h), got: \(dailyAt)")
                }
                recurrence = .daily(hour: hour, minute: minute)
            } else if let rawMinutes = args["everyMinutes"] as? String, let minutes = Int(rawMinutes) {
                recurrence = .everyMinutes(max(5, minutes))
            } else if let minutes = args["everyMinutes"] as? Int {
                recurrence = .everyMinutes(max(5, minutes))
            } else {
                return Self.fail("Provide everyMinutes (>= 5) or dailyAt (\"HH:MM\")")
            }
            if let task = AgentScheduler.shared.add(name: name, prompt: prompt, recurrence: recurrence) {
                return "Scheduled '\(task.name)' (\(task.recurrenceText)). It runs while the app is open; manage tasks in Settings → Agent → Scheduled Tasks."
            }
            return Self.fail("Failed to schedule '\(name)' (empty fields?)")

        case "listScheduledTasks":
            let tasks = AgentScheduler.shared.tasks
            if tasks.isEmpty { return "No scheduled tasks." }
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return tasks.map { task -> String in
                var line = "- \(task.name) [\(task.isEnabled ? "on" : "off")] (\(task.recurrenceText))"
                if let last = task.lastFiredAt, task.lastFiredAt != task.createdAt {
                    line += " last: \(formatter.string(from: last))"
                }
                if let result = task.lastResult {
                    line += " — \(result)"
                }
                return line
            }.joined(separator: "\n")

        case "cancelScheduledTask":
            guard let name = args["name"] as? String else { return Self.fail("Missing name") }
            return AgentScheduler.shared.remove(named: name)
                ? "Cancelled '\(name)'"
                : "No scheduled task named '\(name)'. Use listScheduledTasks."

        case "copyToClipboard":
            guard let text = args["text"] as? String else { return Self.fail("Missing text") }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "Copied to clipboard: \(preview)"

        case "readClipboard":
            // Side-effect tier on purpose: the clipboard may hold sensitive
            // content, so ToolRisk.classify leaves this at .sideEffect and
            // the user is asked (with an Always-Allow option) first.
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if text.isEmpty { return "Clipboard is empty (or holds non-text content)" }
            return text.count > 2000
                ? String(text.prefix(2000)) + "…[truncated]"
                : text

        case "fill":
            guard let val = args["value"] as? String else { return Self.fail("Missing value") }
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return Self.fail("Provide selector or ref") }
            return await callAsync(webView, function: "__desireFill",
                                   args: ["selector": sel ?? "", "value": val, "ref": ref ?? ""])

        case "select":
            guard let val = args["value"] as? String else { return Self.fail("Missing value") }
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return Self.fail("Provide selector or ref") }
            return await callAsync(webView, function: "__desireSelect",
                                   args: ["selector": sel ?? "", "value": val, "ref": ref ?? ""])

        case "scroll":
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            return await callAsync(webView, function: "__desireScroll", args: ["x": x, "y": y])

        case "hover":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            let text = args["text"] as? String
            guard sel != nil || ref != nil || text != nil else {
                return Self.fail("Provide one of: ref, text, or selector")
            }
            // Trusted mouse-moved stream, same rationale as `click`.
            if let point = await clickablePoint(selector: sel, ref: ref, text: text, in: webView) {
                await SyntheticInput.hover(at: point, in: webView)
                return "Hovered (trusted mouse events)"
            }
            return await callAsync(webView, function: "__desireHover",
                                   args: ["selector": sel ?? "", "ref": ref ?? "", "text": text ?? ""])

        case "focus":
            let sel = args["selector"] as? String
            let ref = args["ref"] as? String
            guard sel != nil || ref != nil else { return Self.fail("Provide selector or ref") }
            return await callAsync(webView, function: "__desireFocus",
                                   args: ["selector": sel ?? "", "ref": ref ?? ""])

        case "pressKey":
            // Trusted keyboard event through the AppKit pipeline (the page
            // becomes first responder for the duration). Covers Enter-on-
            // search, Escape-on-modal, arrow/tab navigation, ⌘A-style combos.
            guard let key = args["key"] as? String, !key.isEmpty else {
                return Self.fail("Missing key. Supported: \(SyntheticInput.supportedKeys)")
            }
            var flags: NSEvent.ModifierFlags = []
            if let mods = args["modifiers"] as? [String] {
                for m in mods {
                    switch m.lowercased() {
                    case "cmd", "command", "⌘": flags.insert(.command)
                    case "shift", "⇧": flags.insert(.shift)
                    case "ctrl", "control", "⌃": flags.insert(.control)
                    case "alt", "option", "opt", "⌥": flags.insert(.option)
                    default: break
                    }
                }
            }
            return await SyntheticInput.key(key, modifiers: flags, in: webView)

        case "type":
            // Trusted per-character typing into the FOCUSED element. Unlike
            // fill (prototype setter), real key events fire — autocomplete,
            // search-as-you-type, and keydown-driven widgets respond.
            guard let text = args["text"] as? String, !text.isEmpty else { return Self.fail("Missing text") }
            // Optional focus target first; typing lands in the page either way.
            if let sel = args["selector"] as? String, !sel.isEmpty {
                _ = await callAsync(webView, function: "__desireFocus",
                                    args: ["selector": sel, "ref": args["ref"] as? String ?? ""])
            } else if let ref = args["ref"] as? String, !ref.isEmpty {
                _ = await callAsync(webView, function: "__desireFocus",
                                    args: ["selector": "", "ref": ref])
            }
            return await SyntheticInput.type(text, in: webView)

        case "waitForText":
            // Wait until visible text appears (e.g. search results render).
            guard let text = args["text"] as? String, !text.isEmpty else { return Self.fail("Missing text") }
            let timeout = args["timeout"] as? Int ?? 8000
            return await callAsync(webView, function: "__desireWaitForText",
                                   args: ["text": text, "timeout": timeout])

        case "getFormFields":
            // Structured form inventory (ref/type/name/label/value/options)
            // with data-desire-ref ids assigned — fill {ref} targets them.
            return await callAsync(webView, function: "__desireGetFormFields", args: [:])

        case "postComment":
            // One-shot "评论/回复/回消息": locates the page's comment or
            // chat input automatically (textarea or contenteditable editor),
            // types through the framework-compatible editing path, then
            // submits — trusted click on the 发送/发表/Send button when one
            // exists (rect comes back from the page), otherwise Enter.
            guard let text = args["text"] as? String, !text.isEmpty else { return Self.fail("Missing text") }
            let submit = args["submit"] as? Bool ?? true
            let raw = await callAsync(webView, function: "__desirePostComment",
                                      args: ["text": text, "submit": submit])
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return raw.isEmpty ? "No comment or chat input found on this page" : raw
            }
            let status = obj["status"] as? String ?? "Typed"
            guard submit,
                  let rect = obj["submitRect"] as? [String: Double],
                  let x = rect["x"], let y = rect["y"],
                  let w = rect["w"], let h = rect["h"], w > 0, h > 0 else {
                return status
            }
            let point = windowPoint(fromViewportX: x + w / 2, y: y + h / 2, in: webView)
            await SyntheticInput.click(at: point, in: webView)
            return status + " — submitted"

        case "extract":
            guard let sel = args["selector"] as? String else { return Self.fail("Missing selector") }
            return await callAsync(webView, function: "__desireExtract", args: ["selector": sel])

        case "findElements":
            guard let sel = args["selector"] as? String else { return Self.fail("Missing selector") }
            return await callAsync(webView, function: "__desireFindElements", args: ["selector": sel])

        default:
            return nil
        }
    }
}
