import Foundation

/// 产品内“分享 Desire”文案（v0.8.2，纯逻辑，进 harness）。
///
/// 不调用模型：给用户一个可直接发出去的短文案 + 带 UTM 的产品链接。
/// 语气按渠道适配；不做“最强/第一”这类过度承诺（发布前预检也会拦）。
nonisolated enum PromotionShare {
    static let defaultProductURL = "https://desire.mankong.icu/"

    static func trackedURL(version: String, channel: String) -> String {
        let campaign = "desire-share-v" + normalizedVersion(version)
            .replacingOccurrences(of: ".", with: "-")
        return PromotionCampaignBuilder.trackedURL(
            defaultProductURL, source: channel.lowercased(), campaign: campaign)
    }

    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value.isEmpty ? "next" : value
    }

    /// 默认选中的渠道（分享面板第一项）。
    static var defaultChannel: PromotionChannel {
        PromotionChannel.preset(slug: "x") ?? PromotionChannel.presets[0]
    }

    static func caption(platform: String, version: String) -> String {
        let channel = PromotionChannel.preset(platform: platform) ?? defaultChannel
        let url = trackedURL(version: version, channel: channel.slug)
        let v = normalizedVersion(version)
        switch channel.voice {
        case .x:
            return """
            Desire is a macOS browser that can actually do the work: research with citations, document workbenches, scheduled workflows, and an approval/audit trail for side effects.

            I've been using v\(v) as my daily browser. Worth a look:
            \(url)
            """
        case .xiaohongshu:
            return """
            最近把主力浏览器换成了 Desire v\(v) 🖥️

            它不是“又一个套壳浏览器”，而是能把浏览、研究、文档、定时工作流这些活接过去：
            ✅ 研究带引用
            ✅ 文档工作台
            ✅ 后台任务有审批、审计和回执

            想找一个能真正帮你干活的 macOS 浏览器可以试试：
            \(url)

            \(channel.hashtags)
            """
        case .microblog:
            return "Desire v\(v)：一个会把活干完的 macOS 浏览器——研究带引用、文档工作台、定时工作流、副作用有审计和回执。\(url)"
        case .technical:
            return """
            分享一个 macOS 浏览器：Desire v\(v)

            它不是把 AI 塞进侧栏，而是把研究、文档、定时工作流和运营动作收成可交付的作业：
            - 研究/文档回答带引用
            - 后台任务可审批、可审计
            - 做完给回执，失败说原因

            \(url)
            """
        case .longform:
            return """
            Desire v\(v)：把活交给浏览器

            大多数 AI 浏览器把模型放进侧栏，最后还是用户自己点。Desire 这版把研究、文档、
            定时工作流和运营动作收成可交付的作业：能后台跑、卡住找人、做完给回执。

            如果你每天大部分工作都在浏览器里，可以试试：
            \(url)
            """
        case .hackerNews:
            return """
            Show HN: Desire – a macOS browser that does the work

            Desire is a macOS browser built around an in-browser agent: research with citations, a document workbench, scheduled workflows, and an approval/audit trail for side effects.

            \(url)
            """
        }
    }
}
