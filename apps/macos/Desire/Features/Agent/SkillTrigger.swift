import Foundation

/// **重复指令直通技能**的纯逻辑（v0.8.76 批 3，Foundation-only 进 tests/run.sh）。
///
/// 背景：同一条指令被反复下达（真实轨迹里"下载页面全部视频"一天说了 8 遍），
/// 而每一次模型都像第一次一样从头摸索——技能只在提示词里留了个名字和一句
/// 描述，要不要 `useSkill` 全凭模型自觉，跨会话又没有任何"这句话上次是怎么
/// 做的"的记录。
///
/// 做法：记下"每次加载某个技能时，用户说的是什么"（触发样本）；用户消息与
/// 某个技能的样本相符且**恰好只有一个技能**相符时，开局直接把该技能正文装进
/// 上下文，形状与模型自己调用 `useSkill` 完全一致。
///
/// 匹配刻意保守：只认归一化后相等、或较长一方完整包含较短一方。**不做模糊
/// 相似**——误加载一个用不上的技能会把整段正文塞进上下文，比不直通更糟。
nonisolated enum SkillTrigger {

    /// 首版收窄：同一指令配同一技能至少出现过这么多次才启用直通。
    static let minSamples = 2
    /// 太短的指令不做包含匹配（"打开"之类到处都是）。
    static let minPhrase = 4
    /// 每个技能保留的触发样本上限（最近的在前）。
    static let sampleCap = 20
    /// 样本最长字符数——过长的粘贴不是"一句可重复的指令"。
    static let maxSampleLength = 120

    /// 归一化（与记忆去重同口径）：小写、去空白与常见标点。
    static func normalize(_ text: String) -> String {
        MemoryModels.normalizeFact(text)
    }

    /// 输入是否命中一个触发样本。
    static func matches(input: String, sample: String, minPhrase: Int = minPhrase) -> Bool {
        let lhs = normalize(input)
        let rhs = normalize(sample)
        if lhs.isEmpty || rhs.isEmpty { return false }
        if lhs == rhs { return true }
        if rhs.count >= minPhrase, lhs.contains(rhs) { return true }
        if lhs.count >= minPhrase, rhs.contains(lhs) { return true }
        return false
    }

    struct Candidate: Equatable, Sendable {
        let skill: String
        /// 触发样本：使用中学到的 + frontmatter 里手写的。
        let samples: [String]
    }

    struct Hit: Equatable, Sendable {
        let skill: String
        /// 该技能的样本总数（展示"之前 N 次"用）。
        let sampleCount: Int
        /// 命中的那条样本。
        let sample: String
    }

    /// 从候选里选出应直通的技能。只看样本数达到 `minSamples` 的技能；必须
    /// **恰好一个**技能命中——没有命中、或多个技能都命中，都返回 nil（保持现状）。
    static func resolve(input: String, candidates: [Candidate],
                        minSamples: Int = minSamples) -> Hit? {
        // **歧义样本不参与判定**：一个回合同时加载了多个技能时，那条用户消息
        // 会被记给每一个技能。若只按"恰好一个技能命中"把关，样本不足的技能会
        // 悄悄退出判定，剩下那个就把这句话当成自己的——说"整理书签"却被装上
        // 视频下载技能。同一条话只要被记给多个技能，谁都不许用它。
        var owners: [String: Set<String>] = [:]
        for candidate in candidates {
            for sample in candidate.samples {
                owners[normalize(sample), default: []].insert(candidate.skill)
            }
        }
        let ambiguous = Set(owners.filter { $0.value.count > 1 }.map(\.key))

        var hits: [(candidate: Candidate, sample: String)] = []
        for candidate in candidates {
            let samples = candidate.samples.filter { !ambiguous.contains(normalize($0)) }
            guard samples.count >= minSamples,
                  let sample = samples.first(where: { matches(input: input, sample: $0) })
            else { continue }
            hits.append((candidate, sample))
        }
        guard hits.count == 1, let only = hits.first else { return nil }
        return Hit(skill: only.candidate.skill,
                   sampleCount: only.candidate.samples.filter { !ambiguous.contains(normalize($0)) }.count,
                   sample: only.sample)
    }

    /// 值不值得作为样本：空、过短、slash 命令、过长的粘贴都不算。
    static func isEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minPhrase, trimmed.count <= maxSampleLength,
              !trimmed.hasPrefix("/") else { return false }
        return true
    }

    /// 把一条新的触发样本并入：按归一化去重，最近的排最前，超出上限丢最旧。
    static func upsert(_ triggers: [String]?, adding text: String,
                       cap: Int = sampleCap) -> [String] {
        guard isEligible(text) else { return triggers ?? [] }
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(incoming)
        var kept = (triggers ?? []).filter { normalize($0) != key }
        kept.insert(incoming, at: 0)
        return Array(kept.prefix(cap))
    }

    /// 历史回填：从"用户消息 → 该回合加载过的技能"的序列，聚合出每个技能的
    /// 触发样本。序列按时间顺序给出；最旧的先入，最近的排在最前。
    /// 让已有的使用记录立即可用——否则要等同一条指令再被说两次才开始直通。
    static func backfill(turns: [(user: String, skills: [String])]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for turn in turns where isEligible(turn.user) {
            for skill in turn.skills {
                out[skill] = upsert(out[skill], adding: turn.user)
            }
        }
        return out
    }

    /// 两个样本集合合并（回填结果并入已学到的）：已学到的在前，补上回填里
    /// 没有的，仍按归一化去重与上限截断。
    static func merge(learned: [String]?, backfilled: [String]?,
                      cap: Int = sampleCap) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for text in (learned ?? []) + (backfilled ?? []) {
            let key = normalize(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(text)
            if out.count >= cap { break }
        }
        return out
    }
}
