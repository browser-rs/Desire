import Foundation
import NaturalLanguage

/// 英文语义召回 spike（v0.8.22 批一的质量闸门）。
///
/// 目的：决定英文条目能否用系统 `NLEmbedding.sentenceEmbedding(for: .english)`
/// 做语义检索。中文侧已有 0.7.1 的验收集（bge-small-zh），英文侧没有——
/// 不能凭"系统 API 可用"就上线。
///
/// 语料是**构造的**：24 篇英文短文（技术/新闻/科学/生活各 6 篇）+ 12 条
/// 查询，一半是同义改写（与原文几乎无字面重叠），一半是普通主题查询；
/// 同时跑一个词重叠基线做对照。只看聚合指标，不落任何用户数据。
///
/// 判定：NL 的 recall@5 ≥ 0.75 且明显高于字面基线 → 英文走 NL；
/// 否则英文侧退回字面检索（功能仍可用，只是没有语义补位）。

struct Doc {
    let id: String
    let text: String
}

struct Query {
    let text: String
    let gold: String
    let kind: String   // "paraphrase" / "topic"
}

let docs: [Doc] = [
    Doc(id: "d01", text: "Apple released a new version of its desktop operating system with faster window animations and lower memory use."),
    Doc(id: "d02", text: "The central bank raised interest rates by a quarter point, citing persistent inflation in services."),
    Doc(id: "d03", text: "Researchers found that deep-sea corals grow far more slowly than previously estimated."),
    Doc(id: "d04", text: "A practical guide to kneading bread dough by hand, including resting times and hydration ratios."),
    Doc(id: "d05", text: "The new laptop ships with a brighter display, a larger battery, and a redesigned keyboard."),
    Doc(id: "d06", text: "City planners are converting parking lanes into protected bicycle corridors to reduce traffic deaths."),
    Doc(id: "d07", text: "A study links short bursts of vigorous exercise to improved cardiovascular health in older adults."),
    Doc(id: "d08", text: "The film festival announced its lineup, featuring debut directors from twelve countries."),
    Doc(id: "d09", text: "Database engineers explain how write-ahead logging keeps transactions durable after a crash."),
    Doc(id: "d10", text: "Wildfires in the region forced thousands of residents to evacuate over the weekend."),
    Doc(id: "d11", text: "A tutorial on writing your first compiler: lexing, parsing, and emitting simple assembly."),
    Doc(id: "d12", text: "Nutritionists debate whether artificial sweeteners help or hinder weight loss."),
    Doc(id: "d13", text: "The spacecraft transmitted images of the planet's rings from a distance of two million kilometers."),
    Doc(id: "d14", text: "Small businesses are adopting contactless payments faster than large retailers."),
    Doc(id: "d15", text: "A history of the typewriter and how its keyboard layout survived into modern computers."),
    Doc(id: "d16", text: "Engineers restored rail service after a landslide blocked the main line for three days."),
    Doc(id: "d17", text: "A beginner's introduction to growing tomatoes in containers on a small balcony."),
    Doc(id: "d18", text: "The museum will open a new wing dedicated to contemporary sculpture next spring."),
    Doc(id: "d19", text: "Security researchers disclosed a flaw in a widely used encryption library."),
    Doc(id: "d20", text: "Sleep scientists recommend keeping a consistent wake time even on weekends."),
    Doc(id: "d21", text: "The airline added direct flights between the two cities, cutting travel time by half."),
    Doc(id: "d22", text: "A profile of the volunteers who maintain open-source software in their spare time."),
    Doc(id: "d23", text: "Farmers are testing drought-resistant rice varieties in the delta region."),
    Doc(id: "d24", text: "The orchestra's new conductor plans to program more works by living composers."),
]

let queries: [Query] = [
    Query(text: "how to make a computer's interface feel smoother while using less RAM", gold: "d01", kind: "paraphrase"),
    Query(text: "why borrowing money became more expensive for households", gold: "d02", kind: "paraphrase"),
    Query(text: "slow growth of organisms living on the ocean floor", gold: "d03", kind: "paraphrase"),
    Query(text: "making bread at home with flour and water", gold: "d04", kind: "paraphrase"),
    Query(text: "a portable computer with a better screen and longer runtime", gold: "d05", kind: "paraphrase"),
    Query(text: "safe routes for cyclists instead of car parking", gold: "d06", kind: "paraphrase"),
    Query(text: "short intense workouts and heart health in seniors", gold: "d07", kind: "paraphrase"),
    Query(text: "Apple desktop operating system release", gold: "d01", kind: "topic"),
    Query(text: "interest rate increase inflation", gold: "d02", kind: "topic"),
    Query(text: "wildfire evacuation", gold: "d10", kind: "topic"),
    Query(text: "encryption vulnerability disclosure", gold: "d19", kind: "topic"),
    Query(text: "consistent sleep schedule advice", gold: "d20", kind: "topic"),
    Query(text: "keeping data safe when the power suddenly goes out", gold: "d09", kind: "paraphrase"),
    Query(text: "turning source code into machine instructions step by step", gold: "d11", kind: "paraphrase"),
    Query(text: "pictures of a distant planet's rings beamed back to Earth", gold: "d13", kind: "paraphrase"),
    Query(text: "paying by tapping a phone instead of swiping a card", gold: "d14", kind: "paraphrase"),
    Query(text: "railway reopened after a hillside collapsed onto the tracks", gold: "d16", kind: "paraphrase"),
    Query(text: "growing vegetables in pots on a small outdoor space", gold: "d17", kind: "paraphrase"),
    Query(text: "exhibition space for recent three-dimensional art", gold: "d18", kind: "paraphrase"),
    Query(text: "nonstop service between two airports", gold: "d21", kind: "paraphrase"),
    Query(text: "people who donate their free time to code projects", gold: "d22", kind: "paraphrase"),
    Query(text: "crops that survive with little water", gold: "d23", kind: "paraphrase"),
    Query(text: "a conductor who favors music written by people alive today", gold: "d24", kind: "paraphrase"),
]

func normalize(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count >= 3 }
}

let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "its", "their", "they", "have", "has", "are", "was", "were", "how", "why", "what", "when", "who", "not", "but", "more", "less", "than", "you", "your", "new"]

func tokens(_ text: String) -> Set<String> {
    Set(normalize(text).filter { !stop.contains($0) })
}

func literalScore(_ query: String, _ doc: String) -> Double {
    let q = tokens(query)
    let d = tokens(doc)
    guard !q.isEmpty, !d.isEmpty else { return 0 }
    let overlap = q.intersection(d).count
    return Double(overlap) / Double(q.count)
}

guard let embed = NLEmbedding.sentenceEmbedding(for: .english) else {
    print("NLEmbedding English unavailable — gate: FAIL (fallback to literal)")
    exit(2)
}

func vector(_ text: String) -> [Double]? { embed.vector(for: text) }

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
}

let docVectors: [(String, String, [Double])] = docs.compactMap { doc in
    guard let v = vector(doc.text) else { return nil }
    return (doc.id, doc.text, v)
}
guard docVectors.count == docs.count else {
    print("embedding failures: \(docs.count - docVectors.count)/\(docs.count) — gate: FAIL")
    exit(2)
}

func evaluate(_ scorer: (String, String, [Double]) -> Double, label: String) {
    var ranks: [Int] = []
    var kindHits: [String: (Int, Int)] = [:]
    for query in queries {
        let ranked = docVectors
            .map { (id: $0.0, score: scorer(query.text, $0.1, $0.2)) }
            .sorted { $0.score > $1.score }
        // 零分/低于阈值的视为"没给出"——否则全零并列时按文档顺序的巧合会被
        // 当成命中（曾把字面基线虚高到 4/7）。
        let index = ranked.firstIndex { $0.id == query.gold }
        let rank = (index != nil && ranked[index!].score > 0.15) ? index! + 1 : -1
        ranks.append(rank)
        var entry = kindHits[query.kind] ?? (0, 0)
        entry.1 += 1
        if rank == 1 { entry.0 += 1 }
        kindHits[query.kind] = entry
    }
    let r1 = Double(ranks.filter { $0 == 1 }.count) / Double(ranks.count)
    let r5 = Double(ranks.filter { $0 > 0 && $0 <= 5 }.count) / Double(ranks.count)
    let mrr = ranks.map { $0 > 0 ? 1.0 / Double($0) : 0 }.reduce(0, +) / Double(ranks.count)
    print(String(format: "%@ — recall@1 %.3f  recall@5 %.3f  MRR %.3f", label, r1, r5, mrr))
    for kind in ["paraphrase", "topic"] {
        if let (hit, total) = kindHits[kind] {
            print(String(format: "  %@: recall@1 %.3f (%d/%d)", kind, Double(hit)/Double(total), hit, total))
        }
    }
}

evaluate({ q, _, v in
    guard let qv = vector(q) else { return -1 }
    return cosine(qv, v)
}, label: "NL sentence embeddings")


// 阈值标定：gold 与非 gold 的分数分布（决定检索侧 minScore）
var goldScores: [Double] = []
var nonGoldScores: [Double] = []
for query in queries {
    guard let qv = vector(query.text) else { continue }
    for (id, text, v) in docVectors {
        let score = cosine(qv, v)
        if id == query.gold { goldScores.append(score) } else { nonGoldScores.append(score) }
    }
}
let goldAvg = goldScores.reduce(0, +) / Double(max(1, goldScores.count))
let goldMin = goldScores.min() ?? 0
let nonAvg = nonGoldScores.reduce(0, +) / Double(max(1, nonGoldScores.count))
let nonMax = nonGoldScores.max() ?? 0
print(String(format: "score distribution — gold avg %.3f min %.3f | non-gold avg %.3f max %.3f", goldAvg, goldMin, nonAvg, nonMax))
for threshold in [0.25, 0.3, 0.35, 0.4, 0.45, 0.5] {
    let tp = goldScores.filter { $0 >= threshold }.count
    let fp = nonGoldScores.filter { $0 >= threshold }.count
    print(String(format: "  threshold %.2f: gold kept %d/%d, non-gold leaked %d/%d",
                 threshold, tp, goldScores.count, fp, nonGoldScores.count))
}
evaluate({ q, text, _ in literalScore(q, text) }, label: "Literal word-overlap baseline")
