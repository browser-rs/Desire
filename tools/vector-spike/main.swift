import NaturalLanguage
import Foundation

// 向量记忆 spike（0.6.7 P1，2026-10-06）：验证 NLEmbedding zh-Hans 句向量
// 能否替代/增强 BM25 记忆检索。编译：
//   swiftc -O -o /tmp/vecspike tools/vector-spike/main.swift \
//     apps/macos/Desire/Features/Agent/Memory/MemoryModels.swift \
//     apps/macos/Desire/Features/Agent/Memory/MemoryRetrieval.swift
// 结论见 docs/VECTOR-MEMORY-SPIKE.md（当前判定：不可行，BM25 保留）。
// Apple 更新 NLEmbedding 资产后重跑本探针即可复测。

// ---------- 对照集（中性内容，20 句 = 8 事实 + 5 改写 + 4 查询 + 3 额外） ----------
let facts: [(String, String)] = [
    ("用户偏好用中文回答问题", "preference"),      // F1
    ("下载失败时应该自动重试", "correction"),      // F2
    ("用户经常批量下载视频文件", "habit"),         // F3
    ("回答要简洁直接不要啰嗦", "preference"),      // F4
    ("下载画质优先选择最高清晰度", "preference"),  // F5
    ("用户喜欢深色主题界面", "preference"),        // F6
    ("书签需要按文件夹分类整理", "habit"),         // F7
    ("每周清理一次浏览历史", "habit"),             // F8
]
// 改写对（语义同 ↔ 词面不同）：向量应高分
let paraphrase: [(String, String)] = [
    ("用户偏好用中文回答问题", "回复时应该使用中文"),
    ("下载失败时应该自动重试", "任务失败后自动重新尝试下载"),
    ("用户经常批量下载视频文件", "习惯一次性下载多个视频"),
    ("回答要简洁直接不要啰嗦", "说话风格应该简短直接"),
    ("下载画质优先选择最高清晰度", "优先下载最高画质的版本"),
]
// 无关对（跨主题）：向量应低分
let unrelated: [(String, String)] = [
    ("用户偏好用中文回答问题", "下载失败时应该自动重试"),
    ("回答要简洁直接不要啰嗦", "用户经常批量下载视频文件"),
    ("下载失败时应该自动重试", "用户喜欢深色主题界面"),
    ("用户经常批量下载视频文件", "书签需要按文件夹分类整理"),
    ("回答要简洁直接不要啰嗦", "下载画质优先选择最高清晰度"),
]
// 查询 → 期望命中的事实（真实用法：当前对话 → 检索记忆）
let queries: [(String, Int)] = [
    ("下载出错了怎么办", 1),          // → F2
    ("他希望回复用什么语言", 0),      // → F1
    ("界面配色喜好", 5),              // → F6
    ("想下载最好画质", 4),            // → F5
]

// ---------- NLEmbedding ----------
guard let nle = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else {
    print("FATAL: no zh-Hans sentence embedding"); exit(1)
}
func vec(_ s: String) -> [Double]? {
    nle.vector(for: s)?.map { Double($0) }
}
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count else { return 0 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
}
let cache: [String: [Double]] = {
    var c: [String: [Double]] = [:]
    for (f, _) in facts { c[f] = vec(f) }
    for (a, b) in paraphrase { c[a] = c[a] ?? vec(a); c[b] = vec(b) }
    for (a, b) in unrelated { c[a] = c[a] ?? vec(a); c[b] = vec(b) }
    for (q, _) in queries { c[q] = vec(q) }
    return c
}()

print("== NLE 句向量（zh-Hans, \(nle.dimension)-dim）==")
var rel: [Double] = []
for (i, (a, b)) in paraphrase.enumerated() {
    let s = cosine(cache[a]!, cache[b]!)
    rel.append(s)
    print("改写\(i+1): \(String(format: "%.4f", s))  「\(a)」↔「\(b)」")
}
var unr: [Double] = []
for (i, (a, b)) in unrelated.enumerated() {
    let s = cosine(cache[a]!, cache[b]!)
    unr.append(s)
    print("无关\(i+1): \(String(format: "%.4f", s))  「\(a)」↔「\(b)」")
}
let meanRel = rel.reduce(0,+) / Double(rel.count)
let meanUnr = unr.reduce(0,+) / Double(unr.count)
print(String(format: "改写均值 %.4f | 无关均值 %.4f | 间隔 %.4f", meanRel, meanUnr, meanRel - meanUnr))
let minRel = rel.min()!, maxUnr = unr.max()!
print(String(format: "最差改写 %.4f vs 最好无关 %.4f → 可分性: %@", minRel, maxUnr, minRel > maxUnr ? "完全可分 ✓" : "有重叠 ✗"))

print("\n== 查询 → 事实检索（8 事实池，期望第 1）==")
let factVecs = facts.map { cache[$0.0]! }
var nleTop1 = 0
for (q, expect) in queries {
    let qv = cache[q]!
    let sims = factVecs.map { cosine(qv, $0) }
    let best = sims.indices.max { sims[$0] < sims[$1] }!
    let ranked = sims.enumerated().sorted { $0.element > $1.element }
    let rank = ranked.first { $0.offset == expect }!.offset + 1
    if best == expect { nleTop1 += 1 }
    print(String(format: "「%@」→ 命中%@ (第%d) top1相似 %.4f", q, rank == 1 ? "✓" : "✗", rank, sims[expect]))
}

// ---------- BM25 基线（现有 MemoryRetrieval） ----------
print("\n== BM25 基线（同池同查询）==")
let memFacts = facts.map { MemoryFact(content: $0.0, category: $0.1) }
var bm25Top1 = 0
for (q, expect) in queries {
    let ranked = MemoryRetrieval.rank(facts: memFacts, query: q, params: .init(topK: 8))

    let pos = ranked.firstIndex { $0.id == memFacts[expect].id }!
    if pos == 0 { bm25Top1 += 1 }
    print("「\(q)」→ 期望事实排位 第\(pos+1) \(pos == 0 ? "✓" : "✗")")
}
print(String(format: "\n总结：查询 top1 命中 NLE %d/4 | BM25 %d/4；改写/无关间隔 %.4f", nleTop1, bm25Top1, meanRel - meanUnr))

// ---------- 各向异性补救：均值居中后再余弦 ----------
print("\n== 均值居中（去公共主方向）后再余弦 ==")
let allVecs = Array(cache.values)
var mean = [Double](repeating: 0, count: nle.dimension)
for v in allVecs { for i in 0..<nle.dimension { mean[i] += v[i] / Double(allVecs.count) } }
func centered(_ s: String) -> [Double] {
    let v = cache[s]!
    return zip(v, mean).map { $0 - $1 }
}
var crel: [Double] = []
for (a, b) in paraphrase { crel.append(cosine(centered(a), centered(b))) }
var cunr: [Double] = []
for (a, b) in unrelated { cunr.append(cosine(centered(a), centered(b))) }
let cMeanRel = crel.reduce(0,+) / Double(crel.count)
let cMeanUnr = cunr.reduce(0,+) / Double(cunr.count)
print(String(format: "改写均值 %.4f | 无关均值 %.4f | 间隔 %.4f", cMeanRel, cMeanUnr, cMeanRel - cMeanUnr))
print(String(format: "最差改写 %.4f vs 最好无关 %.4f → 可分性: %@", crel.min()!, cunr.max()!, crel.min()! > cunr.max()! ? "完全可分 ✓" : "有重叠 ✗"))
print("居中后逐对：改写 \(crel.map { String(format: "%.3f", $0) }.joined(separator: " ")) | 无关 \(cunr.map { String(format: "%.3f", $0) }.joined(separator: " "))")
var cTop1 = 0
for (q, expect) in queries {
    let qv = centered(q)
    let sims = facts.map { cosine(qv, centered($0.0)) }
    let ranked = sims.enumerated().sorted { $0.element > $1.element }
    let pos = ranked.first { $0.offset == expect }!.offset + 1
    if pos == 1 { cTop1 += 1 }
    print(String(format: "「%@」→ 第%d %@ top1 %.4f", q, pos, pos == 1 ? "✓" : "✗", ranked[0].element))
}
print("居中后查询 top1：\(cTop1)/4")
