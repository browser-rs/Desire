import Foundation

/// 后台任务日志脱敏（v0.8.40）：写入与读取都过一遍，避免命令把 token/
/// Authorization/密码打进日志后被 Jobs 面板、通知或 Remote 带出。
///
/// 规则刻意保守：只替换“键 + 值”以及明显的 Bearer/sk-/ghp_ 形态，不碰普通
/// 单词；正则用替换时现算，不缓存 NSRange（AGENTS 的越界教训）。
nonisolated enum JobLogRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)(authorization\s*:\s*(?:bearer\s+)?)[^\s]+"#, "$1[redacted]"),
        (#"(?i)((?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|secret)\s*[=:]\s*)[^\s,;]+"#, "$1[redacted]"),
        (#"\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|xox[bap]-[A-Za-z0-9-]{10,})\b"#, "[redacted]"),
    ]

    static func redact(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in patterns {
            // 每轮现算范围：上一轮替换可能改变长度（见 AGENTS NSRange 教训）。
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}
