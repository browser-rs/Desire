import Foundation

/// 网页工作流（v0.7.29）：把用户在页面上的一串操作（点击/输入/选择/导航）
/// 存成可回放的步骤。**纯数据结构**（Foundation-only，进 harness）。
///
/// 选择器是**多候选**的：录制时尽量同时存 data-testid / id / name / aria-label /
/// 文本 / nth-child 路径，回放按顺序尝试——单靠 nth-child 的规则在页面改版后必坏。
nonisolated struct Workflow: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// 站点作用域（小写 host；回放/列表按它匹配子域）。
    var host: String
    /// 录制开始时的页面 URL（回放先导航到这里）。
    var startURL: String
    var createdAt: Date
    var updatedAt: Date
    var steps: [Step]

    struct Step: Codable, Identifiable, Equatable {
        var id: UUID
        var kind: Kind
        /// 有序候选选择器；`text:` 前缀表示按可见文本匹配（回放器解析）。
        var selectors: [String]
        /// input/select 的值；敏感字段恒为 nil（回放时由用户输入）。
        var value: String?
        /// navigate 的目标 URL。
        var url: String?
        /// 敏感字段（密码/卡号/验证码…）：值绝不落盘。
        var sensitive: Bool
        /// 人类可读说明（面板展示）。
        var note: String?

        enum Kind: String, Codable, CaseIterable {
            case navigate, click, input, select, key, waitFor
        }

        init(id: UUID = UUID(), kind: Kind, selectors: [String] = [],
             value: String? = nil, url: String? = nil,
             sensitive: Bool = false, note: String? = nil) {
            self.id = id
            self.kind = kind
            self.selectors = selectors
            self.value = value
            self.url = url
            self.sensitive = sensitive
            self.note = note
        }
    }

    init(id: UUID = UUID(), name: String, host: String, startURL: String,
         createdAt: Date = Date(), updatedAt: Date = Date(), steps: [Step]) {
        self.id = id
        self.name = name
        self.host = host
        self.startURL = startURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.steps = steps
    }
}

nonisolated enum WorkflowLogic {
    // MARK: - 站点

    static func host(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// 工作流是否适用于该 URL（同域或子域）。
    static func matchesSite(_ workflow: Workflow, url: String) -> Bool {
        guard let host = host(of: url), !workflow.host.isEmpty else { return false }
        let scope = workflow.host.lowercased()
        return host == scope || host.hasSuffix("." + scope)
    }

    // MARK: - 选择器

    /// 基本合法性：非空、长度有界、无控制字符；`text:` 候选要求有内容。
    static func isValidSelector(_ raw: String) -> Bool {
        let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, selector.count <= 500 else { return false }
        if selector.hasPrefix("text:") {
            return selector.dropFirst("text:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines).count >= 1
        }
        guard selector.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }

    static func isValid(_ step: Workflow.Step) -> Bool {
        switch step.kind {
        case .navigate:
            return step.url?.isEmpty == false
        case .click, .input, .select, .key, .waitFor:
            return step.selectors.contains(where: isValidSelector)
                || (step.kind == .key)
        }
    }

    // MARK: - 敏感字段

    /// 字段名/类型里出现这些片段就按敏感处理（宁严勿松：值不落盘）。
    static let sensitiveHints = [
        "pass", "card", "cvv", "cvc", "token", "secret", "otp",
        "one-time", "credit", "securitycode", "pin",
    ]

    static func isSensitiveField(type: String?, autocomplete: String?,
                                 name: String?, id: String?, placeholder: String?) -> Bool {
        if (type ?? "").lowercased() == "password" { return true }
        if (autocomplete ?? "").lowercased().hasPrefix("cc-") { return true }
        let hay = [name, id, placeholder]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return sensitiveHints.contains { hay.contains($0) }
    }

    /// 录制入库前的净化：敏感步骤标记 + 清空值。
    static func sanitized(_ step: Workflow.Step, sensitive: Bool) -> Workflow.Step {
        var copy = step
        copy.sensitive = sensitive
        if sensitive { copy.value = nil }
        return copy
    }

    // MARK: - 回放准备

    /// 敏感步骤里还没填值的（面板先收集，再允许运行）。
    static func missingSensitiveValues(_ workflow: Workflow,
                                       values: [UUID: String]) -> [UUID] {
        workflow.steps
            .filter { $0.sensitive && (values[$0.id] ?? "").isEmpty }
            .map(\.id)
    }

    /// 回放用的步骤（把用户本次输入的值填进敏感步骤；不写回工作流本身）。
    static func stepsForReplay(_ workflow: Workflow,
                               values: [UUID: String]) -> [Workflow.Step] {
        workflow.steps.map { step in
            var copy = step
            if copy.sensitive, let value = values[step.id], !value.isEmpty {
                copy.value = value
            }
            return copy
        }
    }
}
