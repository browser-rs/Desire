import Foundation
import WebKit

/// Vim 模式（v0.8.6）：可选的键盘增强——j/k 滚动、gg/G 顶/底、
/// x 关标签、t 新标签、/ 进入查找。仅当焦点在页面（非输入框）时生效。
///
/// 实现：JS 按键捕获（capture 阶段）+ 原生消息回调；开关存 UserDefaults。
/// 独立于 React/Vue 等页面自身键盘事件——capture 阶段先于页面 handler。
nonisolated enum VimMode {
    static let enabledKey = "browser.vimMode"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// 注入脚本：capture keydown，vim 键 → postMessage 给原生。
    @MainActor static var userScript: WKUserScript? {
        guard let source = try? String(
            contentsOf: Bundle.main.url(forResource: "vim-mode", withExtension: "js") ?? URL(fileURLWithPath: ""),
            encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd,
                            forMainFrameOnly: true)
    }
}
