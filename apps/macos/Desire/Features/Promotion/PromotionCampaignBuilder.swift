import Foundation

/// 从版本简报生成运营战役与各平台草稿（v0.8.2，纯逻辑，进 harness）。
///
/// **不调用模型**：确定性模板保证"一键从版本生成草稿"离线可跑、可测试；
/// Agent 可在生成后按需润色（润色属于运营 Playbook 的活）。草稿一律以
/// `.draft` 状态入库，绝不自动发布。
nonisolated enum PromotionCampaignBuilder {
    struct Brief {
        var version: String
        var title: String?
        var objective: String = ""
        var productURL: String = "https://desire.mankong.icu/"
        var highlights: [String] = []
        var audience: String = "macOS 用户、开发者、内容创作者"
        var cta: String = "下载体验："
        var startDate: Date = Date()
        var channels: [PromotionChannel] = []
        var goalText: String?
    }

    struct Draft: Equatable {
        let channel: PromotionChannel
        let platform: String
        let title: String
        let body: String
        let trackedURL: String
        let plannedFor: Date
    }

    struct Plan {
        let campaign: PromotionCampaign
        let drafts: [Draft]
    }

    static func makePlan(_ brief: Brief, goalID: UUID? = nil,
                         now: Date = Date()) -> Plan {
        let version = normalizedVersion(brief.version)
        let highlights = normalizedHighlights(brief.highlights)
        let productURL = brief.productURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = productURL.isEmpty ? "https://desire.mankong.icu/" : productURL
        let campaignSlug = slug(version: version, now: brief.startDate)
        let channels = selectedChannels(brief.channels)
        let customTitle = brief.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let campaignTitle = (customTitle?.isEmpty == false ? customTitle : nil)
            ?? "Desire v\(version.isEmpty ? "next" : version) 发布"

        let drafts = channels.enumerated().map { index, channel -> Draft in
            let tracked = trackedURL(baseURL, source: channel.slug,
                                     campaign: campaignSlug)
            let body = body(for: channel, version: version, highlights: highlights,
                            objective: brief.objective, audience: brief.audience,
                            cta: brief.cta, url: tracked)
            return Draft(
                channel: channel,
                platform: channel.platform,
                title: clamp(title(for: channel, version: version, highlights: highlights),
                             max: channel.maxTitleLength),
                body: clampBody(body, max: channel.maxBodyLength, url: tracked),
                trackedURL: tracked,
                plannedFor: plannedDate(brief.startDate, index: index))
        }

        let campaign = PromotionCampaign(
            title: campaignTitle,
            objective: brief.objective.trimmingCharacters(in: .whitespacesAndNewlines),
            goalID: goalID,
            version: version.isEmpty ? nil : version,
            productURL: baseURL,
            platforms: drafts.map(\.platform),
            status: .drafting,
            startsAt: brief.startDate,
            brief: campaignBrief(version: version, highlights: highlights,
                                 objective: brief.objective, audience: brief.audience,
                                 cta: brief.cta),
            createdAt: now,
            updatedAt: now)
        return Plan(campaign: campaign, drafts: drafts)
    }

    // MARK: - 归一化

    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    static func normalizedHighlights(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(String(trimmed.prefix(100)))
            if out.count >= 5 { break }
        }
        return out.isEmpty
            ? ["A macOS browser that can do more of the work."]
            : out
    }

    static func selectedChannels(_ raw: [PromotionChannel]) -> [PromotionChannel] {
        var seen = Set<String>()
        var out: [PromotionChannel] = []
        for channel in raw where channel.isEnabled {
            guard seen.insert(channel.slug).inserted else { continue }
            out.append(channel)
        }
        return out.isEmpty ? PromotionChannel.presets.filter(\.isEnabled) : out
    }

    // MARK: - 链接

    /// 追加 UTM（保留已有 query；URL 非法时原样返回）。
    static func trackedURL(_ base: String, source: String, campaign: String) -> String {
        guard var components = URLComponents(string: base) else { return base }
        var items = components.queryItems ?? []
        items.removeAll { ["utm_source", "utm_medium", "utm_campaign"].contains($0.name) }
        items.append(URLQueryItem(name: "utm_source", value: source))
        items.append(URLQueryItem(name: "utm_medium", value: "social"))
        items.append(URLQueryItem(name: "utm_campaign", value: campaign))
        components.queryItems = items
        return components.url?.absoluteString ?? base
    }

    static func slug(version: String, now: Date) -> String {
        let cleaned = version.lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if !cleaned.isEmpty { return "desire-v" + cleaned }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "desire-campaign-" + f.string(from: now)
    }

    // MARK: - 文案

    static func title(for channel: PromotionChannel, version: String,
                      highlights: [String]) -> String {
        let first = highlights.first ?? "更新"
        switch channel.voice {
        case .xiaohongshu:
            return "Desire v\(version) 值得更新"
        case .hackerNews:
            return "Show HN: Desire – a macOS browser that does the work"
        case .microblog:
            return "Desire v\(version)"
        case .x:
            return "Desire v\(version) is out"
        case .technical, .longform:
            return "Desire v\(version)：\(first)"
        }
    }

    static func body(for channel: PromotionChannel, version: String,
                     highlights: [String], objective: String,
                     audience: String, cta: String, url: String) -> String {
        let bullets = highlights.map { "- \($0)" }.joined(separator: "\n")
        let numbered = highlights.enumerated()
            .map { "\($0.offset + 1)️⃣ \($0.element)" }
            .joined(separator: "\n")
        let objectiveText = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let audienceText = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        let ctaText = cta.trimmingCharacters(in: .whitespacesAndNewlines)

        switch channel.voice {
        case .x:
            return """
            Desire v\(version) is out.

            \(bullets)

            A macOS browser that can run multi-step work in the browser — with approvals, audit and receipts.

            \(ctaText) \(url)
            """
        case .xiaohongshu:
            return """
            最近把主力浏览器换成了 Desire v\(version) 🖥️

            这版最实用的几个更新：
            \(numbered)

            它不是"又一个套壳浏览器"，而是能把浏览、研究、运营这些活接过去，做完了还留回执。

            \(ctaText)
            🔗 \(url)
            \(channel.hashtags)
            """
        case .technical:
            return """
            分享一个 macOS 浏览器：Desire v\(version)

            \(objectiveText.isEmpty ? "这版把 Agent 做进了浏览体验，重点在\"把活干完\"而不是多一个聊天侧栏。" : objectiveText)

            这版主要更新：
            \(bullets)

            研究带引用、文档工作台、定时工作流、副作用动作有审计和撤销/回执。

            \(ctaText)\(url)
            """
        case .longform:
            return """
            Desire v\(version)：把活交给浏览器

            \(objectiveText.isEmpty ? "这次更新围绕一个目标：让浏览器不只是看网页，而是能接住一件完整的工作。" : objectiveText)

            ## 这版做了什么
            \(numbered)

            ## 为什么不是"又一个 AI 浏览器"
            大多数 AI 浏览器把模型塞进侧栏，最后还是用户自己点。Desire 这版把研究、文档、
            定时工作流和运营动作收成可交付的作业：能后台跑、卡住找人、做完给回执。

            ## 适合谁
            \(audienceText.isEmpty ? "macOS 用户、开发者、内容创作者。" : audienceText)

            \(ctaText)\(url)
            """
        case .microblog:
            let first = highlights.first ?? "更新"
            let second = highlights.count > 1 ? "、\(highlights[1])" : ""
            let third = highlights.count > 2 ? "、\(highlights[2])" : ""
            return "Desire v\(version) 发布了：\(first)\(second)\(third)。\(ctaText)\(url)"
        case .hackerNews:
            return """
            Show HN: Desire – a macOS browser that does the work

            Desire is a macOS browser built around an in-browser agent. Instead of another chat sidebar, it can run multi-step work in the browser: research with citations, a document workbench, scheduled workflows, and an approval/audit trail for side effects.

            Highlights in v\(version):
            \(bullets)

            \(objectiveText)

            \(ctaText.isEmpty ? "Download:" : ctaText) \(url)
            """
        }
    }

    static func campaignBrief(version: String, highlights: [String],
                              objective: String, audience: String,
                              cta: String) -> String {
        var lines = ["版本：v\(version)"]
        if !objective.isEmpty { lines.append("目标：\(objective)") }
        if !audience.isEmpty { lines.append("受众：\(audience)") }
        if !cta.isEmpty { lines.append("CTA：\(cta)") }
        lines.append("亮点：")
        lines.append(contentsOf: highlights.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    static func plannedDate(_ start: Date, index: Int,
                            calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: index / 2, to: start) ?? start
        let hours = [10, 15, 20]
        return calendar.date(bySettingHour: hours[index % hours.count],
                             minute: 0, second: 0, of: day) ?? day
    }

    static func clamp(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard max > 0, trimmed.count > max else { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    /// 超长时保留链接（推广帖没有链接等于白写）。
    static func clampBody(_ text: String, max: Int, url: String) -> String {
        guard max > 0, text.count > max else { return text }
        let suffix = "\n…\n" + url
        let room = max - suffix.count
        guard room > 20 else { return String(url.prefix(max)) }
        return String(text.prefix(room)) + suffix
    }
}
