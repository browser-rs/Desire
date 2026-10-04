import Foundation

/// 输出护栏：把**密钥**在进入对话之前屏蔽掉。
///
/// 两道判据，一严一宽：
/// ① **应用自己配置的密钥**（所有服务档案的 Key）——精确匹配，永远该屏蔽：它们是这台机器
///    上真实可用的凭据，一旦被工具结果（`cat` 一个配置、`curl -v` 打印请求头…）带进对话，
///    就会跟着会话文件落盘、并被**发往模型服务**（可能是第三方的 reviewer）——这是最该堵的
///    一条路，而它恰好无法靠"形态"识别（自建网关的 Key 往往没有任何特征）。
/// ② **常见密钥形态**（OpenAI/Anthropic/GitHub/AWS/Slack/Google/GitLab、`Bearer …`、
///    PEM 私钥块）——保守匹配，都要求足够长的特征串，避免误伤普通正文。
///
/// 只在**工具结果**与**回合结束时的助手文本**上跑（不逐 token 跑：那是热路径，而且流式的
/// 中间态本来就会被覆盖）。屏蔽发生在**消息入会话之前**——模型看不到，也就无从复述。
enum SecretRedactor {
    static let mask = "[redacted]"

    /// 形态规则。**保守**：每条都带长度下限，宁可漏也不能误伤（正文里出现 "sk-" 很正常）。
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // OpenAI / 兼容网关
            #"sk-[A-Za-z0-9_\-]{16,}"#,
            // Anthropic
            #"sk-ant-[A-Za-z0-9_\-]{16,}"#,
            // GitHub PAT / OAuth / App
            #"gh[pousr]_[A-Za-z0-9]{20,}"#,
            // AWS access key id
            #"AKIA[0-9A-Z]{16}"#,
            // Slack
            #"xox[baprs]-[A-Za-z0-9\-]{10,}"#,
            // Google API key
            #"AIza[0-9A-Za-z_\-]{30,}"#,
            // GitLab PAT
            #"glpat-[A-Za-z0-9_\-]{16,}"#,
            // 请求头里的 Bearer token
            #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// PEM 私钥块（`-----BEGIN … PRIVATE KEY-----` 到 `-----END … -----`）。
    private static let privateKeyBlock = try? NSRegularExpression(
        pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    )

    /// 屏蔽后的文本。没有任何命中时**原样返回**（调用方可以据此跳过一次写入）。
    static func redact(_ text: String, knownKeys: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        var out = text

        // ① 应用自己的 Key：先做精确替换（形态规则可能认不出自建网关的 Key）。
        for key in knownKeys where key.count >= 8 && out.contains(key) {
            out = out.replacingOccurrences(of: key, with: mask)
        }

        // ② 形态规则 + PEM 块。**每轮都必须重算 NSRange**：`mask` 比任何命中都短，
        //    替换一次字符串就变短，任何循环外缓存的旧范围立刻越界——Foundation 会抛
        //    NSRangeException。这个异常从 Swift async 帧里穿出去时会废掉当前 actor
        //    （2026-09-23 实测：主 actor 永久卡死，桥端点全部无响应，界面照旧渲染）。
        func maskAllMatches(of regex: NSRegularExpression) {
            let range = NSRange(out.startIndex..., in: out)
            guard regex.firstMatch(in: out, range: range) != nil else { return }
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: mask)
        }
        for regex in patterns { maskAllMatches(of: regex) }
        if let privateKeyBlock { maskAllMatches(of: privateKeyBlock) }
        return out
    }

    /// 是否会被屏蔽（用于测试与日志，不返回原文）。
    static func containsSecret(_ text: String, knownKeys: [String] = []) -> Bool {
        redact(text, knownKeys: knownKeys) != text
    }
}
