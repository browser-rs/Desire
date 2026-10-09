import Foundation

/// 技能安全扫描（Skill Scanner，取自 QwenPaw 的 Skill Guard 思想）：技能是
/// 用户/模型写入的指令文本，会经 useSkill 进入模型上下文并驱动 runCommand——
/// 在导入与使用两个时点对内容做模式扫描，给出风险清单（只提示不拦截，
/// 拦截交给既有的审批链）。Foundation-only：进 tests/run.sh。
nonisolated enum SkillScanner {
    enum Level: String, Comparable {
        case info, medium, high
        static func < (lhs: Level, rhs: Level) -> Bool {
            let order: [Level] = [.info, .medium, .high]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    struct Finding: Equatable {
        let level: Level
        let message: String
    }

    /// 模式清单：保守设计——宁漏不误（正文里出现"删除"很正常），只认
    /// 明确的危险形态。key = 说明文案。
    private static let rules: [(Level, String, NSRegularExpression)] = {
        let defs: [(Level, String, String)] = [
            (.high, "递归强制删除根/家目录（rm -rf / 或 ~）",
             #"rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(/|~|\$HOME)\S*"#),
            (.high, "管道执行远程脚本（curl|wget … | sh/bash）",
             #"(curl|wget)[^|]*\|\s*(sudo\s+)?(ba)?sh\b"#),
            (.high, "格式化或整盘写入（mkfs/dd of=设备）",
             #"(mkfs\.|dd\s+.*of=/dev/)"#),
            (.high, "读取凭据存储（ssh/aws 密钥、钥匙串导出）",
             #"(\.ssh/id_|\.aws/credentials)|security\s+(find-generic-password|dump-keychain)"#),
            (.medium, "sudo 特权命令",
             #"\bsudo\s+[a-z]"#),
            (.medium, "递归强制删除（rm -rf）",
             #"rm\s+(-[a-zA-Z]*[rf])"#),
            (.medium, "全开放文件权限（chmod 777）",
             #"chmod\s+(-R\s+)?777\b"#),
            (.medium, "系统偏好写入（defaults write）",
             #"defaults\s+write\b"#),
            (.medium, "外部数据回传（curl/wget -d/--data 上报）",
             #"(curl|wget)[^\n]*(-d|--data|-F|--form)[^\n]*http"#),
            (.info, "明文口令/密钥字样（password/secret/token =）",
             #"(?i)(password|secret|api[_-]?key|token)\s*[=:]\s*['\"]?[^\s'\"]{6,}"#),
        ]
        return defs.compactMap { level, message, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (level, message, regex)
        }
    }()

    static func findings(in text: String) -> [Finding] {
        guard !text.isEmpty else { return [] }
        // NSRange 现算现用（不做任何改写，无失效风险），同一处命中去重。
        var seen = Set<String>()
        var out: [Finding] = []
        for (level, message, regex) in rules {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil,
               seen.insert(message).inserted {
                out.append(Finding(level: level, message: message))
            }
        }
        return out.sorted { $0.level > $1.level }
    }

    /// 单行风险摘要（列表/工具结果用）：无风险返回 nil。
    static func summary(for text: String) -> String? {
        let found = findings(in: text)
        guard !found.isEmpty else { return nil }
        let high = found.filter { $0.level == .high }.count
        return "⚠️ 风险提示 \(found.count) 条" + (high > 0 ? "（含高危 \(high) 条）" : "")
    }
}
