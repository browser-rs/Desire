import Foundation

/// "批准本轮剩余同类调用"的匹配口径（v0.8.80 批 3）：
/// **工具 + 站点 + 参数模式**。参数模式取顶层键集合（不取具体值）——同一工具
/// 的同类操作（如两条 addBookmark 只是 url 不同）才会被批量放行，换了参数
/// 形状就重新问。
///
/// 纯逻辑（Foundation-only），供 harness 单测与审批闸共用；危险级工具永远不
/// 进批（由调用方把关）。
nonisolated struct ApprovalBatchPattern: Equatable, Codable {
    let tool: String
    /// 审批时的页面 host（归一化为小写；nil 表示无站点上下文）。
    let siteHost: String?
    /// 顶层参数键（排序后），例如 ["title", "url"]。
    let argumentKeys: [String]

    init(tool: String, siteHost: String?, argumentsJSON: String) {
        self.tool = tool
        let normalized = siteHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.siteHost = (normalized?.isEmpty ?? true) ? nil : normalized
        self.argumentKeys = Self.topLevelKeys(argumentsJSON)
    }

    func matches(tool: String, siteHost: String?, argumentsJSON: String) -> Bool {
        guard tool == self.tool else { return false }
        let normalized = siteHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = (normalized?.isEmpty ?? true) ? nil : normalized
        guard host == self.siteHost else { return false }
        return Self.topLevelKeys(argumentsJSON) == argumentKeys
    }

    /// 参数不是合法 JSON 对象时退化为"无参数模式"——宁可多问一次，也不把
    /// 形状不明的调用批量放行。
    static func topLevelKeys(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return object.keys.sorted()
    }
}
