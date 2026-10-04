import Foundation

/// chrome.declarativeNetRequest 规则模型（MV3 子集）。全部字段 optional 化
/// ——插件端 JSON 解码对未知/缺失键宽容；只映射 WebKit content blocker
/// 能表达的语义（见 DNRConverter 的丢弃清单）。
struct DNRRule: Codable, Equatable {
    var id: Int
    var priority: Int?
    var action: DNRAction
    var condition: DNRCondition?
}

struct DNRAction: Codable, Equatable {
    var type: String
    var redirect: DNRRedirect?
}

struct DNRRedirect: Codable, Equatable {
    var url: String?
    var extensionPath: String?
    var regexSubstitution: String?
}

struct DNRCondition: Codable, Equatable {
    var urlFilter: String?
    var regexFilter: String?
    var resourceTypes: [String]?
    var initiatorDomains: [String]?
    var excludedInitiatorDomains: [String]?
    var requestDomains: [String]?
    var domainType: String?
}

/// updateDynamicRules/updateSessionRules 的入参信封。
struct DNROptions: Codable {
    var addRules: [DNRRule]?
    var removeRuleIds: [Int]?
}

/// manifest `declarative_net_request.rule_resources[].path` 指向的静态
/// 规则文件格式（`{"rules": [...]}`；裸数组也认）。
struct DNRStaticRulesFile: Codable {
    var rules: [DNRRule]?
}
