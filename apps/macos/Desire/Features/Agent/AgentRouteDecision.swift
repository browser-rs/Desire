import Foundation

/// 成本感知路由的**决策纯逻辑**（v0.7.26 旗舰；Foundation-only，进 harness）。
/// 保守原则：**任何不确定都走主模型**——省钱是优化项，不是正确性前提。
///
/// 仅当以下全部成立才路由到廉价档案：
/// ① 开关打开（默认关）；② 有可用的廉价档案；③ 无进行中的计划（多步任务）；
/// ④ 最近用户输入 ≤ 80 字符；⑤ 不含动作类关键词（打开/下载/点击/运行…）；
/// ⑥ 会话消息数 ≤ 6（新会话的短问句；长对话上下文复杂，别为省钱降质）。
nonisolated enum AgentRouteDecision {
    enum Route: String, Equatable {
        case main
        case cheap
    }

    struct Decision: Equatable {
        var route: Route
        /// 审计用的一句话原因（进轨迹；不是给用户看的文案）。
        var reason: String
    }

    /// 动作/工具类关键词（小写匹配）：命中即走主模型。
    static let actionKeywords: [String] = [
        "打开", "下载", "搜索", "点击", "登录", "提交", "运行", "执行", "安装",
        "删除", "重命名", "保存", "导出", "导入", "截图", "录屏", "定时", "监视",
        "open", "download", "click", "search", "run ", "install", "delete",
        "submit", "login", "save", "export", "import", "screenshot", "schedule",
        "watch", "navigate", "goto", "fetch", "scrape",
    ]

    static let maxInputChars = 80
    static let maxMessageCount = 6

    static func decide(routingEnabled: Bool,
                       hasCheapProfile: Bool,
                       userText: String,
                       hasActivePlan: Bool,
                       messageCount: Int) -> Decision {
        guard routingEnabled else { return Decision(route: .main, reason: "routing disabled") }
        guard hasCheapProfile else { return Decision(route: .main, reason: "no cheap profile") }
        guard !hasActivePlan else { return Decision(route: .main, reason: "plan active") }
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Decision(route: .main, reason: "empty input") }
        guard trimmed.count <= maxInputChars else {
            return Decision(route: .main, reason: "input too long (\(trimmed.count) chars)")
        }
        let lowered = trimmed.lowercased()
        if let hit = actionKeywords.first(where: { lowered.contains($0.lowercased()) }) {
            return Decision(route: .main, reason: "action keyword '\(hit)'")
        }
        guard messageCount <= maxMessageCount else {
            return Decision(route: .main, reason: "conversation too long (\(messageCount) messages)")
        }
        return Decision(route: .cheap, reason: "short question, no actions, no plan")
    }
}
