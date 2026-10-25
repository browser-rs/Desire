import Foundation

/// DPP 适配包**创作辅助**的纯逻辑半边（Agent 帮用户生成适配包，2026-10-12）：
/// 模型交来的字段 → 校验 + 渲染成 adapter-1 JSON。与 SkillAuthoring 同一模式
/// （纯函数进 harness；落盘与 reload 在工具执行侧）。
nonisolated enum DPPAdapterAuthoring {

    /// 字段校验错误清单（空 = 可渲染）。
    static func validate(name: String, hosts: [String], pathPrefixes: [String]) -> [String] {
        var errors: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { errors.append("name is required") }
        if trimmedName.contains("/") { errors.append("name cannot contain /") }
        if hosts.isEmpty { errors.append("at least one host is required") }
        for h in hosts where h.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("host entries cannot be empty")
            break
        }
        for p in pathPrefixes where !p.hasPrefix("/") {
            errors.append("pathPrefix '\(p)' must start with /")
        }
        return errors
    }

    /// 渲染 adapter-1 JSON（pretty print——用户可在设置页/目录里直接读懂改）。
    /// host 统一小写去空白；name 去首尾。protocolBody 由调用方给（views/signals/actions）。
    /// opsVersion/verifiedAt：运营包元数据（v0.8.3）——`ops/1` 与"真实页面核对时间"，
    /// 由调用方（Agent 工具/Studio）在通过 ops 校验后填。
    static func markdown(name: String, hosts: [String], pathPrefixes: [String],
                         notes: String, protocolBody: DesireProtocol,
                         opsVersion: Int? = nil, verifiedAt: Date? = nil,
                         loginURL: String? = nil) -> Data? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHosts = hosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                              .filter { !$0.isEmpty }
        var adapter = DPPAdapter(name: trimmedName, hosts: cleanHosts,
                                 pathPrefixes: pathPrefixes,
                                 protocolBody: protocolBody,
                                 notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                                 opsVersion: opsVersion, verifiedAt: verifiedAt,
                                 loginURL: loginURL?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
        adapter.protocolBody.warnings.append("adapter: \(trimmedName)")
        adapter.installedAt = Date()   // 创建/更新即视为已核对（陈旧提示的基准）
        let formatter = JSONEncoder()
        formatter.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? formatter.encode(adapter)
    }

    /// 从页面 URL 推导默认包名（如 https://www.juejin.cn/post/1 → "juejin"）：
    /// 去掉 www. / m. 前缀、取注册域主名、非字母数字转连字符。
    static func suggestedName(for url: URL) -> String {
        guard let host = url.host else { return "unknown-site" }
        var h = host.lowercased()
        for prefix in ["www.", "m.", "mobile."] where h.hasPrefix(prefix) {
            h = String(h.dropFirst(prefix.count))
        }
        // 取主域（最后两段——对常见 .com/.cn/.org 够用；多级后缀站手改）
        let parts = h.split(separator: ".")
        let base = parts.count >= 2 ? String(parts[parts.count - 2]) : h
        let cleaned = base.unicodeScalars.map { sc in
            CharacterSet.alphanumerics.contains(sc) ? Character(sc) : "-"
        }
        return String(String(cleaned).drop { $0 == "-" })
    }
}


nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
