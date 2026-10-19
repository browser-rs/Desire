import AppKit
import Foundation
import WebKit

/// 网页分享卡服务（v0.7.24）：活跃标签 → 首屏截图 + 标题/域名 +（可选）旁路
/// 模型摘要 → 组合成卡片 PNG 存到下载目录。
///
/// 摘要是**旁路调用**（bypassPreferences 优先，失败/无 Key 就无摘要——卡片
/// 照出，绝不因为模型挂了挡住导出）；页面正文从 `document.body.innerText`
/// 现取（截 3000 字符），不落盘。
@MainActor
enum PageShareCardService {
    struct Outcome {
        var url: URL
        var title: String
        var domain: String
        var summaryChars: Int
        var width: Int
        var height: Int
    }

    enum ShareCardError: LocalizedError {
        case noTab
        case noWebView
        case snapshotFailed
        case encodeFailed
        var errorDescription: String? {
            switch self {
            case .noTab: String(localized: "No active tab.")
            case .noWebView: String(localized: "The page is not ready yet.")
            case .snapshotFailed: String(localized: "Could not capture the page.")
            case .encodeFailed: String(localized: "Could not encode the card image.")
            }
        }
    }

    static func generate(index: Int? = nil, summarize: Bool = true) async throws -> Outcome {
        let manager = TabSessionCoordinator.shared.activeTabManager
        let tab: Tab? = {
            guard let manager else { return nil }
            if let index { return manager.tabs.indices.contains(index) ? manager.tabs[index] : nil }
            return manager.selectedTab
        }()
        guard let tab else { throw ShareCardError.noTab }
        let webView = tab.browser.webView
        guard webView.url != nil else { throw ShareCardError.noWebView }

        // 标题/域名/正文：一次 JS 往返拿全（innerText 截 3000）。
        let probe = """
        (function() {
          var text = (document.body && document.body.innerText) ? document.body.innerText : "";
          return JSON.stringify({ title: document.title || "", text: text.slice(0, 3000) });
        })()
        """
        var pageTitle = webView.title ?? ""
        var pageText = ""
        if let raw = try? await webView.evaluateJavaScript(probe) as? String,
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["title"] as? String, !t.isEmpty { pageTitle = t }
            pageText = obj["text"] as? String ?? ""
        }
        let domain = webView.url?.host ?? ""

        // 首屏截图（viewport；@2x 由 WebKit 给）。
        let image: NSImage? = await withCheckedContinuation { cont in
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { img, _ in cont.resume(returning: img) }
        }
        guard let image, image.size.width > 10, image.size.height > 10 else {
            throw ShareCardError.snapshotFailed
        }

        // 摘要（旁路模型；失败静默降级）。
        var summaryLines: [String] = []
        if summarize, pageText.count >= 80, let prefs = AppState.live?.aiPreference {
            let sidePrefs = prefs.bypassPreferences() ?? prefs
            let raw = await MemoryExtractor.collectText(
                preference: sidePrefs,
                system: "Summarize this web page in at most 2 sentences in the user's language. Plain text only.",
                user: String(pageText.prefix(3000)))
            if let cleaned = PageShareCardLayout.cleanSummary(raw) {
                summaryLines = PageShareCardLayout.wrap(cleaned)
            }
        }

        let card = PageShareCardRenderer.render(
            title: pageTitle, domain: domain, image: image, summaryLines: summaryLines)
        guard let png = PageShareCardRenderer.pngData(of: card) else {
            throw ShareCardError.encodeFailed
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("网页分享卡-\(stamp).png")
        try png.write(to: url)
        return Outcome(url: url, title: pageTitle, domain: domain,
                       summaryChars: summaryLines.joined().count,
                       width: Int(card.size.width), height: Int(card.size.height))
    }
}
