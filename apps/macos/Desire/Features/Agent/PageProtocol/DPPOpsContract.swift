import Foundation

/// DPP **运营契约**（ops profile，v0.8.3）：把"运营工作台需要的能力"变成
/// DPP 声明里的一组稳定名字，工作台据此发现某站点/适配包能做什么。
///
/// 这是 **profile 约定**，不是 `desire/1` 的新 major：适配包/页面照旧用
/// `protocolBody` 的 views/actions/signals 表达，只是名字统一为 `ops*`。
/// 没有声明的能力 = 不支持，工作台不猜测、不伪造。
///
/// **安全不变量**（校验器强制）：
/// - `opsCompose` 只填表：`effects=local`，不得 `danger`；
/// - `opsPublish` 必须 `effects=persist/outbound` 或 `danger=true`（走审批）；
/// - `opsReply` 必须 `effects=outbound` 或 `danger=true`（走审批）；
/// - 所有动作必须有可解析的 run 步骤，所有视图必须有 item/fields。
///
/// 纯逻辑，Foundation-only，进 harness。
nonisolated enum DPPOpsContract {
    static let version = 1
    static let profileName = "ops"

    /// 运营能力。视图与动作分开命名，但统一成能力集合给 UI/Runbook 用。
    enum Capability: String, CaseIterable, Hashable {
        case account
        case posts
        case metrics
        case comments
        case mentions
        case search
        case composer
        case analytics
        case competitor
        case compose
        case publish
        case reply
        case refresh

        /// UI 用的短标签（英文/中性；本地化在视图层做）。
        var shortLabel: String {
            switch self {
            case .account: return "account"
            case .posts: return "posts"
            case .metrics: return "metrics"
            case .comments: return "comments"
            case .mentions: return "mentions"
            case .search: return "search"
            case .composer: return "composer"
            case .analytics: return "analytics"
            case .competitor: return "competitor"
            case .compose: return "compose"
            case .publish: return "publish"
            case .reply: return "reply"
            case .refresh: return "refresh"
            }
        }
    }

    /// 约定名（协议作者按这些名字声明）。
    static let viewCapabilities: [String: Capability] = [
        "opsAccount": .account,
        "opsPosts": .posts,
        "opsMetrics": .metrics,
        "opsComments": .comments,
        "opsMentions": .mentions,
        "opsSearch": .search,
        "opsComposer": .composer,
        "opsAnalytics": .analytics,
        "opsCompetitor": .competitor,
    ]

    static let actionCapabilities: [String: Capability] = [
        "opsCompose": .compose,
        "opsPublish": .publish,
        "opsReply": .reply,
        "opsSearch": .search,
        "opsRefresh": .refresh,
    ]

    static let signalNames = [
        "opsReady", "opsLoginRequired", "opsBusy", "opsPosted", "opsError",
    ]

    /// 一个协议/适配包的运营能力报告。`errors` 阻止保存/启用；
    /// `warnings` 只提示（例如占位选择器、缺发布动作）。
    struct Report: Equatable {
        var isOps: Bool = false
        var capabilities: Set<Capability> = []
        var views: Set<String> = []
        var actions: Set<String> = []
        var signals: Set<String> = []
        var errors: [String] = []
        var warnings: [String] = []

        var isSafe: Bool { errors.isEmpty }
        /// UI 展示顺序稳定。
        var orderedCapabilities: [Capability] {
            Capability.allCases.filter { capabilities.contains($0) }
        }
    }

    static func report(for proto: DesireProtocol) -> Report {
        var report = Report()
        let viewNames = Set(proto.views.keys)
        let actionNames = Set(proto.actions.map(\.name))
        let signalNames = Set(proto.signals.keys)
        let profile = (proto.profile ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let opsViews = viewNames.filter { Self.viewCapabilities[$0] != nil }
        let opsActions = actionNames.filter { Self.actionCapabilities[$0] != nil }
        let opsSignals = signalNames.filter { Self.signalNames.contains($0) }
        report.views = opsViews
        report.actions = opsActions
        report.signals = opsSignals
        report.isOps = profile == profileName || !opsViews.isEmpty || !opsActions.isEmpty || !opsSignals.isEmpty
        guard report.isOps else { return report }

        for name in opsViews {
            if let capability = Self.viewCapabilities[name] { report.capabilities.insert(capability) }
        }
        for name in opsActions {
            if let capability = Self.actionCapabilities[name] { report.capabilities.insert(capability) }
        }

        if profile != profileName {
            report.warnings.append("ops names declared without `profile: \"ops\"` — add it so consumers know this is an operations contract")
        }

        // ── 视图结构 ──
        for name in opsViews.sorted() {
            guard let view = proto.views[name] else { continue }
            if view.item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.errors.append("\(name).item is empty")
            }
            if view.fields.isEmpty {
                report.errors.append("\(name).fields is empty")
            }
            for (field, spec) in view.fields {
                if isPlaceholder(spec.expression) {
                    report.warnings.append("\(name).\(field) still uses a placeholder selector")
                }
            }
            if isPlaceholder(view.item) {
                report.warnings.append("\(name).item still uses a placeholder selector")
            }
        }

        // ── 动作安全不变量 ──
        var seenActions = Set<String>()
        for action in proto.actions {
            if !seenActions.insert(action.name).inserted {
                report.errors.append("duplicate action name '\(action.name)' — pageAction uses the first one")
            }
        }

        func action(_ name: String) -> DesireProtocol.ProtocolAction? {
            proto.actions.first { $0.name == name }
        }
        func effects(_ action: DesireProtocol.ProtocolAction) -> String {
            (action.effects ?? "local").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func runIsValid(_ action: DesireProtocol.ProtocolAction) -> Bool {
            guard let raw = action.run?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !steps.isEmpty else { return false }
            return true
        }

        for name in opsActions.sorted() {
            guard let action = action(name) else { continue }
            if !runIsValid(action) {
                report.errors.append("\(name).run is missing or not a non-empty JSON step array")
            }
            if let precondition = action.precondition, isPlaceholder(precondition) {
                report.warnings.append("\(name).precondition still uses a placeholder selector")
            }
        }

        if let compose = action("opsCompose") {
            if effects(compose) != "local" {
                report.errors.append("opsCompose must use effects=local (fill only) — submitting belongs to opsPublish")
            }
            if compose.danger == true {
                report.errors.append("opsCompose must not be marked danger — it only fills fields")
            }
            let params = compose.params ?? [:]
            if params["title"] == nil && params["body"] == nil {
                report.warnings.append("opsCompose declares neither title nor body parameter")
            }
        }

        if let publish = action("opsPublish") {
            let e = effects(publish)
            if !["persist", "outbound"].contains(e) && publish.danger != true {
                report.errors.append("opsPublish must use effects=persist/outbound or danger=true — publishing is public and requires approval")
            }
            if publish.precondition == nil && publish.success == nil {
                report.warnings.append("opsPublish has no precondition/success signal — failures may be hard to distinguish")
            }
        }

        if let reply = action("opsReply") {
            let e = effects(reply)
            if e != "outbound" && reply.danger != true {
                report.errors.append("opsReply must use effects=outbound or danger=true — replies are public and require approval")
            }
        }

        if report.capabilities.contains(.compose), !report.capabilities.contains(.composer) {
            report.warnings.append("opsCompose is declared without an opsComposer view — the composer selectors live only in the action")
        }
        if report.capabilities.contains(.publish), !report.capabilities.contains(.compose) {
            report.warnings.append("opsPublish is declared without opsCompose — fill and submit should be separate actions")
        }
        if report.capabilities.contains(.reply),
           report.capabilities.intersection([.comments, .mentions]).isEmpty {
            report.warnings.append("opsReply is declared without opsComments/opsMentions — there is no declared source for reply targets")
        }

        for name in opsSignals.sorted() {
            let selector = proto.signals[name] ?? ""
            if selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.errors.append("signal \(name) has an empty selector")
            } else if isPlaceholder(selector) {
                report.warnings.append("signal \(name) still uses a placeholder selector")
            }
        }

        if profile == profileName && opsViews.isEmpty && opsActions.isEmpty && opsSignals.isEmpty {
            report.warnings.append("profile is ops but no ops* views/actions/signals are declared")
        }

        return report
    }

    /// 适配包/Studio 保存前的校验（结构 + 安全不变量）。
    /// 返回 errors 时禁止保存/启用；warnings 可保存为草稿。
    static func validate(_ proto: DesireProtocol) -> (errors: [String], warnings: [String]) {
        let report = report(for: proto)
        return (report.errors, report.warnings)
    }

    // MARK: - 模板

    /// Studio 的起点模板（**协议体** JSON 文本，不含 adapter 包装——Studio
    /// 里 name/hosts 是独立表单字段）。选择器是显眼的占位符：校验会提示，
    /// 测试会返回 0 条；用户/Agent 按真实页面替换后再保存。
    static func templateProtocolJSON(channelSlug: String = "") -> String {
        prettyJSON(templateBody(channelSlug: channelSlug))
    }

    /// Studio 的完整适配包模板（adapter-1 JSON 文本；CLI/文档/测试用）。
    static func templateAdapterJSON(host: String, platform: String) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseName = suggestedName(host: cleanHost, platform: platform)
        let channelSlug = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let adapter: [String: Any] = [
            "format": "desire/adapter-1",
            "name": baseName,
            "hosts": cleanHost.isEmpty ? ["REPLACE_ME_HOST"] : [cleanHost],
            "pathPrefixes": [],
            "notes": "ops adapter template — replace placeholder selectors, then test and save (saved disabled).",
            "protocolBody": templateBody(channelSlug: channelSlug),
        ]
        return prettyJSON(adapter)
    }

    static func templateBody(channelSlug: String = "") -> [String: Any] {
        [
            "protocolVersion": "desire/1",
            "profile": profileName,
            "pageType": "ops",
            "views": [
                "opsMetrics": [
                    "item": "REPLACE_ME_METRIC_ROW",
                    "fields": [
                        "views": "REPLACE_ME_VIEWS",
                        "likes": "REPLACE_ME_LIKES",
                        "comments": "REPLACE_ME_COMMENTS",
                    ],
                ],
                "opsComments": [
                    "item": "REPLACE_ME_COMMENT_ITEM",
                    "fields": [
                        "author": "REPLACE_ME_AUTHOR",
                        "text": "REPLACE_ME_TEXT",
                        "url": "REPLACE_ME_PERMALINK",
                    ],
                ],
                "opsComposer": [
                    "item": "REPLACE_ME_COMPOSER",
                    "fields": [
                        "title": "REPLACE_ME_TITLE_INPUT",
                        "body": "REPLACE_ME_BODY_INPUT",
                        "submit": "REPLACE_ME_SUBMIT",
                    ],
                ],
            ],
            "actions": [
                [
                    "name": "opsCompose",
                    "description": "Fill the composer only; never submits. The user presses Publish.",
                    "params": [
                        "title": ["type": "string", "required": true],
                        "body": ["type": "string", "required": true],
                    ],
                    "run": "[{\"fill\":{\"REPLACE_ME_TITLE_INPUT\":\"{title}\"}},{\"fill\":{\"REPLACE_ME_BODY_INPUT\":\"{body}\"}}]",
                    "effects": "local",
                ],
                [
                    "name": "opsPublish",
                    "description": "Submit the composer after explicit human approval.",
                    "run": "[{\"click\":\"REPLACE_ME_SUBMIT\"}]",
                    "effects": "persist",
                    "danger": true,
                ],
                [
                    "name": "opsReply",
                    "description": "Fill a reply; the user sends it.",
                    "params": ["text": ["type": "string", "required": true]],
                    "run": "[{\"fill\":{\"REPLACE_ME_REPLY_INPUT\":\"{text}\"}}]",
                    "effects": "outbound",
                    "danger": true,
                ],
            ],
            "signals": [
                "opsReady": "REPLACE_ME_READY",
                "opsLoginRequired": "REPLACE_ME_LOGIN",
                "opsBusy": "REPLACE_ME_BUSY",
            ],
            "context": [
                "channelSlug": channelSlug,
                "note": "ops/1 contract. Fill and submit are separate; publish/reply always require approval.",
            ],
        ]
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func suggestedName(host: String, platform: String) -> String {
        let base = host.isEmpty ? platform : host
        let trimmed = base
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "m.", with: "")
        let pieces = trimmed.split(separator: ".")
        let core = pieces.count >= 2 ? String(pieces[pieces.count - 2]) : trimmed
        let cleaned = core.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (name.isEmpty ? "site" : name) + "-ops"
    }

    private static func isPlaceholder(_ selector: String) -> Bool {
        let upper = selector.uppercased()
        return upper.contains("REPLACE_ME") || upper.contains("REPLACE-WITH") || upper.contains("TODO")
    }
}
