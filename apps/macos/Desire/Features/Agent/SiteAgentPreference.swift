import Foundation

/// 站点级 Agent 偏好（v0.8.25）：按 host 记录"允许自动操作 / 需要确认 /
/// 始终隔离容器"。与审批策略（工具 × 站点）互补：那份管单个工具，
/// 这份管该站点上 Agent 的整体姿态。
nonisolated struct SiteAgentPreference: Codable, Identifiable, Equatable, Sendable {
    /// 归一化 host（小写、去尾点）。
    var host: String
    /// 放行副作用工具（不含 dangerous 级）。
    var autoOperate: Bool = false
    /// 强制人工确认（压过 autoOperate / autoEdit / 白名单）。
    var requireConfirmation: Bool = false
    /// Agent 在本站开新标签时进独立容器（`Isolated · <host>`）。
    var alwaysIsolate: Bool = false
    var updatedAt: Date = Date()

    var id: String { host }
}

nonisolated enum SiteAgentPreferenceCore {
    /// host 归一化：小写、去首尾空白与结尾的点；空 = nil。
    static func normalizeHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// 应用一次修改。三个开关里 autoOperate 与 requireConfirmation 互斥
    ///（后设置的那个赢——"我就是要它自动"与"每次都问我"不能同时成立）。
    static func apply(existing: SiteAgentPreference,
                      autoOperate: Bool? = nil,
                      requireConfirmation: Bool? = nil,
                      alwaysIsolate: Bool? = nil,
                      now: Date = Date()) -> SiteAgentPreference {
        var out = existing
        if let autoOperate {
            out.autoOperate = autoOperate
            if autoOperate { out.requireConfirmation = false }
        }
        if let requireConfirmation {
            out.requireConfirmation = requireConfirmation
            if requireConfirmation { out.autoOperate = false }
        }
        if let alwaysIsolate { out.alwaysIsolate = alwaysIsolate }
        out.updatedAt = now
        return out
    }

    /// 全空 = 没有存留价值（设置页/存储清理用）。
    static func isEmpty(_ pref: SiteAgentPreference) -> Bool {
        !pref.autoOperate && !pref.requireConfirmation && !pref.alwaysIsolate
    }

    /// 该 host 的隔离容器名（创建在 newTab 路径里按需触发）。
    static func isolatedContainerName(for host: String) -> String {
        "Isolated · \(host)"
    }
}
