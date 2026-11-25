import Foundation

/// **按任务精简工具定义**的纯逻辑半边（v0.8.76 批 5，Foundation-only 进 tests/run.sh）。
///
/// 背景：每个请求都全量发送 295 个工具的 JSON 定义（约 17 万字符），而真实工作流
/// 一条任务线全程只用到 18 个。0.8.74 否决过"工具动态子集"——理由是"模型只能
/// 调用已声明的工具，裁剪即阉割"，这条理由仍然成立。本批换一个设计：**渐进披露 +
/// 逃生口 + 自动回退**，不是硬裁剪。
///
/// - 只在"直通技能加载的回合"启用，且受设置开关控制（实验特性，默认关）；
/// - 工具集 = 技能声明的 `tools:` ∪ 正文点名的工具 ∪ 该技能历史执行实际用过的工具
///   ∪ 常驻工具 ∪ 浏览器基本功；推断不出的不硬塞；
/// - 其余工具仍在系统提示的索引里，模型知道它们存在，用 `useTools` 按需加载；
/// - 模型一旦调用未加载的工具，或 `useTools` 用到第二次，本回合余下请求恢复全量。
nonisolated enum ToolScopeCore {

    /// 常驻工具：不管加载了哪个技能都要在——加载更多工具、与用户沟通、做计划、
    /// 记忆、读转存的大结果、订阅与查看后台任务。
    static let residentTools: Set<String> = [
        "useSkill", "listSkills", "useTools", "askUser", "updatePlan", "notify",
        "remember", "recallMemory", "recallConversation", "getToolResult",
        "watchBackgroundTasks", "listBackgroundTasks", "backgroundTaskStatus", "cancelBackgroundTask",
    ]

    /// 浏览器基本功：读页面、点、填、滚、按键、执行脚本、导航、切标签。技能正文
    /// 很少点名它们，但浏览器智能体几乎每个任务都要用——不放进来的话第一个请求
    /// 就得退回全量，精简形同虚设。
    static let browserBasics: Set<String> = [
        "getPageSnapshot", "getPageLinks", "getPageText", "executeJS", "click", "fill",
        "scroll", "pressKey", "type", "navigate", "listTabs", "switchTab",
    ]

    /// 正文推断的最短工具名长度。只认**带大写字母的驼峰名**（`listDetectedMedia`）：
    /// click / fill / scroll 这类英文单词在正文里到处都是，算不准，也不需要——
    /// 它们本来就在基本功里。
    static let minBodyNameLength = 5

    /// 推断不出这么多个"技能特有"的工具就不精简（面太宽的技能裁了也是立刻回退）。
    static let minInferredTools = 5
    /// 工具集上限：超过说明技能本身就什么都可能用，不如不裁。
    static let maxTools = 48
    /// 历史执行里最多采纳的工具数（按次数取前 N）。
    static let maxHistoryTools = 24

    // MARK: - frontmatter 列表

    /// frontmatter 的列表键（`tools:` / `triggers:`）：逗号 / 顿号分隔的一行，或其后
    /// 以 `- ` 开头的列表行。没有 → 空数组。
    static func frontmatterList(_ key: String, frontmatter: String) -> [String] {
        var out: [String] = []
        var inList = false
        let prefix = key + ":"
        for rawLine in frontmatter.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(prefix) {
                inList = true
                out += line.dropFirst(prefix.count)
                    .split(whereSeparator: { ",，、".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else if inList, line.hasPrefix("- ") {
                out.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty {
                inList = false
            }
        }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - 工具集推断

    /// 某个技能对工具集的输入。
    struct Spec: Equatable, Sendable {
        /// frontmatter `tools:`；nil = 没声明（走推断）。
        var declared: [String]?
        /// 技能正文。
        var body: String
        /// 该技能历史执行里实际调用过的工具 → 次数。
        var history: [String: Int]
    }

    /// 这个技能该发完整定义的工具集；nil = 不值得精简。作者在 frontmatter 里写明了
    /// `tools:` 就以作者为准（哪怕只写了两个）；没写才从正文与历史推断。
    static func toolSet(for spec: Spec, knownTools: Set<String>,
                        resident: Set<String> = residentTools,
                        basics: Set<String> = browserBasics) -> Set<String>? {
        var specific: Set<String>
        if let declared = spec.declared {
            specific = Set(declared.filter { knownTools.contains($0) })
            guard !specific.isEmpty else { return nil }
        } else {
            specific = bodyMentions(spec.body, knownTools: knownTools)
                .union(topHistory(spec.history, knownTools: knownTools))
        }
        specific.subtract(resident)
        specific.subtract(basics)
        // "至少 5 个"只约束**推断出的特有工具**（常驻/基本功本来就在，不算数）——
        // 作者亲手写下的名单哪怕只有两个也算数。
        if spec.declared == nil {
            guard specific.count >= minInferredTools else { return nil }
        }
        var set = specific.union(resident).union(basics)
        set.formIntersection(knownTools)
        guard set.count <= maxTools else { return nil }
        return set
    }

    /// 正文里点名的工具（整词匹配、区分大小写）。
    static func bodyMentions(_ body: String, knownTools: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for name in knownTools.sorted() where isInferrable(name) && containsToken(name, in: body) {
            found.insert(name)
        }
        return found
    }

    static func isInferrable(_ name: String) -> Bool {
        name.count >= minBodyNameLength && name.contains { $0.isUppercase }
    }

    /// `token` 是否作为完整标识符出现在 `text` 里（前后不能是字母/数字/下划线）。
    /// range 现算现用，全程不改 `text`。
    static func containsToken(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9_])")
        else { return false }
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// 历史里用得最多的前 N 个（同次数按名字排序，保证结果稳定）。
    static func topHistory(_ history: [String: Int], knownTools: Set<String>,
                           limit: Int = maxHistoryTools) -> Set<String> {
        Set(history
            .filter { knownTools.contains($0.key) && $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key))
    }

    // MARK: - 回合内的范围状态

    /// 一个回合里的工具范围。`active == nil` = 发全量（开局就没精简，或已回退）。
    struct Scope: Equatable {
        /// 当前发完整定义的工具；nil = 全量。
        private(set) var active: Set<String>?
        /// 本回合可用的全部工具（含模式排除后的结果）。
        let available: Set<String>
        private(set) var useToolsCalls = 0
        /// 回退到全量的原因（日志/评估用）。
        private(set) var fallbackReason: String?

        /// `useTools` 用到第几次就回退全量——按需加载两次说明这个技能的工具集
        /// 推断得不准，再逐个加载只是在浪费请求。
        static let useToolsFallbackAfter = 2

        init(initial: Set<String>?, available: Set<String>) {
            self.available = available
            self.active = initial.map { $0.intersection(available) }
        }

        var isSlimmed: Bool { active != nil }

        func includes(_ name: String) -> Bool {
            active?.contains(name) ?? true
        }

        /// 模型调了未加载的工具 → 回退全量。
        mutating func noteUnloadedCall(_ name: String) {
            guard active != nil else { return }
            active = nil
            fallbackReason = "unloaded call: \(name)"
        }

        /// `useTools(names:)`：加入工具集；第 N 次起回退全量。
        struct LoadOutcome: Equatable {
            var loaded: [String] = []
            var unknown: [String] = []
            var fellBack = false
            /// 已经是全量了，没什么可加载。
            var alreadyFull = false
        }

        mutating func load(_ names: [String]) -> LoadOutcome {
            guard var current = active else {
                return LoadOutcome(alreadyFull: true)
            }
            useToolsCalls += 1
            var seen: Set<String> = []
            let wanted = names.filter { seen.insert($0).inserted }
            let valid = wanted.filter { available.contains($0) }
            let unknownNames = wanted.filter { !available.contains($0) }
            let added = valid.filter { !current.contains($0) }
            current.formUnion(valid)
            var outcome = LoadOutcome(loaded: added, unknown: unknownNames)
            if useToolsCalls >= Scope.useToolsFallbackAfter {
                active = nil
                fallbackReason = "useTools ×\(useToolsCalls)"
                outcome.fellBack = true
            } else {
                active = current
            }
            return outcome
        }
    }

    /// 从 useTools 的调用参数里取工具名：`{"names":[…]}`（容忍单个字符串）。
    /// 解析失败返回空数组——回执照常给，模型会看到"没有可加载的"。
    static func requestedNames(inArguments arguments: String) -> [String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let names = object["names"] as? [String] { return names }
        if let name = object["names"] as? String { return [name] }
        return []
    }

    // MARK: - 回执

    static let unloadedReceiptPrefix = "Error: tool '"

    /// 调了未加载的工具：按失败约定以 `Error: ` 开头（动作没有发生），并告诉模型
    /// 全量已恢复、下一请求直接再调即可——不必再绕道 `useTools`。
    static func unloadedReceipt(_ name: String) -> String {
        "Error: tool '\(name)' is not loaded in this request — only the tools for the active skill were sent. "
            + "The full tool set has been restored for the rest of this turn: call it again in your next response."
    }

    static func useToolsReceipt(_ outcome: Scope.LoadOutcome) -> String {
        if outcome.alreadyFull { return "All tools are already loaded in this request." }
        var parts: [String] = []
        parts.append(outcome.loaded.isEmpty
            ? "Those tools were already loaded."
            : "Loaded full definitions for: " + outcome.loaded.joined(separator: ", ") + ". Call them in your next response.")
        if !outcome.unknown.isEmpty {
            parts.append("Not found: " + outcome.unknown.joined(separator: ", ")
                + " — check exact names with listTools or the <tools> index.")
        }
        if outcome.fellBack {
            parts.append("This turn now sends the full tool set, so no further useTools calls are needed.")
        }
        return parts.joined(separator: " ")
    }

    /// 给系统提示 `<tools>` 层的说明：索引里"每个工具都可调用"在精简回合里不成立。
    static func promptNote(loaded: Int, total: Int) -> String {
        "SCOPED TOOLS: this request carries full definitions for \(loaded) of \(total) tools (the ones the active skill needs). "
            + "The index below still lists every tool, but a tool that is not loaded cannot be called yet — "
            + "if a step needs one, call useTools {names:[…]} first and then call it in your next response."
    }
}
