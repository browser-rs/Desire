import Foundation
import NaturalLanguage

// 0.7.1 阶段一探针：居中化 NLE 混合检索的扩大对照评审（2026-10-07）。
// 背景：tools/vector-spike（20 句/4 查询）结论 = NLE 直接做检索不可行，
// 但 BM25 唯一失手恰是零词法重叠的纯改写 → ROADMAP 阶段一规则 =
// 「BM25 为主打分；零词法重叠的查询改用居中化 NLE 向量排序兜底」。
// 本探针把对照集扩到 30 条记忆池形态事实 + 15 条查询来验收该规则。
// **结论（2026-10-07 实测）：不达标**——混合 8/15 == 纯 BM25 8/15，
// 居中化 NLE 在零重叠子集 top-1 0/6（期望事实排位 5–30 名），不进产品。
// 数据与分析见 docs/VECTOR-MEMORY-SPIKE.md「阶段一扩大对照」一节。
// 编译（仓库根执行；BM25 与真实产品同码 = harness 源）：
//   swiftc -O -o /tmp/hybrid-spike/hybrid tools/vector-spike/hybrid-probe.swift \
//     apps/macos/Desire/Features/Agent/Memory/MemoryModels.swift \
//     apps/macos/Desire/Features/Agent/Memory/MemoryRetrieval.swift

// ---------- 事实池：30 条，记忆池真实分布（窄域：用户想让 Agent/浏览器怎么干活） ----------
let factDefs: [(String, String)] = [
    ("回答要简洁直接不要啰嗦", "preference"),        // F1
    ("下载画质优先选择最高清晰度", "preference"),    // F2
    ("下载失败时应该自动重试", "correction"),        // F3
    ("用户经常批量下载视频文件", "habit"),           // F4
    ("用户偏好用中文回答问题", "preference"),        // F5
    ("界面喜欢深色主题", "preference"),              // F6
    ("书签需要按文件夹分类整理", "habit"),           // F7
    ("每周清理一次浏览历史", "habit"),               // F8
    ("标签页不要自动刷新", "preference"),            // F9
    ("关闭窗口前要提醒保存会话", "preference"),      // F10
    ("下载完成后发系统通知", "preference"),          // F11
    ("视频广告必须自动拦截", "preference"),          // F12
    ("弹窗一律阻止不要询问", "preference"),          // F13
    ("搜索引擎保持默认不要改", "preference"),        // F14
    ("新标签页打开空白页", "preference"),            // F15
    ("阅读列表的文章要定期看完", "habit"),           // F16
    ("截图统一保存到桌面文件夹", "habit"),           // F17
    ("快捷键保持默认不要自定义", "preference"),      // F18
    ("密码自动填充保持开启", "preference"),          // F19
    ("无痕模式下的下载不进历史", "fact"),            // F20
    ("长回答分段输出", "preference"),                // F21
    ("代码块要标注语言", "preference"),              // F22
    ("工具执行前先说明意图", "preference"),          // F23
    ("失败的工具不要连续重试超过三次", "correction"),// F24
    ("用户时区是东八区", "fact"),                    // F25
    ("邮件类通知一律忽略", "preference"),            // F26
    ("会话标题自动生成就好", "preference"),          // F27
    ("记忆条目保持精简不要囤积", "preference"),      // F28
    ("翻译目标语言是英文", "preference"),            // F29
    ("用户习惯清晨处理长任务", "habit"),             // F30
]

// 查询（当前对话片段）→ 期望命中的事实下标。前 8 条设计为有词法重叠
//（BM25 应命中），后 7 条设计为零词法重叠的纯改写（NLE 兜底的目标场景）；
// 探针按真实 tokenize 结果分类，不以设计意图为准。
let queries: [(String, Int)] = [
    ("下载失败要怎么处理", 2),            // Q1 → F3
    ("高清画质在哪设置", 1),              // Q2 → F2
    ("广告拦截在哪里开关", 11),           // Q3 → F12
    ("截图默认存到哪里", 16),             // Q4 → F17
    ("翻译功能设置成什么语言", 28),       // Q5 → F29
    ("弹窗拦截要不要开", 12),             // Q6 → F13
    ("浏览历史多久清理一次", 7),          // Q7 → F8
    ("密码填充开关在哪", 18),             // Q8 → F19
    ("回复风格简短一点", 0),              // Q9 → F1（零重叠改写）
    ("他希望回复用什么语言", 4),          // Q10 → F5（零重叠；F29 是词法陷阱）
    ("片子都是好几部一起存", 3),          // Q11 → F4（零重叠）
    ("屏幕太亮看着难受", 5),              // Q12 → F6（零重叠）
    ("动手以前讲一下你准备干什么", 22),   // Q13 → F23（零重叠）
    ("内容多的话切几条消息发", 20),       // Q14 → F21（零重叠）
    ("一大早跑耗时活儿", 29),             // Q15 → F30（零重叠）
]

// updatedAt 以"天数前"错开（固定基准日，可复现）：零重叠查询的期望事实
// 全部排在最旧一档——纯 BM25 的"最近优先"兜底在这些查询上必然落空，
// 这样对比才公平（不给 recency 白送命中）。
let daysAgo: [Double] = [
    40, 2, 35, 38, 41, 36, 1, 33, 3, 30, 2, 28, 26, 4, 24,
    5, 22, 6, 20, 7, 34, 8, 32, 9, 18, 10, 16, 11, 14, 37,
]

let baseDate = Date(timeIntervalSince1970: 1_760_000_000) // 固定基准日，可复现
var facts: [MemoryFact] = factDefs.enumerated().map { index, def in
    var f = MemoryFact(content: def.0, category: def.1)
    f.updatedAt = baseDate.addingTimeInterval(-daysAgo[index] * 86400)
    return f
}
let idToIndex: [UUID: Int] = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($1.id, $0) })

// ---------- BM25（真实产品码 MemoryRetrieval.rank，topK = 全池以看完整排序） ----------
func bm25Ranking(_ query: String) -> [Int] {
    MemoryRetrieval.rank(facts: facts, query: query, params: .init(topK: facts.count))
        .compactMap { idToIndex[$0.id] }
}

// 词法重叠判定：与 rank 内部 hits 条件同口径（query 词元 ∩ 任一文档词元）。
func hasLexicalOverlap(_ query: String) -> Bool {
    let queryTokens = Set(MemoryRetrieval.tokenize(query))
    return facts.contains { fact in
        !queryTokens.isDisjoint(with: MemoryRetrieval.tokenize(fact.content + " " + fact.category))
    }
}

// ---------- 居中化 NLE（部署形态：均值只按事实池算，查询用同一均值居中） ----------
guard let nle = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else {
    print("FATAL: 无 zh-Hans 句向量资产"); exit(1)
}
func vec(_ s: String) -> [Double]? { nle.vector(for: s)?.map { Double($0) } }
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
}
var poolMean = [Double](repeating: 0, count: nle.dimension)
var factVecs: [[Double]] = []
for fact in facts {
    guard let v = vec(fact.content) else { print("FATAL: 事实向量缺失「\(fact.content)」"); exit(1) }
    factVecs.append(v)
    for i in 0..<nle.dimension { poolMean[i] += v[i] / Double(facts.count) }
}
func centered(_ v: [Double]) -> [Double] { zip(v, poolMean).map { $0 - $1 } }
func nleRanking(_ query: String) -> (order: [Int], topSim: Double) {
    guard let raw = vec(query) else { print("FATAL: 查询向量缺失「\(query)」"); exit(1) }
    let qv = centered(raw)
    let sims = factVecs.map { cosine(qv, centered($0)) }
    let order = sims.indices.sorted { sims[$0] > sims[$1] }
    return (order, sims[order[0]])
}

// ---------- 三路对比 ----------
print("== 0.7.1 阶段一：混合检索扩大对照（\(facts.count) 事实 × \(queries.count) 查询，NLE \(nle.dimension) 维居中化）==\n")
var bm25Top1 = 0, bm25Top3 = 0
var nleTop1 = 0, nleTop3 = 0
var hybTop1 = 0, hybTop3 = 0
var noLexCount = 0
var noLexBM25 = 0, noLexNLE = 0, noLexHyb = 0

for (qi, (query, expect)) in queries.enumerated() {
    let bm25 = bm25Ranking(query)
    let nle = nleRanking(query)
    let lexical = hasLexicalOverlap(query)
    let hybrid = lexical ? bm25 : nle.order

    let bRank = (bm25.firstIndex(of: expect) ?? -1) + 1
    let nRank = (nle.order.firstIndex(of: expect) ?? -1) + 1
    let hRank = (hybrid.firstIndex(of: expect) ?? -1) + 1

    if bRank == 1 { bm25Top1 += 1 }
    if bRank <= 3 { bm25Top3 += 1 }
    if nRank == 1 { nleTop1 += 1 }
    if nRank <= 3 { nleTop3 += 1 }
    if hRank == 1 { hybTop1 += 1 }
    if hRank <= 3 { hybTop3 += 1 }

    var subset = ""
    if !lexical {
        noLexCount += 1
        if bRank == 1 { noLexBM25 += 1 }
        if nRank == 1 { noLexNLE += 1 }
        if hRank == 1 { noLexHyb += 1 }
        subset = " 零重叠"
    }
    let tag = hRank == 1 ? "✓" : "✗"
    print(String(format: "Q%-2d[%@]%@ 「%@」→ 期望F%-2d | BM25 第%-2d NLE 第%-2d(%0.3f) 混合 第%-2d %@",
                 qi + 1, lexical ? "词法" : "改写", subset, query, expect + 1, bRank, nRank, nle.topSim, hRank, tag))
}

print("\n---- 汇总（top-1 / top-3，共 \(queries.count) 查询）----")
print("纯 BM25：      top1 \(bm25Top1)/\(queries.count)  top3 \(bm25Top3)/\(queries.count)")
print("居中化 NLE：   top1 \(nleTop1)/\(queries.count)  top3 \(nleTop3)/\(queries.count)")
print("混合规则：     top1 \(hybTop1)/\(queries.count)  top3 \(hybTop3)/\(queries.count)")
print("\n---- 零词法重叠子集（\(noLexCount) 条，混合规则唯一改判处）----")
print("BM25（退化为最近优先）：top1 \(noLexBM25)/\(noLexCount)")
print("居中化 NLE 兜底：        top1 \(noLexNLE)/\(noLexCount)")
print("混合规则：               top1 \(noLexHyb)/\(noLexCount)")

let verdict: String
if hybTop1 > bm25Top1 {
    verdict = "混合(\(hybTop1)) > 纯 BM25(\(bm25Top1)) —— 达标，可进产品（实现时 semanticOrder 走闭包注入，MemoryRetrieval 保持 Foundation-only）"
} else if hybTop1 == bm25Top1 {
    verdict = "混合(\(hybTop1)) == 纯 BM25(\(bm25Top1)) —— 无增益，不值得为 NLE 兜底加复杂度；记入 docs，转向阶段二决策"
} else {
    verdict = "混合(\(hybTop1)) < 纯 BM25(\(bm25Top1)) —— 不应发生（重叠处两路相同），检查分类口径"
}
print("\n验收：\(verdict)")
