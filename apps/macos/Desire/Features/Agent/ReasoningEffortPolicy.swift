import Foundation

/// 思考等级（reasoning effort）的线值适配与能力学习。
///
/// 各家 OpenAI 兼容服务的词汇并不统一：OpenAI 用 `minimal/low/medium/high`，
/// 有的网关把最大档叫 `xhigh` 或 `max`（例如 AMD 网关明确返回
/// `Supported types are xhigh (default), medium, and low`），直接发 `high`
/// 会 400。主流客户端的处理方式是按服务真实支持的取值表映射，而不是把错误
/// 甩给用户、也不是偷偷把全局设置改成 Off。
///
/// 这里做三件事：
/// 1. 从服务端错误文本里解析支持列表（"Supported types are …"）；
/// 2. 把 UI 档位（off/low/medium/high）映射到该列表里最接近的线值；
/// 3. 按 `endpoint|model` 记住这张表（UserDefaults），下次请求直接用对的词。
///
/// 纯逻辑 + UserDefaults，无 AppKit 依赖，进 harness（tests/run.sh）。
nonisolated enum ReasoningEffortPolicy {
    /// 输入栏暴露的档位（顺序即菜单顺序）。`off` 表示不带参数。
    static let uiLevels = ["off", "low", "medium", "high"]

    /// 各服务出现过的线值（解析错误信息时只认这些词，避免把普通单词当档位）。
    private static let vocabulary: Set<String> = [
        "minimal", "low", "medium", "high", "xhigh", "max", "none", "off",
    ]

    private static let defaultsKey = "aiReasoningSupport"

    /// 学习结果按端点 + 模型归档：换服务/换模型各有一张表。
    static func supportKey(endpoint: String, model: String) -> String {
        "\(endpoint.lowercased())|\(model.lowercased())"
    }

    /// 已知支持列表；`nil` = 还没学到，`[]` = 明确不支持可调档位。
    static func supportedValues(endpoint: String, model: String,
                                defaults: UserDefaults = .standard) -> [String]? {
        all(defaults: defaults)[supportKey(endpoint: endpoint, model: model)]
    }

    static func all(defaults: UserDefaults = .standard) -> [String: [String]] {
        defaults.dictionary(forKey: defaultsKey)?
            .compactMapValues { $0 as? [String] } ?? [:]
    }

    static func remember(supported: [String], endpoint: String, model: String,
                         defaults: UserDefaults = .standard) {
        var map = all(defaults: defaults)
        map[supportKey(endpoint: endpoint, model: model)] = supported
        defaults.set(map, forKey: defaultsKey)
    }

    static func forget(endpoint: String, model: String, defaults: UserDefaults = .standard) {
        var map = all(defaults: defaults)
        map.removeValue(forKey: supportKey(endpoint: endpoint, model: model))
        defaults.set(map, forKey: defaultsKey)
    }

    /// 从错误文本里提取支持列表。识别形如：
    /// - "Supported types are xhigh (default), medium, and low."
    /// - "Supported values: low, medium, high."
    /// 至少两个已知词才算解析成功（单个词多半是误命中）。
    static func parseSupportedValues(from text: String) -> [String]? {
        let lowered = text.lowercased()
        let anchors = ["supported type", "supported value", "supported effort", "supported:"]
        var tail: Substring?
        for anchor in anchors {
            if let range = lowered.range(of: anchor) {
                tail = lowered[range.upperBound...]
                break
            }
        }
        guard var tail else { return nil }
        if tail.count > 240 { tail = tail.prefix(240) }
        let tokens = tail.split { !($0.isLetter || $0 == "-" || $0 == "_") }
            .map { String($0) }
        var seen: [String] = []
        for token in tokens where vocabulary.contains(token) && !seen.contains(token) {
            seen.append(token)
        }
        return seen.count >= 2 ? seen : nil
    }

    /// UI 档位 → 请求里的 `reasoning_effort`。`nil` = 不带这个参数。
    ///
    /// `supported == nil`（未学到）时用标准拼写；学到之后按表映射，最大档
    /// 优先取服务的最大词（xhigh/max），否则退回 high，再否则取最接近的。
    static func wireValue(for level: String, supported: [String]?) -> String? {
        let level = level.lowercased()
        guard level != "off" else { return nil }
        let standard = ["low", "medium", "high"].contains(level) ? level : "medium"
        guard let supported else { return standard }
        guard !supported.isEmpty else { return nil }
        let values = supported.map { $0.lowercased() }

        if standard == "high" {
            for candidate in ["xhigh", "max", "high"] where values.contains(candidate) {
                return candidate
            }
        } else if values.contains(standard) {
            return standard
        }

        let rank: [String: Int] = [
            "minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 4,
        ]
        let target = rank[standard] ?? 2
        let nearest = values.compactMap { value in rank[value].map { (value, $0) } }
            .min { lhs, rhs in
                let dl = abs(lhs.1 - target), dr = abs(rhs.1 - target)
                return dl == dr ? lhs.1 > rhs.1 : dl < dr
            }
        return nearest?.0 ?? standard
    }

    /// 该模型应该出现在菜单里的档位。未知 = 全部；明确不支持 = 只有 Off；
    /// 已知列表 = 只列能精确对应的档位（避免"选了 low 实际发 high"的误导）。
    static func offeredLevels(supported: [String]?) -> [String] {
        guard let supported else { return uiLevels }
        guard !supported.isEmpty else { return ["off"] }
        let values = Set(supported.map { $0.lowercased() })
        var levels = ["off"]
        if !values.isDisjoint(with: ["low", "minimal"]) { levels.append("low") }
        if values.contains("medium") { levels.append("medium") }
        if !values.isDisjoint(with: ["high", "xhigh", "max"]) { levels.append("high") }
        return levels.count > 1 ? levels : uiLevels
    }
}
