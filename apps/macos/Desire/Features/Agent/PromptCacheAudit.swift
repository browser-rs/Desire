import Foundation

/// 提示词缓存前缀审计（v0.8.81 批 3）。
///
/// 服务端的提示词缓存按 **token 前缀**命中：system 里任何一处早期变化都会让
/// 后面的全部失效。这里把 system 拆成"稳定段"（identity/memory/skills/tools）
/// 与"动态段"（environment 起——含当前时间与页面内容），只对稳定段做哈希；
/// 与同一会话上一次请求比对，得出"前缀是否变化 / 变化来自哪一层"。
///
/// 纯 Foundation：哈希与分层提取可离线单测。`fnv1a` 不需要 CryptoKit，跨进程
/// 稳定，够用于"是否变化"的判定（不是安全哈希）。
nonisolated enum PromptCacheAudit {
    struct Result: Equatable, Sendable {
        /// 稳定段的 64 位 FNV-1a 哈希（十六进制）。
        let prefixHash: String
        /// 稳定段字符数（诊断/统计页）。
        let prefixChars: Int
        /// nil = 与上次相同；"first" = 本会话第一次；否则是变化来源层。
        let changedReason: String?
        /// 各层哈希（随消息落盘，下一次请求据此定位变化来源）。
        let sectionHashes: [String: String]
    }

    /// 稳定段的结束标记：environment 起含当前时间与页面上下文，必须排除。
    static let stableSectionNames = ["persona", "identity", "output_rules",
                                     "session_directive", "user_memory", "skills",
                                     "tools", "turn_scope"]

    static func stablePrefix(of system: String) -> String {
        if let range = system.range(of: "\n\n<environment>") {
            return String(system[..<range.lowerBound])
        }
        // 没有 environment 段（子代理/旧格式）时只截掉最后一屏动态内容兜底。
        return String(system.prefix(24_000))
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// `previousSectionHashes` 来自同一会话上一条带审计的助手消息；nil = 首次。
    static func evaluate(system: String,
                         previousSectionHashes: [String: String]?) -> Result {
        let stable = stablePrefix(of: system)
        let hashes = sectionHashes(in: stable)
        let hash = fnv1a(stable)
        let reason: String?
        if previousSectionHashes == nil {
            reason = "first"
        } else if previousSectionHashes == hashes {
            reason = nil
        } else {
            reason = changedReason(previous: previousSectionHashes ?? [:], current: hashes)
        }
        return Result(prefixHash: hash, prefixChars: stable.count,
                      changedReason: reason, sectionHashes: hashes)
    }

    /// 变化来源：按"越靠前越致命"的顺序报告第一个不同的层。
    static func changedReason(previous: [String: String],
                              current: [String: String]) -> String {
        let order = stableSectionNames
        for name in order where previous[name] != current[name] {
            return name
        }
        return "other"
    }

    /// 按已知标签抽每层的文本哈希。缺失的层不写入（第一次出现时会被当作变化）。
    static func sectionHashes(in system: String) -> [String: String] {
        var out: [String: String] = [:]
        for name in stableSectionNames {
            guard let open = system.range(of: "<\(name)>"),
                  let close = system.range(of: "</\(name)>", range: open.upperBound..<system.endIndex) else {
                continue
            }
            let body = String(system[open.upperBound..<close.lowerBound])
            out[name] = fnv1a(body)
        }
        return out
    }

    /// 统计页/诊断一行（nil = 无变化）。
    static func displayName(for reason: String) -> String {
        switch reason {
        case "first": return String(localized: "first request in this conversation")
        case "tools": return String(localized: "tool catalog changed")
        case "user_memory": return String(localized: "memory changed")
        case "skills": return String(localized: "skills changed")
        case "session_directive": return String(localized: "session directive changed")
        case "identity": return String(localized: "instructions changed")
        case "persona": return String(localized: "persona changed")
        case "output_rules": return String(localized: "output rules changed")
        case "turn_scope": return String(localized: "tool scope changed")
        default: return String(localized: "prompt prefix changed")
        }
    }
}
