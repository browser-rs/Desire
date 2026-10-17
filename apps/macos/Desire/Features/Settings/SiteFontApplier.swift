import Foundation
import WebKit

/// 站点字体注入的**单点收口**：把生效配置拼进页面脚本一次求值。
/// 页面侧（site-font-inject）幂等——重复调用按新配置重设，所以"关闭"
/// 也走同一条路（清掉此前的字号覆盖与字体样式）。
///
/// 三个调用点：导航完成（didFinish，仅 isActive 时）、站点弹层改值、
/// 桥/工具改值（都是"改完立即重注入"，用户不用刷新）。
@MainActor
enum SiteFontApplier {
    static func apply(to webView: WKWebView, host: String, store: SiteSettingsStore) {
        let font = store.effectiveFont(for: host)
        let script = "window.__desireSiteFontCfg = {min: \(font.minFontSize), family: \(JSString.literal(font.fontFamily))};\n"
            + UserScriptLoader.load("site-font-inject")
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
