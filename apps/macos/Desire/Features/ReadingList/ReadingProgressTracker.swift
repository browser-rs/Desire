import Combine
import Foundation
import WebKit
import os

/// 阅读进度跟踪（v0.7.21）：给「阅读列表里的页面」记滚动位置，重开自动
/// 回到读到的地方。
///
/// 采集策略（不注入页面监听、零常驻开销的取舍）：**每 15 秒对当前标签做
/// 一次纯读**（`WebView.scrollProgressJS`）——只在该标签的 URL 属于阅读
/// 列表时才起表；切标签/离开页面即停。恢复：条目被打开（导航到该 URL）
/// 后由 `WebView.didFinish` 调 `restoreIfNeeded` 回滚到记录位置（一次）。
///
/// 进度写回 `ReadingListStore.setProgress`（盖 LWW 戳随云同步）。
@MainActor
final class ReadingProgressTracker {
    static let shared = ReadingProgressTracker()

    private var timer: Timer?
    private weak var trackedTab: Tab?
    /// 只恢复到"这条"导航一次（didFinish 可能多次触发）。
    private var restoredURLs: Set<String> = []

    private init() {}

    /// 选中标签变更时调用（ContentView.onChange）。
    func track(tab: Tab?) {
        timer?.invalidate()
        timer = nil
        trackedTab = tab
        guard let tab, !tab.isOnNewTabPage,
              let url = tab.browser.webView.url?.absoluteString,
              AppState.live?.readingListStore.items.contains(where: { $0.url == url }) == true else {
            return
        }
        // Timer 跑在主 runloop；assumeIsolated 同步回主 actor（比 Task 少一次
        // 跳帧，也避开"弱 self 进并发闭包"的 Swift 6 警告）。
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.capture()
            }
        }
        timer.tolerance = 5
        self.timer = timer
    }

    /// 立刻采一次（切标签前的机会窗口——track(nil) 前 ContentView 会先调
    /// captureNow，tick 只是兜底）。
    func captureNow() {
        capture()
    }

    private func capture() {
        guard let tab = trackedTab, !tab.isOnNewTabPage,
              let url = tab.browser.webView.url?.absoluteString,
              let store = AppState.live?.readingListStore,
              store.items.contains(where: { $0.url == url }) else { return }
        let webView = tab.browser.webView
        webView.evaluateJavaScript(WebView.scrollProgressJS) { value, _ in
            guard let ratio = value as? Double else { return }
            DispatchQueue.main.async {
                // 未滚动过的打开（scrollY≈0）不许抹掉已存的阅读位置——
                // "打开-没滚-关掉"应该回到上次读到的地方，而不是清零
                // （E2E 实测：桥写 0.5 后关标签被 capture 清零，重开不恢复）。
                // 主动滚回顶部（真实滚动后 capture 到 0）不受影响——本守卫
                // 只拦"一次都没采到过非零值"的覆盖路径。
                if ratio < 0.02, let saved = store.progress(for: url), saved >= 0.02 {
                    return
                }
                store.setProgress(ratio, for: url)
            }
        }
    }

    /// 导航完成后的恢复（WebView.didFinish 调用）。比例过小（<2%，多半是
    /// 刚打开还没滚）不恢复；每条 URL 只恢复一次（同次导航内 didFinish
    /// 可重入——SPA 兜底重载会二次触发）。
    func restoreIfNeeded(webView: WKWebView, url: String?) {
        guard let url, !url.isEmpty,
              let store = AppState.live?.readingListStore,
              let ratio = store.progress(for: url), ratio > 0.02,
              !restoredURLs.contains(url) else { return }
        restoredURLs.insert(url)
        if restoredURLs.count > 64 { restoredURLs.removeAll() }
        webView.evaluateJavaScript(WebView.restoreScrollJS(ratio: ratio), completionHandler: nil)
        Log.app.debug("reading progress: restored \(Int(ratio * 100), privacy: .public)% for \(url, privacy: .public)")
    }
}
