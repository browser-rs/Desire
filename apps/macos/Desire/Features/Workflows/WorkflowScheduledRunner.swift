import Foundation
import WebKit

/// 定时工作流执行器（v0.8.1）：在**离屏 webview** 里回放，不占用/切换用户
/// 当前标签页。共享 `WKWebsiteDataStore.default()` 的 Cookie，登录态可复用；
/// 桌面 Safari UA 与浏览器保持一致（避免移动版页面导致选择器不匹配）。
///
/// 敏感步骤不在无人值守路径执行——调用方应在排程时拒绝这类工作流，这里再
/// 兜一层，返回一条明确的失败步骤而不是静默跳过。
@MainActor
enum WorkflowScheduledRunner {
    static func run(_ workflow: Workflow) async -> WorkflowPlayer.RunResult {
        if let sensitive = workflow.steps.first(where: { $0.sensitive }) {
            return WorkflowPlayer.RunResult(
                ok: false,
                results: [WorkflowPlayer.StepResult(
                    index: sensitiveIndex(in: workflow) ?? 0,
                    kind: sensitive.kind, ok: false,
                    message: "scheduled runs cannot fill sensitive steps — run it manually")])
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = BrowserState._desktopSafariUA
        return await WorkflowPlayer.run(workflow, values: [:], in: webView)
    }

    private static func sensitiveIndex(in workflow: Workflow) -> Int? {
        workflow.steps.firstIndex(where: { $0.sensitive })
    }
}
