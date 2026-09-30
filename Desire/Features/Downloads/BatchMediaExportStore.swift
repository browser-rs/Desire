import AppKit
import Combine
import Foundation
import os

/// 批量视频下载引擎（两种模式，见 `BatchMediaBatch.Mode`）：
///
/// - **page（喂食流）**：列表页本身就是播放器，候选即真实媒体地址
///   （嗅探 + DOM 扫描的合并结果）——规划后直接进下载队列。
/// - **list（逐页解析）**：候选是详情页地址——用 `HeadlessMediaResolver`
///   （隐藏 WebView，共享 Cookie 池）**严格串行**逐页解析出媒体地址再下载，
///   页面访问之间 2-5s 抖动（反爬节奏的一部分，不做并发解析提速）。
///
/// 2026-09-26 真实站点 12 部批量实测后的硬规矩：
/// 1. **解析节流**：下载占满并发槽时不再预解析下一页——签名 URL 是按需
///    签的，解析先行会把"快过期地址"压在队列里（实测 403 一批）。
/// 2. **失败自动重试（同批同文件夹）**：达到重试上限才终局失败。此前失败
///    靠模型手动开新批次，文件散落在两个不同名的批次文件夹和 Downloads
///    根三个地方（用户点名的问题）。
/// 3. **磁盘预留硬底线**：保存位置剩余空间低于 `BatchMediaPreferences.reserveGB`
///    （默认 5GB）时**挂起**整批（在跑的下载停掉、项回到 pending），提醒用户
///    （会话备注 + 系统通知 + 面板提问：换位置/取消/已清理空间继续），并在
///    空间恢复后**自动续跑**。预留不做"继续"绕过——防止写满磁盘是目的。
/// 4. **命名走偏好**：`clean`（默认，折叠站点模板重复段）/ `code`（番号
///    优先）/ `title`（原样），见 `BatchMediaPlan.NamingStyle`。
///
/// 下载并发由 `maxConcurrentDownloads` 闸门控制；单项下载复用
/// `MediaExportStore`（静默模式），批次完成/需要人工验证时才统一发会话
/// 备注 + 系统通知。
///
/// **Cloudflare**：非交互挑战自动放行；交互式验证先**自主通过**——把解析
/// 器 webview 弹成小窗后用 `SyntheticInput`（真实 NSEvent，与物理点击
/// 无异）点 Turnstile 复选框，三次不成才降级为等人工（验证窗留给用户，
/// 引擎继续轮询解除后自动续跑）。
@MainActor
final class BatchMediaExportStore: ObservableObject {
    static let shared = BatchMediaExportStore()

    @Published private(set) var batches: [BatchMediaBatch] = []

    private var engineTasks: [UUID: Task<Void, Never>] = [:]
    /// 槽位看门狗：单点卡死不该拖死整队（2026-09-30 用户实测）。
    private var watchdogTasks: [UUID: Task<Void, Never>] = [:]
    /// 引擎循环是否在跑（暂停/挂起会让循环退出；恢复时据此决定要不要重启）。
    private var engineRunning: Set<UUID> = []
    /// list 模式的解析器（每批一个；page 模式不需要）。
    private var resolvers: [UUID: HeadlessMediaResolver] = [:]
    private var batchUserAgents: [UUID: String] = [:]

    // MARK: 暂停 / 挂起

    /// 手动暂停（桥 / 工具触发）：不起新下载、解析停摆，在跑项收回到 pending。
    private var pausedBatches: Set<UUID> = []
    /// 磁盘预留触发的挂起：batchID → 原因。挂起期间行为同暂停，另有
    /// 空间监视任务在自动续跑。
    private var suspendedReasons: [UUID: String] = [:]
    private var spaceMonitorTasks: [UUID: Task<Void, Never>] = [:]
    /// 低空间提问去重（同一批次同时只挂一个提问）。
    private var diskAskInFlight: Set<UUID> = []
    /// 空间检查节流（进度回调很密，statfs 不必每次都打）。
    private var lastSpaceCheckAt: Date = .distantPast

    // MARK: 可观测性

    /// 逐项进度（itemID → done/total/单位）。**不进 @Published**——段级
    /// 回调很密，发布会让桥/UI 跟着抖；快照读取时现取。
    private var itemProgress: [UUID: (done: Int, total: Int, unit: MediaExporter.ProgressUnit)] = [:]
    /// 槽位看门狗依据：每个在跑项最近一次进度回调的时间。
    private var lastProgressAt: [UUID: Date] = [:]

    /// 同批下载并发上限（用户可在 config 里调 1-4）。
    private var maxConcurrentDownloads: Int { BatchMediaPreferences.maxConcurrent }
    /// 单项总尝试次数（1 次原始 + 2 次自动重试，每次重试都换新解析地址）。
    static let maxItemAttempts = 3
    /// 自动重试前的冷却（签名地址按需签 + 冷却，避免立刻再撞墙）。
    private let retryCooldownSeconds: TimeInterval = 15
    /// 批量上限（Agent 工具描述与桥文档同步声明）。
    static let maxItemsPerBatch = 100

    private init() {}

    // MARK: - 入口

    /// page 模式：候选 = 嗅探/DOM 扫描的合并结果（调用方负责采集，
    /// 见 `downloadAllPageVideos` 工具与桥 `POST /media/batch`）。
    @discardableResult
    func startPageBatch(
        candidates: [(url: String, kind: String, mime: String, isBlob: Bool)],
        referer: URL?,
        userAgent: String?,
        folderName: String?,
        naming: String? = nil,
        force: Bool = false,
        directory: String? = nil,
        splitEvery: Int? = nil
    ) -> BatchMediaBatch {
        BatchMediaPreferences.applyExplicitNaming(naming)
        let plan = BatchMediaPlan.planPageBatch(candidates: candidates)
        let total = plan.items.count
        let style = BatchMediaPreferences.namingStyle
        let items = plan.items.enumerated().map { index, entry -> BatchMediaItem in
            let number = BatchMediaPlan.numberedPrefix(index, total: total)
            return BatchMediaItem(
                id: UUID(),
                sourceURL: entry.url,
                mediaURL: entry.url,
                referer: referer,
                title: "\(number)-\(BatchMediaPlan.displayName(pageTitle: "", mediaURL: entry.url, style: style))",
                numberPrefix: number
            )
        }
        return enqueue(
            mode: .page,
            folderName: folderName,
            items: items,
            skipped: plan.skipped,
            userAgent: userAgent,
            force: force,
            directory: directory,
            splitEvery: splitEvery
        )
    }

    /// list 模式：逐页解析。`urls` = 详情页地址清单。
    @discardableResult
    func startListBatch(
        pageURLs: [String],
        userAgent: String?,
        folderName: String?,
        naming: String? = nil,
        force: Bool = false,
        directory: String? = nil,
        splitEvery: Int? = nil
    ) -> BatchMediaBatch {
        BatchMediaPreferences.applyExplicitNaming(naming)
        let plan = BatchMediaPlan.planListBatch(urls: pageURLs)
        let total = plan.items.count
        let items = plan.items.enumerated().map { index, entry -> BatchMediaItem in
            let number = BatchMediaPlan.numberedPrefix(index, total: total)
            return BatchMediaItem(
                id: UUID(),
                sourceURL: entry.url,
                mediaURL: nil,
                referer: nil,
                title: number,
                numberPrefix: number
            )
        }
        return enqueue(
            mode: .list,
            folderName: folderName,
            items: items,
            skipped: plan.skipped,
            userAgent: userAgent,
            force: force,
            directory: directory,
            splitEvery: splitEvery
        )
    }

    /// 入队 + 起引擎。超量截断进 skipped；空批次立即终局（checkBatchSettled）。
    private func enqueue(
        mode: BatchMediaBatch.Mode,
        folderName: String?,
        items: [BatchMediaItem],
        skipped: [BatchMediaPlan.SkippedEntry],
        userAgent: String?,
        force: Bool = false,
        directory: String? = nil,
        splitEvery: Int? = nil
    ) -> BatchMediaBatch {
        // 用户/模型可能把**绝对路径**当 folderName 传（"存到 /Volumes/x"）——
        // 直接消毒会把斜杠打成横杠、落在 Downloads 下的畸形文件夹。拆出
        // 目录部分作为本批 saveRoot，末段才是子文件夹名。
        // **组合语义**（用户实测三轮定案）：directory 与 folderName **可以组合**——
        //   · directory = 保存**父目录**（精确路径，展开 ~）；
        //   · folderName = 其下的子文件夹名；与 directory 同给 → 父/子组合
        //     （"/Volumes/sd" + "missav.ws" → /Volumes/sd/missav.ws，用户直觉）；
        //     不给 → 直接落在 directory（不硬造子文件夹）；
        //   · folderName 误传**绝对路径** = 等价 directory（整段直落）；
        //   · 都不给 → 默认下载根 + 时间戳文件夹；folder 点噪音（"." / ".."）= 无。
        // 目标目录随批持久化（restore 曾丢 saveRoot——恢复后回落默认 Downloads）。
        var saveRootOverride: String?
        if let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty, dir != "/" {
            saveRootOverride = NSString(string: dir).expandingTildeInPath
        }
        var folderInput = folderName ?? ""
        if let raw = folderInput.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
           raw.hasPrefix("/"), raw != "/" {
            // 绝对路径进 folderName = 整段就是目标目录（优先于 directory）
            saveRootOverride = NSString(string: raw).expandingTildeInPath
            folderInput = ""
        }
        let folderProbe = folderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderProbe.isEmpty || folderProbe == "." || folderProbe == ".." {
            folderInput = ""
        }
        let folder = BatchMediaPlan.sanitizedFileName(
            from: folderInput,
            fallback: saveRootOverride != nil ? "" : "Desire-Batch-" + Self.folderTimestamp()
        )
        var batchItems = items
        var overflow = skipped
        if batchItems.count > Self.maxItemsPerBatch {
            let dropped = batchItems.suffix(from: Self.maxItemsPerBatch)
            batchItems = Array(batchItems.prefix(Self.maxItemsPerBatch))
            overflow += dropped.map {
                BatchMediaPlan.SkippedEntry(url: $0.sourceURL.absoluteString, reason: "batch limit \(Self.maxItemsPerBatch)")
            }
        }
        let skippedItems = overflow.map { entry -> BatchMediaItem in
            BatchMediaItem(
                id: UUID(),
                sourceURL: URL(string: entry.url) ?? batchItems.first?.sourceURL ?? URL(string: "about:blank")!,
                mediaURL: nil,
                referer: nil,
                title: entry.url,
                numberPrefix: "",
                state: .skipped,
                summary: entry.reason
            )
        }
        let batch = BatchMediaBatch(
            id: UUID(),
            mode: mode,
            saveRoot: saveRootOverride,
            // 批未显式指定时回落用户默认（设置面板/引导里配置的）。
            splitEvery: ((splitEvery ?? 0) > 0 ? splitEvery : nil) ?? BatchMediaPreferences.splitEvery,
            folderName: folder,
            items: batchItems + skippedItems,
            state: .running,
            createdAt: Date()
        )
        batches.insert(batch, at: 0)
        batchUserAgents[batch.id] = userAgent
        if force { forceDownloadBatches.insert(batch.id) }
        persistUnfinished()
        startEngine(batch.id)
        return batch
    }

    /// `force: true` 的批次绕过已下载索引（强制重下）。
    private var forceDownloadBatches: Set<UUID> = []

    private static func folderTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 重试失败项（手动触发 / `retryBatchDownloads` 工具）：**复用原批次
    /// 与原文件夹**——不要让调用方另开批次（文件散落的根源）。list 模式
    /// 重新解析拿新签名 URL；page 模式直接重下。
    func retryFailed(_ batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .finished else { return }
        batches[bi].state = .running
        for ii in batches[bi].items.indices where batches[bi].items[ii].state == .failed {
            batches[bi].items[ii].state = .pending
            batches[bi].items[ii].summary = nil
            if batches[bi].mode == .list {
                batches[bi].items[ii].mediaURL = nil
            }
        }
        Log.downloads.info("batch retry-failed started (batch \(batchID.uuidString.prefix(8), privacy: .public))")
        persistUnfinished()
        startEngine(batchID)
    }

    /// **向既有批次追加任务**（排队中/已完成均可）：list 模式追加详情页、
    /// page 模式追加媒体地址。序号接着已有项往下编；追加的项自动入队。
    /// 去重按 sourceURL（重复追加的地址会被跳过）。
    func addItems(
        batchID: UUID,
        pageURLs: [String] = [],
        mediaURLs: [String] = [],
        referer: URL? = nil
    ) -> (added: Int, duplicates: Int) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state != .cancelled else { return (0, 0) }
        let batch = batches[bi]

        let existing = Set(batch.items.map { $0.sourceURL.absoluteString })
        let wasFinished = batch.state == .finished

        var newItems: [BatchMediaItem] = []
        var duplicates = 0
        let startIndex = batch.items.count
        let nextTotal = startIndex + max(pageURLs.count, mediaURLs.count)

        func makeNumber(_ offset: Int) -> String {
            BatchMediaPlan.numberedPrefix(startIndex + offset, total: nextTotal)
        }

        switch batch.mode {
        case .list:
            for (offset, raw) in pageURLs.enumerated() {
                guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "http" || url.scheme == "https" else { duplicates += 1; continue }
                guard !existing.contains(url.absoluteString) else { duplicates += 1; continue }
                newItems.append(BatchMediaItem(
                    id: UUID(),
                    sourceURL: url,
                    mediaURL: nil,
                    referer: nil,
                    title: makeNumber(offset),
                    numberPrefix: makeNumber(offset)
                ))
            }
        case .page:
            let style = BatchMediaPreferences.namingStyle
            for (offset, raw) in mediaURLs.enumerated() {
                guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "http" || url.scheme == "https" else { duplicates += 1; continue }
                guard !existing.contains(url.absoluteString) else { duplicates += 1; continue }
                newItems.append(BatchMediaItem(
                    id: UUID(),
                    sourceURL: url,
                    mediaURL: url,
                    referer: referer,
                    title: "\(makeNumber(offset))-\(BatchMediaPlan.displayName(pageTitle: "", mediaURL: url, style: style))",
                    numberPrefix: makeNumber(offset)
                ))
            }
        }

        guard !newItems.isEmpty else { return (0, duplicates) }
        batches[bi].items.append(contentsOf: newItems)
        Log.downloads.info("batch add-items: +\(newItems.count, privacy: .public) (batch \(batchID.uuidString.prefix(8), privacy: .public))")

        if wasFinished {
            batches[bi].state = .running
            persistUnfinished()
            startEngine(batchID)
        } else {
            // 引擎在跑：list 模式的 resolveAll 下一圈自然捡到新 pending；
            // page 模式靠 pump。挂起/暂停中的批次恢复后自动接上。
            persistUnfinished()
            pumpDownloads(batchID)
        }
        return (newItems.count, duplicates)
    }

    /// 跳过一项（pending / needsHuman / downloading 可跳；终态忽略）。
    /// downloading 的跳过 = 取消该单项任务。
    func skip(batchID: UUID, itemID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running,
              let ii = batches[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        let state = batches[bi].items[ii].state
        guard [.pending, .needsHuman, .downloading].contains(state) else { return }
        if state == .downloading, let jobID = batches[bi].items[ii].jobID {
            // downloadSettled 回调里按"已 skipped"短路，不会改写终态。
            batches[bi].items[ii].state = .skipped
            batches[bi].items[ii].summary = "skipped"
            MediaExportStore.shared.cancel(id: jobID)
            persistUnfinished()
            // P1-16：被 skip 的项若正是唯一在跑项，并发槽已空但没有任何
            // 回调再碰这个批次（downloadSettled 被 skipped 短路）——必须
            // 主动推进，否则批次永久卡 running。
            pumpDownloads(batchID)
            checkBatchSettled(batchID)
            return
        }
        batches[bi].items[ii].state = .skipped
        batches[bi].items[ii].summary = "skipped"
        persistUnfinished()
        pumpDownloads(batchID)
        checkBatchSettled(batchID)
    }

    /// 手动暂停：解析停摆、不起新下载、在跑项收回 pending。
    func pause(batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running,
              !pausedBatches.contains(batchID) else { return }
        pausedBatches.insert(batchID)
        engineTasks[batchID]?.cancel()
        watchdogTasks[batchID]?.cancel()
        pullBackInFlightItems(batchID, summary: "paused")
        persistUnfinished()
        Log.downloads.info("batch paused (batch \(batchID.uuidString.prefix(8), privacy: .public))")
    }

    /// 恢复（手动暂停或挂起后）。
    func resume(batchID: UUID) {
        pausedBatches.remove(batchID)
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        Log.downloads.info("batch resumed (batch \(batchID.uuidString.prefix(8), privacy: .public))")
        persistUnfinished()
        ensureEngine(batchID)
        pumpDownloads(batchID)
    }

    func isPaused(_ batchID: UUID) -> Bool { pausedBatches.contains(batchID) }
    func suspensionReason(_ batchID: UUID) -> String? { suspendedReasons[batchID] }

    // MARK: - 断点续传（未完成批次持久化）

    /// 落盘快照：只存**未完成**批次。重启后恢复到队列（暂停态），
    /// 下载中的项收回到 pending；失败的项保留 attempts（自动重试可用）。
    private struct PersistedItem: Codable {
        let id: UUID
        let sourceURL: String
        var mediaURL: String?
        var referer: String?
        let title: String
        let numberPrefix: String
        var state: String
        var summary: String?
        var attempts: Int
    }

    private struct PersistedBatch: Codable {
        let id: UUID
        let mode: String
        let folderName: String
        let createdAt: Date
        let userAgent: String?
        var force: Bool = false
        var items: [PersistedItem]
        // 用户指定的目标目录与分卷规则必须随批存活——此前 restore 丢
        // saveRoot，恢复后整批回落默认 Downloads（用户实测）。
        var saveRoot: String? = nil
        var splitEvery: Int? = nil
    }

    private static let persistenceKey = "batch-media-unfinished"

    /// 把所有 running 批次写入 DiskStore（debounce 写，热路径安全）。
    private func persistUnfinished() {
        let pending = batches.filter { $0.state == .running }.map { batch -> PersistedBatch in
            PersistedBatch(
                id: batch.id, mode: batch.mode.rawValue, folderName: batch.folderName,
                createdAt: batch.createdAt, userAgent: batchUserAgents[batch.id],
                force: forceDownloadBatches.contains(batch.id),
                items: batch.items.map { item in
                    PersistedItem(
                        id: item.id, sourceURL: item.sourceURL.absoluteString,
                        mediaURL: item.mediaURL?.absoluteString, referer: item.referer?.absoluteString,
                        title: item.title, numberPrefix: item.numberPrefix,
                        state: item.state.rawValue, summary: item.summary, attempts: item.attempts
                    )
                },
                saveRoot: batch.saveRoot, splitEvery: batch.splitEvery
            )
        }
        if pending.isEmpty {
            DiskStore.remove(key: Self.persistenceKey)
        } else {
            DiskStore.save(pending, key: Self.persistenceKey)
        }
    }

    /// 启动恢复：把上次未完成的批次放回队列（**暂停态**，摘要
    /// "restored after app restart"），用户/Agent resume 继续或取消。
    /// AppState.init 调用（幂等）。
    func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let persisted = DiskStore.load([PersistedBatch].self, key: Self.persistenceKey) ?? []
            guard !persisted.isEmpty else { return }
            var restoredFolders: [String] = []
            for persistedBatch in persisted {
                let mode = BatchMediaBatch.Mode(rawValue: persistedBatch.mode) ?? .list
                let items = persistedBatch.items.map { item -> BatchMediaItem in
                    var state = BatchMediaItem.State(rawValue: item.state) ?? .pending
                    var summary = item.summary
                    // 在途状态随进程死了，收回到 pending 等待续跑
                    if [.downloading, .resolving, .needsHuman].contains(state) {
                        state = .pending
                        summary = "restored after app restart"
                    }
                    return BatchMediaItem(
                        id: item.id,
                        sourceURL: URL(string: item.sourceURL) ?? URL(fileURLWithPath: "/dev/null"),
                        mediaURL: item.mediaURL.flatMap(URL.init(string:)),
                        referer: item.referer.flatMap(URL.init(string:)),
                        title: item.title,
                        numberPrefix: item.numberPrefix,
                        state: state,
                        summary: summary,
                        attempts: item.attempts
                    )
                }
                // 旧持久化没有 saveRoot/splitEvery（optional 解码 nil）。
                // folder 恢复**保真**：""（目录直存）原样保留，只有 "." 类
                // 噪音归位为时间戳文件夹——恢复不得改变批次落点。
                let rawFolder = persistedBatch.folderName
                let folder = (rawFolder == "." || rawFolder == ".." || rawFolder == "/")
                    ? "Desire-Batch-" + Self.folderTimestamp()
                    : rawFolder
                let batch = BatchMediaBatch(
                    id: persistedBatch.id, mode: mode,
                    saveRoot: persistedBatch.saveRoot, splitEvery: persistedBatch.splitEvery,
                    folderName: folder,
                    items: items, state: .running, createdAt: persistedBatch.createdAt
                )
                batches.append(batch)
                batchUserAgents[batch.id] = persistedBatch.userAgent
                if persistedBatch.force { forceDownloadBatches.insert(batch.id) }
                pausedBatches.insert(batch.id)
                restoredFolders.append(batch.folderName)
            }
            Log.downloads.info("restored \(restoredFolders.count, privacy: .public) unfinished batch(es) from last launch")
            MediaExportStore.shared.deliverNote(
                String(localized: "Batch downloads restored"),
                body: restoredFolders.joined(separator: ", ") + " — paused; resume to continue"
            )
            persistUnfinished()
        }
    }

    private var didRestore = false

    /// 取消整批：终止引擎、取消在跑的下载、收起验证窗。
    /// 更新批次的分卷规则（桥 manage add 的参数同步：追加任务的最新
    /// 意图覆盖旧批次遗留的分卷设置）。0/nil = 不分卷。
    func setSplitEvery(batchID: UUID, _ value: Int?) {
        guard let idx = batches.firstIndex(where: { $0.id == batchID }) else { return }
        batches[idx].splitEvery = (value ?? 0) > 0 ? value : nil
        persistUnfinished()
    }

    /// 从面板**移除已结束**的批次（finished/cancelled）：清孤儿 .part、
    /// 摘出列表。running 批不适用（先 cancel）。此前已结束批次永远占着
    /// 面板、删除按钮是空操作（用户实测"删除无效"）。
    func removeSettled(batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state != .running else { return }
        engineTasks[batchID]?.cancel()
        engineTasks[batchID] = nil
        watchdogTasks[batchID]?.cancel()
        watchdogTasks[batchID] = nil
        spaceMonitorTasks[batchID]?.cancel()
        spaceMonitorTasks[batchID] = nil
        resolvers[batchID]?.teardown()
        resolvers[batchID] = nil
        cleanOrphanParts(batchID)
        batches.remove(at: bi)
        pausedBatches.remove(batchID)
        suspendedReasons[batchID] = nil
        forceDownloadBatches.remove(batchID)
        persistUnfinished()
    }

    func cancel(batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        batches[bi].state = .cancelled
        engineTasks[batchID]?.cancel()
        watchdogTasks[batchID]?.cancel()
        engineTasks[batchID] = nil
        watchdogTasks[batchID] = nil
        engineRunning.remove(batchID)
        diskAskInFlight.remove(batchID)
        pausedBatches.remove(batchID)
        suspendedReasons[batchID] = nil
        forceDownloadBatches.remove(batchID)
        spaceMonitorTasks[batchID]?.cancel()
        spaceMonitorTasks[batchID] = nil
        for ii in batches[bi].items.indices where batches[bi].items[ii].state == .downloading {
            if let jobID = batches[bi].items[ii].jobID {
                MediaExportStore.shared.cancel(id: jobID)
            }
        }
        // 非终态项统一收口成 skipped，快照里不留永远停在 resolving 的行。
        for ii in batches[bi].items.indices
        where ![.finished, .failed, .skipped].contains(batches[bi].items[ii].state) {
            batches[bi].items[ii].state = .skipped
            batches[bi].items[ii].summary = "batch cancelled"
        }
        resolvers[batchID]?.teardown()
        resolvers[batchID] = nil
        batchUserAgents[batchID] = nil
        cleanOrphanParts(batchID)
        BatchVerifyWindowController.shared.dismiss()
        MediaExportStore.shared.deliverNote(
            String(localized: "Batch download cancelled"),
            body: saveRootDescription + "/" + batches[bi].folderName
        )
    }

    /// 第十批：清理批内文件夹残留的 `.part` 孤儿（取消/崩溃遗留）——只扫
    /// 本批目录一层，命中 `.part` 后缀即删（目录专属本批，无误删风险）。
    private func cleanOrphanParts(_ batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }) else { return }
        let root = saveRootURL(for: batchID)
            .appendingPathComponent(batches[bi].folderName, isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasSuffix(".part") {
            try? fm.removeItem(at: entry)
        }
    }

    private var saveRootDescription: String {
        BatchMediaPreferences.baseDirectory ?? "~/Downloads"
    }

    // MARK: - 引擎

    private func startEngine(_ batchID: UUID) {
        guard !engineRunning.contains(batchID) else { return }
        engineRunning.insert(batchID)
        if batches.first(where: { $0.id == batchID })?.mode == .list, resolvers[batchID] == nil {
            resolvers[batchID] = HeadlessMediaResolver()
        }
        engineTasks[batchID] = Task { [weak self] in
            await self?.engineLoop(batchID)
            self?.engineRunning.remove(batchID)
        }
        watchdogTasks[batchID] = Task { [weak self] in
            await self?.watchStalls(batchID)
        }
    }

    /// 槽位看门狗：HLS/ffmpeg 项有进度回调——**超过 3 分钟没有任何进度推进**
    /// 的在跑项，直接取消其导出任务（completion 以 failed 收场 → attempts
    /// 递增、槽位释放、队列继续）。此前一个挂死的下载会占住并发槽到天荒地老，
    /// "一个卡住、剩下的全卡住"。没有进度数据的项目（URLSession 直连单文件）
    /// 不适用——它们由 URLSession 自身的请求/资源超时兜底。
    private func watchStalls(_ batchID: UUID) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            guard let bi = batches.firstIndex(where: { $0.id == batchID }),
                  batches[bi].state == .running,
                  !isHalted(batchID) else { return }
            let now = Date()
            for item in batches[bi].items where item.state == .downloading {
                guard let at = lastProgressAt[item.id],
                      now.timeIntervalSince(at) > 180,
                      let jobID = item.jobID else { continue }
                Log.downloads.error("item stalled (no progress for 3min) — cancelling its job to free the slot (batch \(batchID.uuidString.prefix(8), privacy: .public))")
                lastProgressAt[item.id] = nil
                MediaExportStore.shared.cancel(id: jobID)
            }
        }
    }

    private func engineLoop(_ batchID: UUID) async {
        let mode = batches.first(where: { $0.id == batchID })?.mode ?? .page
        if mode == .list {
            await resolveAll(batchID)
        }
        pumpDownloads(batchID)
        checkBatchSettled(batchID)
    }

    /// list 模式：按队列顺序逐页解析（串行 + 抖动）。
    ///
    /// **节流**：下载占满并发槽时不预解析——签名 URL 按需签，提前解析的
    /// 地址会在队列里过期（2026-09-26 实测 12 部大批次 403 一批的根因）。
    private func resolveAll(_ batchID: UUID) async {
        while !Task.isCancelled {
            guard !isHalted(batchID) else { return }
            guard let bi = batches.firstIndex(where: { $0.id == batchID }),
                  batches[bi].state == .running,
                  // 只解析**未解析**的项：pending 且还没有 mediaURL。已解析
                  // 待下载的项（低空间挂起时）留在这重解析会无限空转
                  //（实测 attempts 涨到 6，页面被反复加载）。
                  let pendingID = batches[bi].items.first(where: {
                      $0.state == .pending && $0.mediaURL == nil
                  })?.id else { return }
            // 并发槽满就等：downloaded-pending（已解析未开始）恒为 0，
            // 所以槽满 = running == cap。
            while !Task.isCancelled, !isHalted(batchID),
                  batches.first(where: { $0.id == batchID })?
                      .items.filter({ $0.state == .downloading }).count ?? 0 >= maxConcurrentDownloads {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, !isHalted(batchID) else { return }
            await resolveItem(batchID: batchID, itemID: pendingID)
            if !Task.isCancelled, !isHalted(batchID) {
                try? await Task.sleep(for: .seconds(Double.random(in: 2...5)))
            }
        }
    }

    private func resolveItem(batchID: UUID, itemID: UUID) async {
        guard let resolver = resolvers[batchID] else {
            setState(batchID, itemID, .failed, summary: "resolver unavailable")
            return
        }
        guard let sourceURL = batches.first(where: { $0.id == batchID })?
            .items.first(where: { $0.id == itemID })?.sourceURL else { return }
        bumpAttempts(batchID, itemID)
        setState(batchID, itemID, .resolving)
        Log.downloads.info("resolving \(sourceURL.absoluteString, privacy: .public) (batch \(batchID.uuidString.prefix(8), privacy: .public))")

        var outcome = await resolver.load(sourceURL)
        var humanNotified = false

        while case .needsHuman = outcome {
            setState(batchID, itemID, .needsHuman)
            if !humanNotified {
                humanNotified = true
                BatchVerifyWindowController.shared.present(webView: resolver.webView)
                MediaExportStore.shared.deliverNote(
                    String(localized: "Human verification required"),
                    body: sourceURL.host ?? sourceURL.absoluteString
                )
            }
            // ① 自主通过：验证窗已前置，用真实鼠标事件点 Turnstile 复选框
            //    （纯 JS click 是 isTrusted=false 的 bot 信号，反而坏事）。
            outcome = await attemptAutonomousPass(resolver, batchID: batchID, itemID: itemID)
            if case .needsHuman = outcome {
                // ② 自主通过不成 → 人工兜底：轮询挑战解除（用户在验证窗里
                //    亲手完成）；该项被外部跳过则直接让位。
                // 人工等待**不能无上限**：串行解析队列在此阻塞，用户不去点
                // 的话整批永远停摆（2026-09-30 用户实测强退）。5 分钟没人处理
                // 判失败，队列继续——事后 retryBatchDownloads 可补。
                let verifyDeadline = Date().addingTimeInterval(300)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if state(of: itemID, in: batchID) == .skipped { return }
                    if await resolver.refreshChallengeState() == false { break }
                    if Date() > verifyDeadline {
                        setState(batchID, itemID, .failed, summary: "verification not completed within 5 minutes — batch moved on; retry this item later")
                        return
                    }
                }
                if Task.isCancelled { return }
                outcome = await resolver.awaitMedia()
            }
            if case .needsHuman = outcome {
                // 验证刚解除又立刻要求验证：防死循环。
                setState(batchID, itemID, .failed, summary: "verification keeps reappearing on this page")
                return
            }
        }

        // 挂起/暂停会取消引擎任务：await 返回后任务已取消时静默让位，
        // 别把 pullBack 收回 pending 的项改写成 failed。
        if Task.isCancelled { return }
        switch outcome {
        case .media(let resources, let pageTitle):
            guard let best = BatchMediaPlan.pickBestResource(resources),
                  let mediaURL = URL(string: best.url) else {
                setState(batchID, itemID, .failed, summary: "page loaded but no downloadable media found")
                return
            }
            guard let bi = batches.firstIndex(where: { $0.id == batchID }),
                  let ii = batches[bi].items.firstIndex(where: { $0.id == itemID }),
                  batches[bi].state == .running else { return }
            let base = BatchMediaPlan.displayName(pageTitle: pageTitle, mediaURL: mediaURL, style: BatchMediaPreferences.namingStyle)
            batches[bi].items[ii].mediaURL = mediaURL
            batches[bi].items[ii].referer = sourceURL
            // 以序号为底重建标题（重试时 title 已是上一轮的完整名字，直接
            // 叠加会翻倍——"01-Retry Episode-Retry Episode"，实测踩过）。
            batches[bi].items[ii].title = "\(batches[bi].items[ii].numberPrefix)-\(base)"
            batches[bi].items[ii].state = .pending
            persistUnfinished()
            Log.downloads.info("resolved → \(mediaURL.absoluteString, privacy: .public)")
            pumpDownloads(batchID)
        case .needsHuman:
            break // 上面的 while 已处理
        case .failed(let reason):
            setState(batchID, itemID, .failed, summary: reason)
        }
    }

    /// 自主通过交互式验证：定位挑战控件的复选框（iframe 左缘中点），
    /// 发**真实**鼠标事件点击（`SyntheticInput`，走 AppKit 事件管线，
    /// isTrusted == true）。最多 3 次，每次点击后轮询挑战是否解除。
    private func attemptAutonomousPass(
        _ resolver: HeadlessMediaResolver,
        batchID: UUID,
        itemID: UUID
    ) async -> HeadlessMediaResolver.Outcome {
        for _ in 0..<3 {
            if Task.isCancelled { return .failed("cancelled") }
            if state(of: itemID, in: batchID) == .skipped { return .failed("skipped") }
            // 找不到控件 / webview 不在可见窗口里 → 点了也没用，直接放弃。
            guard let point = await resolver.challengeCheckboxWindowPoint() else { break }
            await SyntheticInput.click(at: point, in: resolver.webView)
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(2))
                if state(of: itemID, in: batchID) == .skipped { return .failed("skipped") }
                if await resolver.refreshChallengeState() == false {
                    return await resolver.awaitMedia()
                }
            }
        }
        return .needsHuman
    }

    // MARK: - 下载闸门

    /// 下载闸门：running < cap 才从 pending 里起新任务；剩余空间低于预留
    /// 线时挂起整批（在跑项收回 pending + 提醒）。
    private func pumpDownloads(_ batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        guard !isHalted(batchID) else { return }
        if let free = volumeFreeBytes(at: saveRootURL(for: batchID)), free < reserveBytes {
            suspend(batchID: batchID, reason: "disk free space (\(Self.gb(free)) GB) is below the reserve (\(BatchMediaPreferences.reserveGB) GB)")
            return
        }
        var running = batches[bi].items.filter { $0.state == .downloading }.count
        for ii in batches[bi].items.indices {
            guard running < maxConcurrentDownloads else { break }
            guard batches[bi].items[ii].state == .pending,
                  let mediaURL = batches[bi].items[ii].mediaURL else { continue }
            let itemID = batches[bi].items[ii].id
            let title = batches[bi].items[ii].title
            let referer = batches[bi].items[ii].referer
            // 分卷规则：每 splitEvery 个文件滚动一个 archivedNNN 子文件夹。
            // 卷号按**文件编号**（01→第1卷、121→第2卷）而非"非跳过序数"——
            // 重跑同一列表时前面的项会被"已下载"跳过，按序数算会让
            // 121-240 错落进 archived001（与上一批的 1-120 混住，实测推演）。
            // 编号解析不出才退回序数。folder 为空 = 目录直存，只有分卷层。
            var itemFolder = batches[bi].folderName
            if let split = batches[bi].splitEvery, split > 0 {
                let number = Int(batches[bi].items[ii].numberPrefix)
                    ?? (batches[bi].items[..<ii].filter { $0.state != .skipped }.count + 1)
                var part = (number - 1) / split + 1
                // **智能顺延**：候选卷的**实际文件数**已满（≥ split，.part 残件
                // 不计）则滚到下一卷——跨批次共用同一目录、用户手工放过文件、
                // 跳过造成的错位都能自愈（"144 个文件了还没分卷"就是各批编号
                // 都不足 N、按编号永远滚不起来的场景）。
                let fm = FileManager.default
                let folderRoot = batches[bi].folderName.isEmpty
                    ? saveRootURL(for: batchID)
                    : saveRootURL(for: batchID).appendingPathComponent(batches[bi].folderName, isDirectory: true)
                while part < 999 {
                    let candidate = folderRoot.appendingPathComponent(
                        String(format: "archived%03d", part), isDirectory: true)
                    let occupied = (try? fm.contentsOfDirectory(atPath: candidate.path))?
                        .filter { !$0.hasSuffix(".part") }.count ?? 0
                    if occupied < split { break }
                    part += 1
                }
                let rolling = String(format: "archived%03d", part)
                itemFolder = itemFolder.isEmpty ? rolling : itemFolder + "/" + rolling
            }
            let folderName = itemFolder.isEmpty ? nil : itemFolder
            let userAgent = batchUserAgents[batchID]
            // 已下载索引：重跑同一列表不重复占盘（force 批次绕过）。
            // **智能判断**：索引命中还要验证落盘文件仍在——用户手动删除/
            // 移动过的话照常重新下载并刷新索引，而不是永远跳过。
            if !forceDownloadBatches.contains(batchID), BatchMediaPreferences.skipDownloaded,
               let downloaded = BatchDownloadedIndex.file(for: mediaURL.absoluteString) {
                if FileManager.default.fileExists(atPath: downloaded) {
                    batches[bi].items[ii].state = .skipped
                    batches[bi].items[ii].summary = "already downloaded: \(downloaded)"
                    Log.downloads.info("item skipped (already downloaded: \(downloaded, privacy: .public))")
                    continue
                }
                Log.downloads.info("index hit but file missing — re-downloading (\(downloaded, privacy: .public))")                
            }
            batches[bi].items[ii].state = .downloading
            running += 1
            let jobID = MediaExportStore.shared.start(
                url: mediaURL,
                referer: referer,
                userAgent: userAgent,
                fileNameHint: title,
                folderName: folderName,
                baseDirectory: batches[bi].saveRoot ?? BatchMediaPreferences.baseDirectory,
                notify: false,
                completion: { [weak self] outcome in
                    self?.downloadSettled(batchID: batchID, itemID: itemID, outcome: outcome)
                },
                progressHandler: { [weak self] done, total, unit in
                    self?.recordProgress(itemID: itemID, done: done, total: total, unit: unit)
                }
            )
            if let jobIndex = batches.firstIndex(where: { $0.id == batchID }),
               let itemIndex = batches[jobIndex].items.firstIndex(where: { $0.id == itemID }) {
                batches[jobIndex].items[itemIndex].jobID = jobID
            }
        }
    }

    // MARK: - 磁盘预留（硬底线）

    private var reserveBytes: Int64 {
        Int64(BatchMediaPreferences.reserveGB) * 1_073_741_824
    }

    /// 恢复余量：略高于预留线（迟滞），避免在边界上反复挂起/恢复。
    private var resumeBytes: Int64 {
        reserveBytes + 512 * 1_048_576
    }

    private func saveRootURL(for batchID: UUID) -> URL {
        // 用户对话里显式指定的目录优先（随批持久化）；否则全局偏好/默认。
        if let batch = batches.first(where: { $0.id == batchID }), let root = batch.saveRoot {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        if let base = BatchMediaPreferences.baseDirectory {
            return URL(fileURLWithPath: base, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    private func volumeFreeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    /// 进度回调里的空间巡检：节流到 5s 一次（statfs 虽轻，段回调很密）。
    /// 快照读取逐项进度（无在途进度返回 nil）。
    func progress(for itemID: UUID) -> (done: Int, total: Int, unit: MediaExporter.ProgressUnit)? {
        itemProgress[itemID]
    }

    private func recordProgress(itemID: UUID, done: Int, total: Int, unit: MediaExporter.ProgressUnit) {
        itemProgress[itemID] = (done, total, unit)
        lastProgressAt[itemID] = Date()
        guard Date().timeIntervalSince(lastSpaceCheckAt) > 5 else { return }
        lastSpaceCheckAt = Date()
        // 在跑的项还在写盘——按 itemID 找回所属批次并挂起（各批可能各有
        // 自己的保存目录，逐一检查剩余空间）。
        for batch in batches where batch.state == .running {
            guard batch.items.contains(where: { $0.id == itemID }) else { continue }
            let root = saveRootURL(for: batch.id)
            guard let free = volumeFreeBytes(at: root), free < reserveBytes else { return }
            suspend(batchID: batch.id, reason: "disk free space (\(Self.gb(free)) GB) dropped below the reserve (\(BatchMediaPreferences.reserveGB) GB) while downloading")
            return
        }
    }

    /// 挂起整批：在跑项收回 pending（不烧 attempts）、提醒用户、起空间
    /// 监视（恢复后自动续跑）。**预留线不做"继续"绕过**——它的目的就是
    /// 保护磁盘。
    private func suspend(batchID: UUID, reason: String) {
        guard suspendedReasons[batchID] == nil,
              let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        suspendedReasons[batchID] = reason
        engineTasks[batchID]?.cancel()
        watchdogTasks[batchID]?.cancel()
        engineTasks[batchID] = nil
        watchdogTasks[batchID] = nil
        engineRunning.remove(batchID)
        pullBackInFlightItems(batchID, summary: "suspended: disk reserve")
        persistUnfinished()
        let folder = batches[bi].folderName
        Log.downloads.error("batch suspended: \(reason, privacy: .public) (batch \(batchID.uuidString.prefix(8), privacy: .public))")
        MediaExportStore.shared.deliverNote(
            String(localized: "Batch download suspended"),
            body: "\(folder) — \(reason)"
        )
        startSpaceMonitor(batchID)
        scheduleSuspendAsk(batchID: batchID, reason: reason)
    }

    /// 在跑/解析中的项收回到 pending（挂起与手动暂停共用）。
    private func pullBackInFlightItems(_ batchID: UUID, summary: String) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }) else { return }
        for ii in batches[bi].items.indices where batches[bi].items[ii].state == .downloading {
            if let jobID = batches[bi].items[ii].jobID {
                MediaExportStore.shared.cancel(id: jobID)
            }
        }
        for ii in batches[bi].items.indices
        where [.downloading, .resolving, .needsHuman].contains(batches[bi].items[ii].state) {
            batches[bi].items[ii].state = .pending
            batches[bi].items[ii].summary = summary
        }
    }

    /// 挂起后的面板提问：换位置 / 取消 / 已清理空间继续。用户不答也没
    /// 关系——空间监视会在恢复条件满足时自动续跑。
    private func scheduleSuspendAsk(batchID: UUID, reason: String) {
        guard !diskAskInFlight.contains(batchID) else { return }
        diskAskInFlight.insert(batchID)
        Task { [weak self] in
            guard let self else { return }
            defer { self.diskAskInFlight.remove(batchID) }
            guard let bi = self.batches.firstIndex(where: { $0.id == batchID }),
                  self.batches[bi].state == .running,
                  self.suspendedReasons[batchID] != nil else { return }
            let folder = self.batches[bi].folderName
            let answer = await UserPromptCenter.shared.ask(
                "批量下载已挂起：\(reason)。\n" +
                "批次「\(folder)」保留在队列里，磁盘空间恢复后会自动继续。\n" +
                "回复：**换位置**（选择其他文件夹，并记住这个偏好）/ **取消** / **已清理空间，继续**"
            )
            self.diskAskInFlight.remove(batchID)
            guard let bi2 = self.batches.firstIndex(where: { $0.id == batchID }),
                  self.batches[bi2].state == .running,
                  self.suspendedReasons[batchID] != nil else { return }
            let normalized = answer.lowercased()
            if normalized.contains("取消") || normalized.contains("cancel") {
                self.suspendedReasons[batchID] = nil
                self.spaceMonitorTasks[batchID]?.cancel()
                self.cancel(batchID: batchID)
                return
            }
            if normalized.contains("换") || normalized.contains("位置") || normalized.contains("move") || normalized.contains("folder") {
                if let picked = await Self.pickDirectory() {
                    BatchMediaPreferences.baseDirectory = picked.path
                }
            }
            // "已清理空间，继续" 与 "换位置" 都走同一条重查路径：
            // 空间够就恢复，不够则保持挂起（监视任务继续盯着）。
            self.resumeIfSpaceAllows(batchID)
        }
    }

    /// 空间监视：挂起期间每 30s 查一次，恢复条件满足（≥ 预留 + 512MB
    /// 迟滞）自动续跑并提醒。
    private func startSpaceMonitor(_ batchID: UUID) {
        guard spaceMonitorTasks[batchID] == nil else { return }
        spaceMonitorTasks[batchID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                guard self.suspendedReasons[batchID] != nil,
                      let bi = self.batches.firstIndex(where: { $0.id == batchID }),
                      self.batches[bi].state == .running else { return }
                self.resumeIfSpaceAllows(batchID, announce: true)
                if self.suspendedReasons[batchID] == nil { return }
            }
        }
    }

    /// 重查空间，够（≥ 预留 + 迟滞）就摘掉挂起并续跑；不够维持挂起。
    private func resumeIfSpaceAllows(_ batchID: UUID, announce: Bool = false) {
        guard suspendedReasons[batchID] != nil,
              let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        guard let free = volumeFreeBytes(at: saveRootURL(for: batchID)), free >= resumeBytes else { return }
        let reason = suspendedReasons[batchID]
        suspendedReasons[batchID] = nil
        spaceMonitorTasks[batchID]?.cancel()
        spaceMonitorTasks[batchID] = nil
        Log.downloads.info("batch auto-resumed after disk space recovery (batch \(batchID.uuidString.prefix(8), privacy: .public))")
        if announce {
            MediaExportStore.shared.deliverNote(
                String(localized: "Batch download resumed"),
                body: "\(batches[bi].folderName) — was suspended: \(reason ?? "disk reserve")"
            )
        }
        ensureEngine(batchID)
        pumpDownloads(batchID)
    }

    // MARK: - 暂停/挂起判定

    private func isHalted(_ batchID: UUID) -> Bool {
        pausedBatches.contains(batchID) || suspendedReasons[batchID] != nil
    }

    /// 引擎循环已退（暂停/挂起导致）时重启；还在跑就不动。
    private func ensureEngine(_ batchID: UUID) {
        guard !engineRunning.contains(batchID) else { return }
        startEngine(batchID)
    }

    @MainActor
    private static func pickDirectory() async -> URL? {
        // 第十批：sheet 化（runModal 冻结整个 app——远程会话触发的提问
        // 尤其恶劣：主线程上挂着整个远程桥等物理点击）。
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择批量视频的保存位置（会记住这个偏好）"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.directoryURL : nil)
            }
        }
    }

    // MARK: - 结果回收与自动重试

    private func downloadSettled(batchID: UUID, itemID: UUID, outcome: MediaExportStore.JobOutcome) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running,
              let ii = batches[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        itemProgress[itemID] = nil
        lastProgressAt[itemID] = nil
        // 外部（skip）已定的终态不被回调改写。
        guard batches[bi].items[ii].state != .skipped else { return }
        switch outcome {
        case .finished(let result):
            batches[bi].items[ii].state = .finished
            batches[bi].items[ii].summary = "\(result.fileURL.lastPathComponent), \(result.displayBytes)" +
                (result.verification.map { ", ✓ \($0)" } ?? "")
            BatchDownloadedIndex.record(
                urls: [batches[bi].items[ii].sourceURL.absoluteString, batches[bi].items[ii].mediaURL?.absoluteString ?? ""],
                file: result.fileURL.path
            )
            Log.downloads.info("item finished: \(result.fileURL.lastPathComponent, privacy: .public) (\(result.displayBytes, privacy: .public))")
        case .failed(let error):
            // 挂起/暂停导致的取消回收为 pending（不烧 attempts），等恢复续跑。
            if isHalted(batchID), (error as? URLError)?.code == .cancelled || error is CancellationError {
                batches[bi].items[ii].state = .pending
                batches[bi].items[ii].summary = isSuspendedSummary(batchID)
                persistUnfinished()
                return
            }
            // P0-D：下载失败也烧 attempts——此前只有解析阶段递增，page 模式
            // 下载失败 attempts 恒 0 → 重试判据恒真 → 无限循环，批次永不落定。
            batches[bi].items[ii].attempts += 1
            batches[bi].items[ii].state = .failed
            batches[bi].items[ii].summary = error.localizedDescription
            Log.downloads.error("item failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            if isHalted(batchID) {
                batches[bi].items[ii].state = .pending
                batches[bi].items[ii].summary = isSuspendedSummary(batchID)
                persistUnfinished()
                return
            }
            batches[bi].items[ii].state = .skipped
            batches[bi].items[ii].summary = "cancelled"
        }
        persistUnfinished()
        pumpDownloads(batchID)
        checkBatchSettled(batchID)
    }

    private func isSuspendedSummary(_ batchID: UUID) -> String {
        suspendedReasons[batchID] != nil ? "suspended: disk reserve" : "paused"
    }

    /// 全部落定（无 pending/resolving/needsHuman/downloading）→ 还有可重试
    /// 的失败项就冷却后**同批重跑**（同文件夹，不另开批次）；全部终态才汇总。
    private func checkBatchSettled(_ batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              batches[bi].state == .running else { return }
        guard !isHalted(batchID) else { return } // 挂起/暂停中不算落定
        let unsettled = batches[bi].items.contains { state in
            ![.finished, .failed, .skipped].contains(state.state)
        }
        guard !unsettled else { return }
        let retryable = batches[bi].items.contains {
            $0.state == .failed && $0.attempts < Self.maxItemAttempts
        }
        guard retryable else {
            finalize(batchID)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.retryCooldownSeconds ?? 15))
            guard let self else { return }
            guard let bi = self.batches.firstIndex(where: { $0.id == batchID }),
                  self.batches[bi].state == .running,
                  !self.isHalted(batchID) else { return }
            for ii in self.batches[bi].items.indices
            where self.batches[bi].items[ii].state == .failed
                && self.batches[bi].items[ii].attempts < Self.maxItemAttempts {
                self.batches[bi].items[ii].state = .pending
                self.batches[bi].items[ii].summary = nil
                if self.batches[bi].mode == .list {
                    // 换新解析地址（签名 URL 过期是 403 的主因）
                    self.batches[bi].items[ii].mediaURL = nil
                }
            }
            self.startEngine(batchID)
        }
    }

    private func finalize(_ batchID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }) else { return }
        batches[bi].state = .finished
        engineTasks[batchID] = nil
        watchdogTasks[batchID] = nil
        engineRunning.remove(batchID)
        diskAskInFlight.remove(batchID)
        forceDownloadBatches.remove(batchID)
        resolvers[batchID]?.teardown()
        resolvers[batchID] = nil
        batchUserAgents[batchID] = nil
        spaceMonitorTasks[batchID]?.cancel()
        spaceMonitorTasks[batchID] = nil
        suspendedReasons[batchID] = nil
        persistUnfinished()
        cleanOrphanParts(batchID)
        BatchVerifyWindowController.shared.dismiss()

        let batch = batches[bi]
        let failed = batch.items.filter { $0.state == .failed }
        let skipped = batch.items.filter { $0.state == .skipped }
        var body = "\(batch.finishedCount)/\(batch.items.count) → \(saveRootDescription)/\(batch.folderName)"
        if !skipped.isEmpty {
            body += "\nSkipped: " + skipped.map { entry in
                let name = String((entry.title.isEmpty ? entry.sourceURL.absoluteString : entry.title).prefix(60))
                return "\(name) (\(entry.summary ?? ""))"
            }.joined(separator: "; ")
        }
        if !failed.isEmpty {
            body += "\nFailed: " + failed.map {
                // 汇总备注里的标题截断——真实站点那批的整条备注被 80 字符×
                // 重复模板的标题撑爆过。
                "\($0.title.prefix(60)) (\($0.summary ?? ""))"
            }.joined(separator: "; ")
        }
        Log.downloads.info("batch finished: \(batch.finishedCount, privacy: .public)/\(batch.items.count, privacy: .public)")
        MediaExportStore.shared.deliverNote(
            String(localized: "Batch download finished"),
            body: body
        )
    }

    // MARK: - 状态工具（全部现查 index——批次数组头插会移动下标）

    private func setState(_ batchID: UUID, _ itemID: UUID, _ state: BatchMediaItem.State, summary: String? = nil) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              let ii = batches[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        guard batches[bi].state == .running else { return }
        // 外部（skip）设置的状态不被引擎覆盖；取消后不再改状态。
        if batches[bi].items[ii].state == .skipped { return }
        batches[bi].items[ii].state = state
        if let summary { batches[bi].items[ii].summary = summary }
        persistUnfinished()
    }

    private func bumpAttempts(_ batchID: UUID, _ itemID: UUID) {
        guard let bi = batches.firstIndex(where: { $0.id == batchID }),
              let ii = batches[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        batches[bi].items[ii].attempts += 1
    }

    private func state(of itemID: UUID, in batchID: UUID) -> BatchMediaItem.State? {
        batches.first(where: { $0.id == batchID })?
            .items.first(where: { $0.id == itemID })?.state
    }
}
