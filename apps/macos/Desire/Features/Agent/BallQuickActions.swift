import Foundation
import WebKit
import os

/// 悬浮球特色快捷动作（v7）：把 agent 的招牌能力（AI 去广告 / 页面视频
/// 下载）做成一键操作。与 agent 工具**同一引擎**：
/// - 去广告 = `AutoAdClean.scanAndClean`（ad-candidates 扫描 + ≥2 理由
///   高置信度拦截，与 didFinish 自动清理和 agent blockElements 同一份规则库）；
/// - 视频下载 = 网络嗅探（`BrowserState.detectedMedia`）+ DOM 扫描
///   （`__desireScanMedia`），批量走 `BatchMediaExportStore.startPageBatch`
///   （与 downloadAllPageVideos 同引擎），单个走 `MediaExportStore.start`。
@MainActor
enum BallQuickActions {

    // MARK: - AI 去广告

    /// 手动触发当前页广告清理。返回拦截数（0 = 没找到高置信度候选；
    /// -1 = 页面不可用）。
    static func cleanAds(on tab: Tab) async -> Int {
        let webView = tab.browser.webView
        guard let host = webView.url?.host, !host.isEmpty else { return -1 }
        return await AutoAdClean.shared.scanAndClean(webView: webView, host: host)
    }

    // MARK: - 页面媒体嗅探

    /// 网络嗅探 + DOM 扫描合并的媒体候选（顺序与 agent 工具层一致：
    /// 嗅探在前，扫描去重追加）。
    static func mediaCandidates(on tab: Tab) async -> [(url: String, kind: String, mime: String, isBlob: Bool)] {
        let webView = tab.browser.webView
        var out: [(url: String, kind: String, mime: String, isBlob: Bool)] = []
        var seen = Set<String>()
        for m in tab.browser.detectedMedia where !seen.contains(m.url) {
            seen.insert(m.url)
            out.append((m.url, m.kind.rawValue, m.mime, false))
        }
        // DOM/meta 扫描（列表页还没播放的卡片视频靠它）。__desireScanMedia
        // 由媒体扫描注入脚本装配，在 agentToolWorld（与 agent 工具层同 world）。
        if let result = try? await webView.callAsyncJavaScript(
            "return await __desireScanMedia({});",
            arguments: [:], in: nil, contentWorld: WebView.agentToolWorld
        ), let data = (result as? String)?.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let items = obj["items"] as? [[String: Any]] {
            for item in items {
                guard let url = item["url"] as? String, !seen.contains(url) else { continue }
                seen.insert(url)
                out.append((url,
                            item["kind"] as? String ?? "video",
                            item["mime"] as? String ?? "",
                            item["isBlob"] as? Bool ?? false))
            }
        }
        return out
    }

    // MARK: - 下载页面视频（单个）

    /// 下载"正在看的那个"视频：嗅探列表里的第一个视频/流（跳过纯音频和
    /// blob 占位）。返回用户可读的结果文本（toast 用）。
    static func downloadPageVideo(on tab: Tab) -> String {
        let candidate = tab.browser.detectedMedia.first {
            $0.kind != .audio && !$0.url.hasPrefix("blob:")
        }
        guard let candidate else {
            return "未检测到视频——先播放一下再试"
        }
        guard let url = URL(string: candidate.url) else {
            return "视频地址无效"
        }
        MediaExportStore.shared.start(
            url: url,
            referer: tab.browser.webView.url,
            userAgent: tab.browser.webView.customUserAgent,
            fileNameHint: nil
        )
        return "已开始下载（后台进行，完成会通知）"
    }

    // MARK: - 下载全部视频（批量）

    /// 页面嗅探到的媒体全部入队（blob/DASH/纯音频的过滤在批量引擎的
    /// 规划层做，与 downloadAllPageVideos 一致）。返回结果文本。
    static func downloadAllVideos(on tab: Tab) async -> String {
        let webView = tab.browser.webView
        let candidates = await mediaCandidates(on: tab)
        guard !candidates.isEmpty else {
            return "未检测到视频——先播放一下再试"
        }
        // 未指定文件夹时垫站点域名子夹（与 agent 工具同规则：换站不混装）。
        let batch = BatchMediaExportStore.shared.startPageBatch(
            candidates: candidates.map { ($0.url, $0.kind, $0.mime, $0.isBlob) },
            referer: webView.url,
            userAgent: webView.customUserAgent,
            folderName: webView.url?.host,
            naming: nil,
            force: false,
            directory: nil,
            splitEvery: nil
        )
        let queued = batch.items.filter { $0.state == .pending }.count
        return queued > 0 ? "已入队 \(queued) 个视频（后台批量下载）" : "这些视频都已在下载索引里"
    }
}
