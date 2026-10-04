import Foundation

/// DNR 规则 → WebKit content blocker JSON 的纯转换（Foundation-only，进
/// tests/run.sh）。映射不了 WebKit 语义的规则**逐条丢弃并给理由**——
/// 拦截类扩展常常只依赖规则集的一个子集，整包失败会让扩展全废。
///
/// 三条 WebKit 硬约束（AGENTS 有全文，2026-09-21 实测）直接决定这里的
/// 形状：resource-type 词汇表 / 一个 trigger 只能一个域条件 / url-filter
/// 禁组内 `$`（`^` 只能译成 `[/?#]`）。
enum DNRConverter {

    struct ConversionError: Error {
        let message: String
        static func reason(_ m: String) -> ConversionError { ConversionError(message: m) }
    }

    struct Outcome {
        let rules: [[String: Any]]
        let dropped: [Drop]

        struct Drop: Equatable {
            let id: Int
            let reason: String
        }
    }

    /// 排序 + 转换。**allow 类规则必须排在最后**：WebKit 的
    /// ignore-previous-rules 只豁免"排在它之前"的规则——按 Chrome 优先级
    /// 正排会让 allow 落在最前（前面没有规则可豁免 = 形同虚设）。
    /// 拦截类规则按优先级降序，allow 收尾。
    static func convert(_ rules: [DNRRule]) -> Outcome {
        let sorted = rules.sorted { a, b in
            let allowA = (a.action.type == "allow" || a.action.type == "allowAllRequests")
            let allowB = (b.action.type == "allow" || b.action.type == "allowAllRequests")
            if allowA != allowB { return !allowA }
            return (a.priority ?? 1) > (b.priority ?? 1)
        }
        var out: [[String: Any]] = []
        var dropped: [Outcome.Drop] = []
        for rule in sorted {
            switch webkitRule(rule) {
            case .success(let object):
                out.append(object)
            case .failure(let error):
                dropped.append(Outcome.Drop(id: rule.id, reason: error.message))
            }
        }
        return Outcome(rules: out, dropped: dropped)
    }

    static func webkitRule(_ rule: DNRRule) -> Result<[String: Any], ConversionError> {
        guard rule.id > 0 else {
            return .failure(.reason("invalid id"))
        }
        let condition = rule.condition ?? DNRCondition()
        // 动作映射（modifyHeaders 是 WebKit 表达不了的——丢弃）。
        let action: [String: Any]
        switch rule.action.type {
        case "block":
            action = ["type": "block"]
        case "allow", "allowAllRequests":
            // 近似：WebKit 没有独立 allow，ignore-previous-rules 免疫更早规则。
            action = ["type": "ignore-previous-rules"]
        case "upgradeScheme":
            action = ["type": "make-https"]
        case "redirect":
            guard let url = rule.action.redirect?.url, !url.isEmpty else {
                return .failure(.reason("redirect requires redirect.url (extensionPath/regexSubstitution unsupported)"))
            }
            action = ["type": "redirect", "redirect": ["url": url]]
        case "modifyHeaders":
            return .failure(.reason("modifyHeaders unsupported (WebKit content blocker cannot rewrite headers)"))
        default:
            return .failure(.reason("unsupported action type: \(rule.action.type)"))
        }
        // 过滤条件：urlFilter/regexFilter 二选一（DNR 语义）。
        var urlFilter: String
        if let regex = condition.regexFilter, !regex.isEmpty {
            if condition.urlFilter?.isEmpty == false {
                return .failure(.reason("urlFilter and regexFilter are mutually exclusive"))
            }
            if hasDollarInsideGroup(regex) {
                return .failure(.reason("regexFilter has `$` inside a group (WebKit rejects)"))
            }
            urlFilter = regex
        } else if let plain = condition.urlFilter, !plain.isEmpty {
            urlFilter = convertURLFilter(plain)
        } else {
            urlFilter = ".*"
        }
        var trigger: [String: Any] = ["url-filter": urlFilter]
        // resource-type 词汇表映射；映射不了的类型跳过（全 unmappable → 丢规则）。
        var types: [String] = []
        for raw in condition.resourceTypes ?? [] {
            if let mapped = resourceType(raw) { types.append(mapped) }
        }
        if let rawList = condition.resourceTypes, !rawList.isEmpty, types.isEmpty {
            return .failure(.reason("no expressible resource types: \(rawList.joined(separator: ","))"))
        }
        if !types.isEmpty { trigger["resource-type"] = types }
        // 域条件只能一个（WebKit 硬约束）；initiatorDomains 是发起页域
        //（与 ABPRuleConverter 的 $domain= → if-domain 同一先例）；
        // requestDomains 是资源 URL 域——WebKit 无对应键，丢弃带理由。
        if let ifDomains = condition.initiatorDomains, !ifDomains.isEmpty {
            trigger["if-domain"] = ifDomains
        }
        if let unlessDomains = condition.excludedInitiatorDomains, !unlessDomains.isEmpty {
            if trigger["if-domain"] != nil {
                return .failure(.reason("initiatorDomains + excludedInitiatorDomains both set (WebKit allows one domain condition)"))
            }
            trigger["unless-domain"] = unlessDomains
        }
        // requestDomains 匹配资源 URL 域——WebKit content blocker 没有这个
        // 维度（if-domain 是发起页域），静默近似会错杀，明确丢弃。
        if let requestDomains = condition.requestDomains, !requestDomains.isEmpty {
            return .failure(.reason("requestDomains unsupported (WebKit has no resource-domain condition)"))
        }
        switch condition.domainType {
        case "thirdParty": trigger["load-type"] = ["third-party"]
        case "firstParty": trigger["load-type"] = ["first-party"]
        default: break
        }
        return .success(["trigger": trigger, "action": action])
    }

    /// DNR urlFilter 语法（`*` 通配、`^` 分隔符、`||`/`|` 锚点）→ WebKit
    /// url-filter 正则。其余字符一律转义（`.` 不转义会把 `?` 放出来、
    /// `*` 会通配别家 URL——InterceptStore 注释同款教训）。
    static func convertURLFilter(_ raw: String) -> String {
        var pattern = Substring(raw)
        var prefix = ""
        var suffix = ""
        if pattern.hasPrefix("||") {
            // `||host` = scheme 任意 + 域起点（host 前缀可有可无的点）。
            prefix = "^[a-z-]+://(?:[^/?#]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            prefix = "^"
            pattern = pattern.dropFirst(1)
        }
        if pattern.hasSuffix("|") {
            suffix = "$"
            pattern = pattern.dropLast(1)
        }
        var out = ""
        for character in pattern {
            switch character {
            case "*": out += ".*"
            case "^": out += "[/?#]"
            case ".": out += "\\."
            case "?": out += "\\?"
            case "+": out += "\\+"
            case "(": out += "\\("
            case ")": out += "\\)"
            case "[": out += "\\["
            case "]": out += "\\]"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "|": out += "\\|"
            case "\\": out += "\\\\"
            default: out.append(character)
            }
        }
        return prefix + out + suffix
    }

    /// WebKit 硬约束 ③：url-filter 正则里组内 `$` 让整份列表编译失败。
    static func hasDollarInsideGroup(_ regex: String) -> Bool {
        var depth = 0
        var escaped = false
        for character in regex {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == "$" && depth > 0 { return true }
        }
        return false
    }

    /// DNR resourceTypes → WebKit resource-type 词汇表。映射不了的
    ///（sub_frame/websocket/ping/csp_report 等）返回 nil 跳过。
    static func resourceType(_ raw: String) -> String? {
        switch raw {
        case "main_frame": return "document"
        case "script": return "script"
        case "image": return "image"
        case "stylesheet": return "style-sheet"
        case "font": return "font"
        case "media": return "media"
        case "xmlhttprequest", "other", "object": return "raw"
        default: return nil
        }
    }
}
