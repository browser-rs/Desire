import Foundation

/// 审批策略规则（0.2.6；0.8.1 加站点维度）。
///
/// `host == nil` 的规则是全局规则：该工具在任何页面上都按规则放行/拒绝。
/// 带 host 的规则只在**该 host 的页面处于前台**时参与匹配，粒度是
/// 「工具 × 站点」——用户在审批卡上点“Always on <site>”时写入。
///
/// 匹配优先级：host 点名的规则 > 全局规则。于是“全局允许 executeJS、但对
/// 银行站点单独拒绝”可以表达，且不必删掉全局规则。
struct ApprovalPolicy: Codable, Identifiable, Equatable {
    let id: UUID
    /// 工具名（精确匹配）。
    var toolName: String
    /// 站点 host（已归一化：小写、去空白与尾点）。nil = 全局。
    var host: String?
    var decision: Decision
    var createdAt: Date

    enum Decision: String, Codable {
        case allow
        case deny
    }

    init(id: UUID = UUID(), toolName: String, host: String? = nil,
         decision: Decision, createdAt: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.host = ApprovalPolicy.normalizeHost(host)
        self.decision = decision
        self.createdAt = createdAt
    }

    /// host 归一化：小写、去首尾空白与结尾的点。空串归一为 nil（全局）。
    nonisolated static func normalizeHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// 选出对该工具 + 当前页面生效的规则（host 点名的优先于全局）。
    ///
    /// 纯函数、无状态：store、桥与单测共用同一套匹配语义，避免“设置页
    /// 显示已放行、执行侧仍弹审批”这类口径分叉。
    nonisolated static func effectiveRule(in rules: [ApprovalPolicy],
                                          toolName: String,
                                          host: String?) -> ApprovalPolicy? {
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return nil }
        if let site = normalizeHost(host),
           let scoped = rules.last(where: { $0.toolName == tool && $0.host == site }) {
            return scoped
        }
        return rules.last(where: { $0.toolName == tool && $0.host == nil })
    }
}
