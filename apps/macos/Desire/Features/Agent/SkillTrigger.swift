import Foundation

/// **重复指令直通技能**的纯逻辑（v0.8.76 批 3，Foundation-only 进 tests/run.sh）。
///
/// 背景：同一条指令被反复下达（真实轨迹里"下载页面全部视频"一天说了 8 遍），
/// 而每一次模型都像第一次一样从头摸索——技能只在提示词里留了个名字和一句
/// 描述，要不要 `useSkill` 全凭模型自觉，跨会话又没有任何"这句话上次是怎么
/// 做的"的记录。
///
/// 做法：记下"每次加载某个技能时用户说的是什么"；用户消息与某个技能的触发
/// 样本相符、且**恰好只有一个技能**相符时，开局直接把该技能正文装进上下文，
/// 形状与模型自己调用 `useSkill` 完全一致。
///
/// 匹配刻意保守：只认归一化后相等、或较长一方完整包含较短一方。**不做模糊
/// 相似**——误加载一个用不上的技能会把整段正文塞进上下文，比不直通更糟。
nonisolated enum SkillTrigger {

    /// 一条触发样本：一句话，以及它触发过多少次。
    ///
    /// 计数按"这句话说过几遍"算，不是"有几条不同的话"——真实用法恰恰是同一句
    /// 原话反复说（去重后只剩一条样本，按条数计永远到不了门槛）。
    struct Sample: Codable, Equatable, Sendable {
        var text: String
        var count: Int
    }

    /// 首版收窄：这句话至少触发过这么多次才启用直通。
    static let minCount = 2
    /// 太短的指令不做包含匹配（"打开"之类到处都是）。
    static let minPhrase = 4
    /// 每个技能保留的不同样本条数上限（最近的在前）。
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
        let samples: [Sample]
    }

    struct Hit: Equatable, Sendable {
        let skill: String
        /// 命中的那句话此前触发过多少次（展示"之前 N 次"用）。
        let sampleCount: Int
        let sample: String
    }

    /// 从候选里选出应直通的技能。只看触发次数达到 `minCount` 的样本；必须
    /// **恰好一个**技能命中——没有命中、或多个技能都命中，都返回 nil（保持现状）。
    static func resolve(input: String, candidates: [Candidate],
                        minCount: Int = minCount) -> Hit? {
        // **歧义样本不参与判定**：一个回合同时加载了多个技能时，那条用户消息
        // 会被记给每一个技能。若只按"恰好一个技能命中"把关，样本不足的技能会
        // 悄悄退出判定，剩下那个就把这句话当成自己的——说"整理书签"却被装上
        // 视频下载技能。同一条话只要被记给多个技能，谁都不许用它。
        var owners: [String: Set<String>] = [:]
        for candidate in candidates {
            for sample in candidate.samples {
                owners[normalize(sample.text), default: []].insert(candidate.skill)
            }
        }
        let ambiguous = Set(owners.filter { $0.value.count > 1 }.map(\.key))

        var hits: [(candidate: Candidate, sample: Sample)] = []
        for candidate in candidates {
            guard let sample = candidate.samples.first(where: {
                $0.count >= minCount
                    && !ambiguous.contains(normalize($0.text))
                    && matches(input: input, sample: $0.text)
            }) else { continue }
            hits.append((candidate, sample))
        }
        guard hits.count == 1, let only = hits.first else { return nil }
        return Hit(skill: only.candidate.skill,
                   sampleCount: only.sample.count,
                   sample: only.sample.text)
    }

    /// 值不值得作为样本：空、过短、slash 命令、过长的粘贴都不算。
    static func isEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minPhrase, trimmed.count <= maxSampleLength,
              !trimmed.hasPrefix("/") else { return false }
        return true
    }

    /// 记一次触发：同一句话再来一次 → 计数加一并移到最前；新话 → 新样本。
    /// 超出条数上限时丢最久没说的。
    static func upsert(_ triggers: [Sample]?, adding text: String,
                       cap: Int = sampleCap) -> [Sample] {
        guard isEligible(text) else { return triggers ?? [] }
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(incoming)
        var kept = triggers ?? []
        if let index = kept.firstIndex(where: { normalize($0.text) == key }) {
            var again = kept.remove(at: index)
            again.count += 1
            kept.insert(again, at: 0)
        } else {
            kept.insert(Sample(text: incoming, count: 1), at: 0)
        }
        return Array(kept.prefix(cap))
    }

    /// 历史回填：从"用户消息 → 该回合加载过的技能"的序列，聚合出每个技能的
    /// 触发样本。序列按时间顺序给出；逐条累加计数。
    static func backfill(turns: [(user: String, skills: [String])]) -> [String: [Sample]] {
        var out: [String: [Sample]] = [:]
        for turn in turns where isEligible(turn.user) {
            for skill in turn.skills {
                out[skill] = upsert(out[skill], adding: turn.user)
            }
        }
        return out
    }

    /// 使用中学到的样本 + frontmatter 手写的短语。手写是用户的明确声明，视为
    /// 已满足触发次数门槛。
    static func merge(learned: [Sample]?, handwritten: [String]?,
                      cap: Int = sampleCap) -> [Sample] {
        var out = learned ?? []
        for phrase in handwritten ?? [] {
            let key = normalize(phrase)
            guard !key.isEmpty, !out.contains(where: { normalize($0.text) == key }) else { continue }
            out.append(Sample(text: phrase, count: minCount))
        }
        return Array(out.prefix(cap))
    }

    /// 回填结果并入已学到的样本：同一句话计数相加，新的补在后面。
    static func merge(learned: [Sample]?, backfilled: [Sample]?,
                      cap: Int = sampleCap) -> [Sample] {
        var out = learned ?? []
        for sample in backfilled ?? [] {
            let key = normalize(sample.text)
            guard !key.isEmpty else { continue }
            if let index = out.firstIndex(where: { normalize($0.text) == key }) {
                out[index].count += sample.count
            } else {
                out.append(sample)
            }
        }
        return Array(out.prefix(cap))
    }
}
