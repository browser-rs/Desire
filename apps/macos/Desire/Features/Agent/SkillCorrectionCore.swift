import Foundation

/// **纠正回写技能**的纯逻辑半边（v0.8.76 批 4，Foundation-only 进 tests/run.sh）：
/// 用户纠正了上一轮按某技能执行的做法 → 给该技能一个**定点补丁**，落候选收件箱
/// 等用户确认。旁路调用在 AgentSessionStore（收尾路径），落地在 SkillCandidateStore。
///
/// 与 0.8.73 教训并存、分工不同：教训是"别这样做"的一条记忆（跨技能的泛化）；
/// 补丁改的是技能本体——用户原话："你自己写的技能 你自己修改对啊"。
///
/// 三条纪律：
/// 1. **识别是确定性的**（中英模式表 + 短消息），不靠模型判断"这句是不是纠正"；
/// 2. **补丁只能定点**：`find` 必须在技能文件里逐字存在且唯一、不动 frontmatter、
///    不超过全文的一半——定位不到就丢弃，绝不让旁路"重写整份技能"；
/// 3. **落地只走确认**：这里没有任何写盘，采纳在收件箱（旧版另存备份）。
nonisolated enum SkillCorrectionCore {

    // MARK: - 纠正识别

    /// 纠正消息的长度上限（字符）。纠正都是短句；长消息多半是新任务里顺带一句
    /// 说明，不值得为它烧一次旁路。
    static let maxCorrectionLength = 300

    /// 中文纠正形态。`(?<!对)不对` 把"对不对？"这类确认问句排除在外，
    /// `(?<!是)不是这样` 同理排除"是不是这样"。
    static let chinesePatterns: [String] = [
        #"(?<![对])不对"#,
        #"(?<![是])不是(这样|这个|这么|我要的|我说的|我让你)"#,
        #"你应该|你需要先|你要先|你本该|你得先"#,
        #"为什么(要|总|又|还|反复|不|老)"#, #"为啥(不|要|总|又|还|先|老)"#,
        #"自作主张"#,
        #"你自己(改|修改|修)"#, #"你自己写的"#,
        #"错了|搞错|弄错|犯错|理解错|改错"#,
        #"别再|不要再|不许再|不应再"#,
        #"反反复复|反复(看|查|读|试|执行)"#,
        #"谁让你|谁叫你"#,
        #"我说的是|我要的是|我的意思是|我说过|我刚才说|我不是说了"#,
        #"不会.{1,16}吗"#,
        #"明明(有|是|说|让|叫)"#,
        #"太多次"#,
        #"(之前|刚才|上次).{0,8}(做|跑|执行|处理|弄|下载).{0,4}过"#,
        #"重新(来|做|写|执行)|重来"#,
        #"愚蠢"#,
        #"到底在干什么|在干什么啊|你干了什么"#,
    ]

    /// 英文纠正形态（小写匹配）。
    static let englishPatterns: [String] = [
        #"that'?s (wrong|incorrect|not (what|right|it))"#,
        #"\bnot what i (said|asked|meant|wanted|requested)\b"#,
        #"\byou should\b|\byou need to\b|\byou (were|are|'re) supposed\b|\byou're wrong\b|\byou are wrong\b"#,
        #"\bwhy (do|did) you\b|\bwhy are you\b|\bwhy (do|does) (you|it) keep\b"#,
        #"\bstop (doing|polling|checking|repeatedly|it)\b"#,
        #"\bdon'?t (do|keep|just|repeat)\b"#,
        #"\bi said\b|\bi asked (for|you to)\b|\bwhat i meant\b|\bi didn'?t ask\b"#,
        #"\bincorrect\b"#,
        #"\byou keep\b|\bover and over\b|\brepeatedly\b|\bagain and again\b"#,
    ]

    /// `wrong` 单独成词时才算纠正，且排除"哪里出问题了"这类排障问句。
    static let wrongPattern = #"\bwrong\b"#
    static let wrongExclusions: [String] = [
        #"\bwhat('?s| is| was|'d) wrong\b"#, #"\banything wrong\b"#, #"\bsomething wrong\b"#,
        #"\bwrong with\b"#, #"\bgoes wrong\b"#, #"\bwent wrong\b"#, #"\bif (anything goes )?wrong\b"#,
    ]

    /// 这条用户消息是不是在纠正上一步的做法。
    static func isCorrection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCorrectionLength else { return false }
        if hit(chinesePatterns, trimmed) { return true }
        let lower = trimmed.lowercased()
        if hit(englishPatterns, lower) { return true }
        return hit([wrongPattern], lower) && !hit(wrongExclusions, lower)
    }

    /// 正则每次现编译现用，range 只在同一行文本上现算现用（不缓存）。
    private static func hit(_ patterns: [String], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    // MARK: - 被纠正的技能

    /// 纠正对应的技能与它前后的执行片段。
    struct Context {
        var skill: String
        /// 技能加载之后、纠正之前的消息（被纠正的那段执行）。
        var before: [AgentMessage]
        /// 从纠正那条消息开始到结尾（纠正之后的过程——改对了的话，它就是补丁的依据）。
        var after: [AgentMessage]
    }

    /// 从这条纠正往前找最近一次 `useSkill`（只看近处 `window` 条——被压缩归档的
    /// 轮次已不在 `messages` 里，判为"没加载过"即可）。直通技能（v0.8.76 批 3）
    /// 合成的调用对与模型自己调用的形状一致，这里一并认。
    static func context(in messages: [AgentMessage], correction: String,
                        window: Int = 60) -> Context? {
        guard let opener = messages.lastIndex(where: { $0.role == .user && $0.content == correction }),
              opener > 0 else { return nil }
        let floor = max(0, opener - window)
        var index = opener - 1
        while index >= floor {
            let message = messages[index]
            if message.role == .assistant, let calls = message.toolCalls {
                for call in calls.reversed() where call.function.name == "useSkill" {
                    if let name = skillName(inArguments: call.function.arguments) {
                        return Context(skill: name,
                                       before: Array(messages[(index + 1)..<opener]),
                                       after: Array(messages[opener...]))
                    }
                }
            }
            index -= 1
        }
        return nil
    }

    /// 从 useSkill 的调用参数里取技能名（解析失败返回 nil）。
    static func skillName(inArguments arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    // MARK: - 补丁输入

    static let skillCharLimit = 6_000
    static let executionCharLimit = 3_500
    static let correctionCharLimit = 1_000
    static let stepArgumentPreview = 160
    static let stepResultPreview = 220
    static let answerPreview = 200

    /// 一段执行过程的摘要：每步工具调用 = 签名 → 结果开头。技能正文本身不重复带
    /// （输入里已经给了全文），system 备注不带。
    static func executionDigest(from messages: [AgentMessage]) -> String {
        var lines: [String] = []
        var pending: [String: String] = [:]
        for message in messages {
            if message.role == .assistant, let calls = message.toolCalls {
                for call in calls {
                    pending[call.id] = call.function.name + " " + call.function.arguments.prefix(stepArgumentPreview)
                }
            }
            if message.role == .tool {
                guard message.toolName != "useSkill" else { continue }
                let signature = pending[message.toolCallId ?? ""] ?? (message.toolName ?? "?")
                let result = (message.content ?? "")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                lines.append("• " + signature + " → " + result.prefix(stepResultPreview))
            }
            if message.role == .assistant, let text = message.content, !text.isEmpty {
                lines.append("答：" + text.replacingOccurrences(of: "\n", with: " ").prefix(answerPreview))
            }
        }
        var joined = lines.joined(separator: "\n")
        if joined.count > executionCharLimit { joined = String(joined.prefix(executionCharLimit)) + "\n…（已截断）" }
        return joined
    }

    /// 旁路补丁生成的用户侧输入。
    static func promptInput(skillText: String, correction: String,
                            before: [AgentMessage], after: [AgentMessage]) -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit)) + "\n…（已截断）" : text
        }
        return """
        【技能文件】（find 必须是其中逐字存在且唯一的一段）
        \(clip(skillText, skillCharLimit))

        【按该技能执行的过程（被纠正的那一段）】
        \(executionDigest(from: before))

        【用户的纠正（原话）】
        \(clip(correction, correctionCharLimit))

        【纠正之后的过程】
        \(executionDigest(from: after))
        """
    }

    // MARK: - 补丁

    /// 定点补丁：`find` 是技能原文里**逐字存在且唯一**的一段，`replace` 是改后的
    /// 文字（可以是空串 = 删掉这一段），`reason` 一句话说清改的是什么。
    struct Patch: Codable, Equatable, Sendable {
        var find: String
        var replace: String
        var reason: String
    }

    static let minNeedleLength = 2
    /// `find` 最多占全文的比例——超过即视为重写。
    static let maxNeedleShare = 0.5
    static let maxNeedleLength = 1_200
    static let maxReplacementLength = 1_200
    static let maxReasonLength = 300

    /// 解析旁路输出：容忍代码围栏与前后引导语；`find` 为空 = 模型认为纠正与技能
    /// 无关（或定位不到），返回 nil。超长的 `find` 视为"重写全文"予以拒绝。
    static func parsePatch(_ output: String) -> Patch? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = String(text.dropFirst(3))
            if text.hasPrefix("json") { text = String(text.dropFirst(4)) }
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Patch.self, from: data) else { return nil }
        let find = normalizeNeedle(decoded.find)
        var reason = decoded.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.count > maxReasonLength { reason = String(reason.prefix(maxReasonLength)) + "…" }
        guard !find.isEmpty, find.count <= maxNeedleLength, !reason.isEmpty else { return nil }
        let replace = normalizeReplacement(decoded.replace)
        guard replace.count <= maxReplacementLength else { return nil }
        return Patch(find: find, replace: replace, reason: reason)
    }

    static func normalizeNeedle(_ needle: String) -> String {
        needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeReplacement(_ replacement: String) -> String {
        replacement.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 补丁能不能用。
    enum Verdict: Equatable, Sendable {
        case ok
        case emptyNeedle
        case notFound
        case ambiguous(count: Int)
        case tooShort
        case unchanged
        case oversized
        case frontmatter
    }

    /// 最多数到几个命中（只用于区分"唯一"与"不唯一"）。
    static let maxHits = 5

    static func validate(_ patch: Patch, against text: String) -> Verdict {
        let needle = normalizeNeedle(patch.find)
        guard !needle.isEmpty else { return .emptyNeedle }
        // 单个字符的替换看不出改的是哪一处（卡片上的"改前"也无法辨认）。
        guard needle.count >= minNeedleLength else { return .tooShort }
        if fingerprint(patch.replace) == fingerprint(needle) { return .unchanged }
        // 一半以上的替换就不是"定点"了。
        if Double(needle.count) > Double(max(text.count, 1)) * maxNeedleShare { return .oversized }
        let hits = locate(needle, in: text)
        if hits.isEmpty { return .notFound }
        if hits.count > 1 { return .ambiguous(count: hits.count) }
        // name/description 是技能的身份与索引，补丁不碰。
        if let bodyStart = frontmatterEnd(text), hits[0].lowerBound < bodyStart { return .frontmatter }
        return .ok
    }

    /// 应用补丁；任何校验不过都返回 nil（调用方不得绕过）。
    static func apply(_ patch: Patch, to text: String) -> String? {
        guard case .ok = validate(patch, against: text),
              let range = locate(patch.find, in: text).first else { return nil }
        return String(text[..<range.lowerBound]) + normalizeReplacement(patch.replace)
            + String(text[range.upperBound...])
    }

    /// 文件 frontmatter 的结束位置（没有 frontmatter = nil）。与 SkillStore.parse
    /// 同一条规则：以 `---` 开头、到下一个 `\n---` 为止。
    static func frontmatterEnd(_ text: String) -> String.Index? {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---") else { return nil }
        return end.upperBound
    }

    // MARK: - 定位

    /// 空白折叠后的文本：连续空白（含换行）算一个空格；`origins[i]` = 第 i 个字符在
    /// 原文 `Array(text)` 里的下标。折叠空格的 origin 指向它**之后**的第一个非空白
    /// 字符——于是命中的首尾天然落在非空白字符上。
    private struct Collapsed: Equatable {
        var chars: [Character]
        var origins: [Int]
    }

    private static func collapse(_ text: String) -> Collapsed {
        var chars: [Character] = []
        var origins: [Int] = []
        var pendingSpace = false
        for (index, char) in text.enumerated() {
            if char.isWhitespace {
                if !origins.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace {
                    chars.append(" ")
                    origins.append(index)
                    pendingSpace = false
                }
                chars.append(char)
                origins.append(index)
            }
        }
        return Collapsed(chars: chars, origins: origins)
    }

    /// 只比内容不比位置的归一化形态（"改了没有"与查重都用它——`Collapsed` 的
    /// origins 是位置信息，两段相同文字起点不同就不相等）。
    static func fingerprint(_ text: String) -> String {
        String(collapse(text).chars)
    }

    /// `needle` 在 `text` 里的全部命中（最多 `maxHits` 个，按原文的 Range 给出）。
    /// 匹配忽略空白差异——模型抄原文时常把缩进/换行/引号周围的空白重排，逐字匹配
    /// 会白丢；非空白字符必须完全一致。
    static func locate(_ rawNeedle: String, in text: String) -> [Range<String.Index>] {
        let haystack = collapse(text)
        let needle = collapse(normalizeNeedle(rawNeedle))
        guard !needle.chars.isEmpty, needle.chars.count <= haystack.chars.count else { return [] }
        var out: [Range<String.Index>] = []
        var start = 0
        while out.count < maxHits, start + needle.chars.count <= haystack.chars.count {
            var same = true
            for offset in 0..<needle.chars.count
            where haystack.chars[start + offset] != needle.chars[offset] {
                same = false
                break
            }
            guard same else {
                start += 1
                continue
            }
            // 末尾若是折叠空格（其 origin 指向下一个非空白字符），退到最后一个非空白。
            var last = start + needle.chars.count - 1
            while last > start, haystack.chars[last] == " " { last -= 1 }
            let firstOrigin = haystack.origins[start]
            let lower = text.index(text.startIndex, offsetBy: firstOrigin)
            let upper = text.index(lower, offsetBy: haystack.origins[last] + 1 - firstOrigin)
            out.append(lower..<upper)
            start += 1
        }
        return out
    }

    // MARK: - 节流与查重

    /// 一次补丁生成的记账（**调用旁路前**记——烧的是那一次调用，不是落卡的那次）。
    struct Attempt: Codable, Equatable {
        var skill: String
        var conversationId: UUID?
        var at: Date
    }

    /// 用户连续纠正时（真实轨迹里一口气五六句），每句都烧一次旁路没有意义：
    /// 同一（技能, 会话）10 分钟内只生成一次；全局每天最多 `maxPerDay` 次。
    static func patchBudgetPasses(_ attempts: [Attempt], skill: String, conversationId: UUID?,
                                  now: Date, cooldown: TimeInterval = 600, maxPerDay: Int = 3,
                                  window: TimeInterval = 24 * 3_600) -> Bool {
        let windowStart = now.addingTimeInterval(-window)
        let recent = attempts.filter { $0.at >= windowStart }
        guard recent.count < maxPerDay else { return false }
        let cooldownStart = now.addingTimeInterval(-cooldown)
        return !recent.contains {
            $0.skill.caseInsensitiveCompare(skill) == .orderedSame
                && $0.conversationId == conversationId && $0.at >= cooldownStart
        }
    }

    /// 收件箱里已有同一技能、同一处的待确认补丁 → 重复。
    static func isRedundantPatch(skill: String, find: String, pending: [SkillCandidateCore.Candidate]) -> Bool {
        let needle = fingerprint(find)
        return pending.contains { candidate in
            guard let patch = candidate.patch,
                  candidate.name.caseInsensitiveCompare(skill) == .orderedSame else { return false }
            return fingerprint(patch.find) == needle
        }
    }
}
