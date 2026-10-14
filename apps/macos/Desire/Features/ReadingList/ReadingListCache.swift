import Foundation
import WebKit

/// 阅读列表离线缓存：把整页抓成 `.webarchive`（DOM + 子资源，可再导入
/// WebKit 系浏览器）落到应用支持目录。
///
/// 拿页面的两条路：条目对应的**页面已打开**就复用其 webview 直接抓
/// （零等待、含登录态）；没打开才离屏加载（轮询 isLoading，镜像
/// PageWatch 的手法）。缓存文件是**机器本地**——同步到别的设备后
/// 文件不存在，按"未缓存"处理。
@MainActor
enum ReadingListCache {

    struct Outcome {
        let fileURL: URL
        let bytes: Int
        /// true = 复用了已打开的标签（含其登录态/滚动态）。
        let fromOpenTab: Bool
    }

    /// 抓取 `url` 的离线副本，文件名 `<itemID>.webarchive`（重缓存即覆盖）。
    static func capture(url: String, itemID: UUID) async -> Outcome? {
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
            return nil
        }

        let webview: WKWebView
        let fromOpenTab: Bool
        if let openTabView = openTabWebview(matching: url) {
            webview = openTabView
            fromOpenTab = true
        } else {
            let offscreen = WKWebView(frame: .zero)
            offscreenCacheWebview = offscreen
            webview = offscreen
            fromOpenTab = false
            webview.load(URLRequest(url: target))
            var finished = false
            for _ in 0..<200 {   // ≤20s
                if !webview.isLoading { finished = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard finished else {
                offscreenCacheWebview = nil
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))   // 让晚到的 JS 渲染
        }

        let data: Data = await withCheckedContinuation { continuation in
            webview.createWebArchiveData { result in
                switch result {
                case .success(let archive): continuation.resume(returning: archive)
                case .failure: continuation.resume(returning: Data())
                }
            }
        }
        offscreenCacheWebview = nil
        guard !data.isEmpty else { return nil }

        let directory = ReadingListStore.cacheDirectory
        let file = directory.appendingPathComponent("\(itemID.uuidString).webarchive")
        do {
            try data.write(to: file)
        } catch {
            return nil
        }
        return Outcome(fileURL: file, bytes: data.count, fromOpenTab: fromOpenTab)
    }

    /// 离屏缓存 webview（一次抓取一个；完成即释放，别常驻）。
    private static var offscreenCacheWebview: WKWebView?

    private static func openTabWebview(matching url: String) -> WKWebView? {
        for manager in TabSessionCoordinator.shared.liveManagers() {
            for tab in manager.tabs {
                let current = tab.browser.webView.url?.absoluteString
                if current == url || tab.urlString == url {
                    return tab.browser.webView
                }
            }
        }
        return nil
    }
}
