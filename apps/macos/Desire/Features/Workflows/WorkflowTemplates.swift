import Foundation

/// 工作流模板库（v0.8.1）：给任意站点一键生成确定性工作流（不调用模型）。
///
/// 模板只用**通用文本选择器**（`text:` 前缀，回放器按可见文本匹配），
/// 因此不依赖某个站点的类名；匹配不到时回放会在该步报 "not found"，
/// 不会静默点错。所有模板都没有敏感步骤，可以直接定时无人值守运行。
nonisolated enum WorkflowTemplates {
    struct Template: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        /// 点击候选（按顺序尝试；`text:` = 可见文本包含匹配）。
        let clickSelectors: [String]
    }

    static let all: [Template] = [
        Template(
            id: "dismiss-banners",
            name: "Dismiss cookie banner",
            detail: "Clicks the first visible Accept / Allow all / 同意 / 我知道了 button.",
            clickSelectors: [
                "text:Accept all", "text:Accept", "text:Allow all", "text:I agree",
                "text:Got it", "text:同意", "text:全部接受", "text:接受",
                "text:我知道了", "text:知道了",
            ]),
        Template(
            id: "load-more",
            name: "Load more",
            detail: "Clicks Load more / 加载更多 / Show more once, revealing the next page of items.",
            clickSelectors: [
                "text:Load more", "text:Show more", "text:View more", "text:See more",
                "text:加载更多", "text:查看更多", "text:显示更多", "text:更多",
            ]),
        Template(
            id: "expand-read-more",
            name: "Expand “Read more”",
            detail: "Clicks the first Read more / 展开全文 link to unfold the full article.",
            clickSelectors: [
                "text:Read more", "text:Continue reading", "text:Show full article",
                "text:展开全文", "text:阅读全文", "text:查看全文", "text:展开",
            ]),
    ]

    /// 生成只作用于该站点的工作流。host/startURL 来自当前页。
    static func make(_ template: Template, host: String, startURL: String,
                     now: Date = Date()) -> Workflow {
        let step = Workflow.Step(kind: .click,
                                 selectors: template.clickSelectors,
                                 note: template.name)
        return Workflow(name: template.name,
                        host: host.lowercased(),
                        startURL: startURL,
                        createdAt: now,
                        updatedAt: now,
                        steps: [step],
                        offerOnVisit: false)
    }
}
