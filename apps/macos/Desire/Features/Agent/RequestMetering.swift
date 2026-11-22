import Foundation

/// **请求分层计量**（v0.8.74 批 1，Foundation-only 进 tests/run.sh）：每次
/// 模型调用的请求由固定基础（身份/记忆/技能/工具索引/环境）+ 每请求新鲜
/// （页面上下文/历史）+ 工具 schema 组成——真实采样 p50 = 130,788 prompt
/// tokens，但"构成"此前不可见。本计量与请求组装**同源**（组装点填充、
/// 流式点补充 schema），字符账管构成、prompt_tokens 真值（0.8.71）管成本。
nonisolated enum RequestMetering {

    struct Layers: Codable, Equatable {
        var identity: Int = 0        // 身份/人设/输出规则/会话指令
        var memory: Int = 0          // 记忆块（L0-L2 注入）
        var skills: Int = 0          // 技能清单
        var toolsIndex: Int = 0      // 工具索引行（系统提示词内）
        var environment: Int = 0     // 环境（工作目录/下载/ffmpeg/书/会话 id）
        var pageContext: Int = 0     // 页面上下文（每请求新鲜）
        var notes: Int = 0           // 带外备注（Session notes）
        var digest: Int = 0          // 压缩摘要（Earlier conversation）
        var history: Int = 0         // 对话历史（消息体 + tool_calls 参数）
        var toolsSchema: Int = 0     // 工具 JSON schema（每请求全量）

        var total: Int {
            identity + memory + skills + toolsIndex + environment
                + pageContext + notes + digest + history + toolsSchema
        }

        /// 会话累计：逐字段相加（值类型，返回新实例）。
        func adding(_ other: Layers) -> Layers {
            var out = self
            out.identity += other.identity
            out.memory += other.memory
            out.skills += other.skills
            out.toolsIndex += other.toolsIndex
            out.environment += other.environment
            out.pageContext += other.pageContext
            out.notes += other.notes
            out.digest += other.digest
            out.history += other.history
            out.toolsSchema += other.toolsSchema
            return out
        }
    }

    /// 历史侧计量：消息体 + tool_calls 参数（与压缩 size 同口径）。
    static func historyChars(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) {
            $0 + ($1.content?.count ?? 0)
                + ($1.toolCalls?.reduce(0) {
                    $0 + $1.function.arguments.count + $1.function.name.count
                } ?? 0)
        }
    }

    /// schema 侧计量：JSON 序列化长度（与请求实际发送的形态一致，含参数
    /// schema）。编码 100KB 级每次 ~1ms，流式点每次调用一次可接受。
    static func schemaChars(_ defs: [AgentToolDef]) -> Int {
        guard let data = try? JSONEncoder().encode(defs) else { return 0 }
        return String(decoding: data, as: UTF8.self).count
    }

    /// 单行日志（debug 可查的分层构成）。
    static func logLine(_ layers: Layers) -> String {
        "request layers: identity=\(layers.identity) memory=\(layers.memory) " +
            "skills=\(layers.skills) toolsIndex=\(layers.toolsIndex) " +
            "env=\(layers.environment) page=\(layers.pageContext) " +
            "notes=\(layers.notes) digest=\(layers.digest) " +
            "history=\(layers.history) schema=\(layers.toolsSchema) " +
            "total=\(layers.total)"
    }
}


/// **schema 瘦身**（v0.8.74 批 2）：请求发送前对超长描述做**句边界截断**——
/// 完整描述保留在源码（文档/维护面不变），实发 schema 只带要点。实测：
/// schema 179.6k 字符中描述 ≈60k、协议脚手架 ≈110k（不可动）——描述瘦身是
/// 唯一杠杆。工具 ≤700（复杂 JSON 契约工具在 exempt 名单，整体保留）、
/// 参数 ≤160（首句通常已含要点）。幂等（再截无变化）。
nonisolated enum AgentToolSchemaSlimming {

    /// 复杂 JSON 契约工具：参数/动作说明是一个整体，截断会破坏可驱动性——
    /// 豁免整体截断（三份 description 合计 ~4.6k 字符，代价可接受）。
    static let exempt: Set<String> = ["editImage", "editVideoPro", "editTimeline"]

    static func slimmed(_ defs: [AgentToolDef], toolLimit: Int = 700,
                        paramLimit: Int = 160) -> [AgentToolDef] {
        defs.map { def in
            var out = def
            if !exempt.contains(def.function.name) {
                out.function.description = firstSentences(def.function.description, limit: toolLimit)
            }
            if let params = out.function.parameters.properties {
                var trimmed: [String: AgentJSONSchemaValue] = [:]
                for (key, value) in params {
                    var v = value
                    v.description = v.description.map { firstSentences($0, limit: paramLimit) }
                    trimmed[key] = v
                }
                out.function.parameters.properties = trimmed
            }
            return out
        }
    }

    /// 按句边界累积（中英句号/换行切句），不超 limit；第一句必须保留。
    static func firstSentences(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let sentences = text.split(omittingEmptySubsequences: false,
                                   whereSeparator: { $0 == "." || $0 == "。" || $0 == "\n" })
        var out = ""
        for sentence in sentences {
            let candidate = out.isEmpty ? String(sentence) : out + String(sentence)
            if candidate.count > limit { break }
            out = candidate
        }
        if out.isEmpty { out = String(text.prefix(limit)) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
