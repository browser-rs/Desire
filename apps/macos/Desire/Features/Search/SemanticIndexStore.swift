import Combine
import Foundation
import os

/// 语义索引的**编排层**（v0.8.22）：快照各数据源 → 后台嵌入/落盘 → 发布
/// 状态；对外提供检索与配置。纯逻辑（切分/近邻/增量）在
/// `SemanticIndexCore`，向量化在 `SemanticEmbedder`，分片 IO 在
/// `SemanticIndexStorage`——这里只做调度与状态。
///
/// 三条硬规矩：
/// 1. **绝不在主线程嵌入/写盘**：几千条 × 每条几毫秒会把 UI 拖死。
/// 2. **变更驱动 + 长防抖**（120s）：摘录/书签/高亮/会话的 `objectWillChange`
///    只标脏，到点合并一次增量构建（内容哈希未变的条目不重嵌）。
/// 3. **模型换了必须全量重嵌**：manifest 里记 model，旧分片的模型标识不匹配
///    时丢弃旧向量（跨模型余弦没有意义）。
@MainActor
final class SemanticIndexStore: ObservableObject {
    static let shared = SemanticIndexStore()

    struct Hit: Sendable, Equatable {
        var id: String
        var source: SemanticSource
        var title: String
        var subtitle: String
        var snippet: String
        var score: Float
        var language: SemanticLanguage
    }

    private struct Snapshot: Sendable {
        var source: SemanticSource
        var items: [SemanticItem]
    }

    private struct BuildOutcome: Sendable {
        var shards: [SemanticIndexStorage.Shard]
        var failedEmbeds: Int
        var saveError: String?
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isBuilding = false
    @Published private(set) var status: [SemanticSourceStatus] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastBuildAt: Date?
    @Published private(set) var lastBuildReason: String?

    private static let enabledKey = "semantic.index.enabled"
    private static let sourcesKey = "semantic.index.sources"
    /// 默认只索引用户**自己沉淀**的内容；会话消息默认关（隐私敏感）。
    /// 历史正文另外受 `history.contentIndex.enabled` 自己的开关约束。
    private static let defaultSources: [SemanticSource] = [.history, .bookmark, .excerpt, .highlight]

    private let defaults = UserDefaults.standard
    private var enabledSourceKeys: Set<String>
    private var cache: [String: SemanticIndexStorage.Shard] = [:]
    private var observers: [AnyCancellable] = []
    private var dirtySources: Set<SemanticSource> = []
    private var debounceTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var started = false

    private init() {
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if let raw = defaults.array(forKey: Self.sourcesKey) as? [String] {
            enabledSourceKeys = Set(raw)
        } else {
            enabledSourceKeys = Set(Self.defaultSources.map(\.rawValue))
            defaults.set(Array(enabledSourceKeys), forKey: Self.sourcesKey)
        }
    }

    // MARK: - 生命周期

    /// AppState.init 末尾调用：加载已有分片、观察数据源、错峰构建。
    func start() {
        guard !started else { return }
        started = true
        Task { await loadCache() }
        observeChanges()
        if isEnabled { scheduleLaunchBuild(delay: 30) }
    }

    private func scheduleLaunchBuild(delay: TimeInterval) {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            await self.build(sources: nil, reason: "launch")
        }
    }

    private func loadCache() async {
        let loaded = await Task.detached(priority: .utility) {
            () -> [String: SemanticIndexStorage.Shard] in
            var out: [String: SemanticIndexStorage.Shard] = [:]
            for source in SemanticSource.allCases {
                for language in SemanticLanguage.allCases {
                    if let shard = SemanticIndexStorage.load(source: source, language: language) {
                        out[Self.key(source, language)] = shard
                    }
                }
            }
            return out
        }.value
        cache = loaded
        refreshStatus()
    }

    // MARK: - 配置

    var enabledSources: [SemanticSource] {
        SemanticSource.allCases.filter { isSourceEnabled($0) }
    }

    func isSourceEnabled(_ source: SemanticSource) -> Bool {
        enabledSourceKeys.contains(source.rawValue)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            scheduleLaunchBuild(delay: 1)
        } else {
            debounceTask?.cancel()
            launchTask?.cancel()
            dirtySources.removeAll()
        }
    }

    func setSourceEnabled(_ source: SemanticSource, enabled: Bool) {
        guard enabled != isSourceEnabled(source) else { return }
        if enabled {
            enabledSourceKeys.insert(source.rawValue)
        } else {
            enabledSourceKeys.remove(source.rawValue)
        }
        defaults.set(Array(enabledSourceKeys), forKey: Self.sourcesKey)
        if enabled {
            rebuild(source: source)
        } else {
            clear(source: source)
        }
    }

    // MARK: - 构建

    func rebuild(source: SemanticSource? = nil) {
        guard isEnabled else { return }
        let targets = source.map { [$0] } ?? enabledSources
        Task { await build(sources: targets, reason: source == nil ? "all" : "manual") }
    }

    private func build(sources: [SemanticSource]?, reason: String) async {
        guard isEnabled else { return }
        if isBuilding {
            // 构建中来的请求不能丢：合并回脏集合，结束后再跑。
            for source in sources ?? enabledSources { dirtySources.insert(source) }
            scheduleDebounce()
            return
        }
        let targets = (sources ?? enabledSources).filter { isSourceEnabled($0) }
        guard !targets.isEmpty else { return }
        isBuilding = true
        lastError = nil
        lastBuildReason = reason
        defer { isBuilding = false }

        var snapshots: [Snapshot] = []
        for source in targets {
            snapshots.append(Snapshot(source: source,
                                      items: SemanticIndexSources.items(for: source)))
        }

        let outcome = await Task.detached(priority: .utility) {
            Self.embedAndSave(snapshots: snapshots)
        }.value

        for shard in outcome.shards {
            cache[Self.key(shard.manifest.source, shard.manifest.language)] = shard
        }
        refreshStatus()
        lastBuildAt = Date()
        if let saveError = outcome.saveError {
            lastError = saveError
        } else if outcome.failedEmbeds > 0 {
            lastError = "\(outcome.failedEmbeds) item(s) failed to embed"
        } else {
            lastError = nil
        }
        let sourceList = targets.map(\.rawValue).joined(separator: ",")
        let itemTotal = status.reduce(0) { $0 + $1.itemCount }
        Log.app.info("semantic index built — sources \(sourceList, privacy: .public) items \(itemTotal, privacy: .public) reason \(reason, privacy: .public)")
    }

    /// 后台线程执行：嵌入 + 落盘（纯静态，不碰 store）。
    private nonisolated static func embedAndSave(snapshots: [Snapshot]) -> BuildOutcome {
        var shards: [SemanticIndexStorage.Shard] = []
        var failedEmbeds = 0
        var saveError: String?

        for snapshot in snapshots {
            let groups = Dictionary(grouping: snapshot.items, by: \.language)
            for language in SemanticLanguage.allCases {
                let items = groups[language] ?? []
                let previous = SemanticIndexStorage.load(source: snapshot.source, language: language)
                // 模型换了旧向量作废（跨模型余弦没有意义）。
                let reusable = previous?.manifest.model == language.modelKey ? (previous?.vectors ?? []) : []
                let plan = SemanticIncremental.plan(previous: reusable, items: items)

                var records: [SemanticVectorRecord] = []
                records.reserveCapacity(items.count)
                var dimension = 0
                for item in items {
                    if let vector = plan.reuse[item.id] {
                        if dimension == 0 { dimension = vector.count }
                        if vector.count == dimension {
                            records.append(SemanticVectorRecord(id: item.id,
                                                                contentHash: item.contentHash,
                                                                vector: vector))
                        } else {
                            failedEmbeds += 1
                        }
                        continue
                    }
                    guard let output = SemanticEmbedder.embed(
                        SemanticText.embedInput(title: item.title, body: item.body),
                        language: language) else {
                        failedEmbeds += 1
                        continue
                    }
                    if dimension == 0 { dimension = output.dimension }
                    guard output.dimension == dimension else {
                        failedEmbeds += 1
                        continue
                    }
                    records.append(SemanticVectorRecord(id: item.id,
                                                        contentHash: item.contentHash,
                                                        vector: output.vector))
                }

                let keptIDs = Set(records.map(\.id))
                let keptItems = items.filter { keptIDs.contains($0.id) }
                let manifest = SemanticShardManifest(
                    version: SemanticShardManifest.currentVersion,
                    source: snapshot.source,
                    language: language,
                    model: language.modelKey,
                    dimension: dimension,
                    itemCount: keptItems.count,
                    builtAt: Date(),
                    fingerprint: SemanticFingerprint.of(keptItems))
                let shard = SemanticIndexStorage.Shard(manifest: manifest,
                                                       items: keptItems,
                                                       vectors: records)
                do {
                    try SemanticIndexStorage.save(shard)
                    shards.append(shard)
                } catch {
                    saveError = "save failed: \(error)"
                }
            }
        }
        return BuildOutcome(shards: shards, failedEmbeds: failedEmbeds, saveError: saveError)
    }

    // MARK: - 清理

    func clear(source: SemanticSource? = nil) {
        if let source {
            SemanticIndexStorage.remove(source: source)
            for language in SemanticLanguage.allCases {
                cache.removeValue(forKey: Self.key(source, language))
            }
        } else {
            SemanticIndexStorage.removeAll()
            cache.removeAll()
        }
        refreshStatus()
        lastBuildAt = nil
        lastError = nil
    }

    // MARK: - 检索

    /// 语义检索（同语言分片内）；查询太短、模型不可用、索引为空都返回空，
    /// 调用方自行回退字面检索。
    func search(query: String, limit: Int = 20,
                source: SemanticSource? = nil,
                minScoreOverride: Float? = nil) -> [Hit] {
        guard isEnabled, SemanticQueryPlan.isSemanticWorthy(query) else { return [] }
        let language = SemanticQueryPlan.primaryLanguage(for: query)
        guard let queryVector = SemanticEmbedder.embedQuery(query, language: language) else { return [] }
        return rank(queryVector: queryVector, language: language, limit: limit,
                    source: source, minScore: minScoreOverride)
    }

    /// UI 专用：查询嵌入放后台（bge ~4ms、NL 首次可能更久），排序仍在主线程
    ///（几千条向量的余弦 <1ms）。防抖由调用方负责。
    func searchAsync(query: String, limit: Int = 20,
                     source: SemanticSource? = nil) async -> [Hit] {
        guard isEnabled, SemanticQueryPlan.isSemanticWorthy(query) else { return [] }
        let language = SemanticQueryPlan.primaryLanguage(for: query)
        let embedded = await Task.detached(priority: .userInitiated) {
            SemanticEmbedder.embedQuery(query, language: language)
        }.value
        guard let queryVector = embedded else { return [] }
        return rank(queryVector: queryVector, language: language, limit: limit,
                    source: source, minScore: nil)
    }

    private func rank(queryVector: SemanticEmbedder.Output,
                      language: SemanticLanguage,
                      limit: Int,
                      source: SemanticSource?,
                      minScore: Float?) -> [Hit] {
        var records: [SemanticVectorRecord] = []
        var items: [String: SemanticItem] = [:]
        for shard in cache.values {
            guard shard.manifest.language == language,
                  shard.manifest.dimension == queryVector.dimension,
                  isSourceEnabled(shard.manifest.source),
                  source == nil || shard.manifest.source == source else { continue }
            records.append(contentsOf: shard.vectors)
            for item in shard.items { items[item.id] = item }
        }

        let ranked = SemanticRanking.topK(
            query: queryVector.vector,
            records: records,
            limit: max(1, limit),
            minScore: minScore ?? SemanticEmbedder.minScore(for: language))
        return ranked.compactMap { hit in
            guard let item = items[hit.record.id] else { return nil }
            return Hit(id: item.id,
                       source: item.source,
                       title: item.title,
                       subtitle: item.subtitle,
                       snippet: SemanticText.snippet(item.body),
                       score: hit.score,
                       language: item.language)
        }
    }

    // MARK: - 变更驱动

    private func observeChanges() {
        guard observers.isEmpty else { return }
        ExcerptStore.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.noteDirty(.excerpt) }
            }
            .store(in: &observers)
        ReaderHighlightStore.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.noteDirty(.highlight) }
            }
            .store(in: &observers)
        HistoryContentStore.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.noteDirty(.history) }
            }
            .store(in: &observers)
        if let app = AppState.live {
            app.bookmarkStore.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in self?.noteDirty(.bookmark) }
                }
                .store(in: &observers)
            app.conversationStore.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in self?.noteDirty(.conversation) }
                }
                .store(in: &observers)
        }
    }

    private func noteDirty(_ source: SemanticSource) {
        guard isEnabled, isSourceEnabled(source) else { return }
        dirtySources.insert(source)
        scheduleDebounce()
        // Spotlight 走同一批变更信号（5 分钟防抖，别跟着每次击键重建）。
        SpotlightIndexer.schedule(after: 300)
    }

    /// 合并 120 秒内的所有变更后再构建；构建中触发会在结束后补跑。
    private func scheduleDebounce() {
        guard isEnabled, !dirtySources.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            let targets = self.dirtySources
            self.dirtySources.removeAll()
            guard !targets.isEmpty else { return }
            await self.build(sources: Array(targets), reason: "changes")
        }
    }

    // MARK: - 状态

    private func refreshStatus() {
        var shards: [SemanticSourceStatus] = []
        for shard in cache.values where shard.manifest.itemCount > 0 {
            shards.append(SemanticSourceStatus(
                source: shard.manifest.source,
                language: shard.manifest.language,
                itemCount: shard.manifest.itemCount,
                vectorCount: shard.vectors.count,
                bytes: SemanticIndexStorage.bytes(source: shard.manifest.source,
                                                  language: shard.manifest.language),
                builtAt: shard.manifest.builtAt,
                model: shard.manifest.model))
        }
        status = SemanticStatusMath.aggregate(shards)
            .sorted { order($0.source) < order($1.source) }
    }

    private func order(_ source: SemanticSource) -> Int {
        SemanticSource.allCases.firstIndex(of: source) ?? 0
    }

    private nonisolated static func key(_ source: SemanticSource, _ language: SemanticLanguage) -> String {
        "\(source.rawValue)|\(language.rawValue)"
    }

    /// 桥端点 `GET /index/status` 的载荷（也是设置页的同一份真相）。
    func statusPayload() -> [String: Any] {
        [
            "enabled": isEnabled,
            "building": isBuilding,
            "lastBuildAt": lastBuildAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
            "lastError": lastError ?? "",
            "sources": SemanticSource.allCases.map { source -> [String: Any] in
                let entry = status.first { $0.source == source }
                return [
                    "source": source.rawValue,
                    "enabled": isSourceEnabled(source),
                    "items": entry?.itemCount ?? 0,
                    "vectors": entry?.vectorCount ?? 0,
                    "bytes": entry?.bytes ?? 0,
                    "builtAt": entry?.builtAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
                    "model": entry?.model ?? "",
                ]
            },
            "totalItems": status.reduce(0) { $0 + $1.itemCount },
            "totalBytes": status.reduce(0) { $0 + $1.bytes },
        ]
    }
}
