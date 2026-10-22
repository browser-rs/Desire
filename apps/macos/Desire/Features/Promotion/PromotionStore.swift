import Combine
import Foundation

/// 运营工作台（自推广 + 自媒体/电商专项）：目标、帖子、账号、经验四类数据
/// 的单一真相。Agent 工具（promotion* / promotionAccount* / promotionLesson）、
/// 斜杠 /promote、桥 /promotion/*、Agent 窗口「运营」页全部读写这一份；
/// 持久化走 DiskStore（四个键，量小，单文件数组）。
///
/// 持续学习进化的数据链：帖子/账号的 `metricHistory` 快照积累趋势 →
/// Agent 复盘把结论写成 `lessons`（PromotionLesson）→ promotionBrief 把
/// 经验注入下次起草 → 更好的动作产生新数据。
@MainActor
final class PromotionStore: ObservableObject {
    static let shared = PromotionStore()

    @Published private(set) var goals: [PromotionGoal] = []
    @Published private(set) var posts: [PromotionPost] = []
    @Published private(set) var accounts: [PromotionAccount] = []
    @Published private(set) var lessons: [PromotionLesson] = []
    @Published private(set) var interactions: [PromotionInteraction] = []
    /// 运营战役（v0.8.2）：目标与帖子之间的 campaign 层。
    @Published private(set) var campaigns: [PromotionCampaign] = []
    /// 提及雷达来源（v0.8.2）。
    @Published private(set) var mentionSources: [MentionSource] = []

    private static let goalsKey = "promotion.goals"
    private static let postsKey = "promotion.posts"
    private static let accountsKey = "promotion.accounts"
    private static let lessonsKey = "promotion.lessons"
    private static let interactionsKey = "promotion.interactions"
    private static let campaignsKey = "promotion.campaigns"
    private static let mentionSourcesKey = "promotion.mentionSources"

    private init() {
        goals = DiskStore.load([PromotionGoal].self, key: Self.goalsKey) ?? []
        posts = DiskStore.load([PromotionPost].self, key: Self.postsKey) ?? []
        accounts = DiskStore.load([PromotionAccount].self, key: Self.accountsKey) ?? []
        lessons = DiskStore.load([PromotionLesson].self, key: Self.lessonsKey) ?? []
        interactions = DiskStore.load([PromotionInteraction].self, key: Self.interactionsKey) ?? []
        campaigns = DiskStore.load([PromotionCampaign].self, key: Self.campaignsKey) ?? []
        mentionSources = DiskStore.load([MentionSource].self, key: Self.mentionSourcesKey) ?? []
    }

    // MARK: - 目标

    @discardableResult
    func addGoal(title: String, objective: String = "", domain: OperationDomain = .promotion,
                 platforms: [String] = [], targetPosts: Int? = nil,
                 dueDate: Date? = nil) -> PromotionGoal? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let goal = PromotionGoal(
            title: trimmed,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain,
            platforms: platforms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            targetPosts: targetPosts.flatMap { $0 > 0 ? $0 : nil },
            dueDate: dueDate)
        goals.append(goal)
        persistGoals()
        return goal
    }

    func setGoalActive(_ id: UUID, active: Bool) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].isActive = active
        persistGoals()
    }

    /// 删目标不删帖子：历史数据保留，只解除关联。
    func removeGoal(_ id: UUID) {
        goals.removeAll { $0.id == id }
        var touched = false
        for i in posts.indices where posts[i].goalID == id {
            posts[i].goalID = nil
            touched = true
        }
        persistGoals()
        if touched { persistPosts() }
    }

    /// 自由文本匹配进行中的目标（标题双向包含，大小写不敏感）。
    func matchGoal(_ text: String) -> PromotionGoal? {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return goals.first { $0.isActive &&
            ($0.title.lowercased().contains(q) || q.contains($0.title.lowercased())) }
    }

    // MARK: - 帖子

    struct SaveOutcome {
        let post: PromotionPost
        /// 传了 goal 文本并匹配到目标时的目标标题（工具回执/调用方提示用）。
        let matchedGoalTitle: String?
        /// 传了 goal 文本但没匹配上（调用方应提醒可用目标清单）。
        var goalMissed: Bool {
            post.goalID == nil && missedGoalText != nil
        }
        fileprivate let missedGoalText: String?
    }

    @discardableResult
    func savePost(goalText: String?, platform: String, title: String, body: String,
                  status: PromotionPost.Status, url: String?, plannedFor: Date? = nil,
                  campaignID: UUID? = nil) -> SaveOutcome {
        var matched: PromotionGoal?
        let trimmedGoal = goalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedGoal.isEmpty { matched = matchGoal(trimmedGoal) }
        let now = Date()
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let post = PromotionPost(
            goalID: matched?.id,
            campaignID: campaignID,
            platform: platform.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            status: status,
            url: (cleanURL?.isEmpty ?? true) ? nil : cleanURL,
            publishedAt: status == .published ? now : nil,
            plannedFor: plannedFor,
            createdAt: now, updatedAt: now)
        posts.insert(post, at: 0)
        persistPosts()
        return SaveOutcome(post: post, matchedGoalTitle: matched?.title,
                           missedGoalText: matched == nil && !trimmedGoal.isEmpty ? trimmedGoal : nil)
    }

    /// 更新既有帖子（选题→草稿、改排期、补正文/URL）——nil = 保持原值；
    /// `clearPlannedFor` 显式清排期（工具里用空字符串表达）。
    @discardableResult
    func updatePost(id: UUID, goalText: String?? = nil, platform: String? = nil,
                    title: String? = nil, body: String? = nil,
                    status: PromotionPost.Status? = nil, url: String? = nil,
                    plannedFor: Date?? = nil,
                    campaignID: UUID?? = nil) -> PromotionPost? {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else { return nil }
        let now = Date()
        if let platform, !platform.isEmpty { posts[idx].platform = platform }
        if let title, !title.isEmpty { posts[idx].title = title }
        if let body { posts[idx].body = body }
        if let status {
            posts[idx].status = status
            if status == .published, posts[idx].publishedAt == nil {
                posts[idx].publishedAt = now
            }
        }
        if let url {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            posts[idx].url = clean.isEmpty ? nil : clean
        }
        if let plannedFor {
            posts[idx].plannedFor = plannedFor
        }
        if let campaignID {
            posts[idx].campaignID = campaignID
        }
        if let goalText {
            let trimmed = goalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            posts[idx].goalID = trimmed.isEmpty ? nil : matchGoal(trimmed)?.id
        }
        posts[idx].updatedAt = now
        persistPosts()
        if posts[idx].status == .published {
            JobStore.shared.completePublishJob(for: id, url: posts[idx].url)
        }
        return posts[idx]
    }

    /// 草稿 → 已发布（用户批准、内容上线后调用）。返回是否找到该帖。
    @discardableResult
    func markPublished(_ id: UUID, url: String?) -> Bool {
        guard let idx = posts.firstIndex(where: { $0.id == id }) else { return false }
        let now = Date()
        posts[idx].status = .published
        posts[idx].publishedAt = now
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanURL, !cleanURL.isEmpty { posts[idx].url = cleanURL }
        posts[idx].updatedAt = now
        persistPosts()
        JobStore.shared.completePublishJob(for: id, url: posts[idx].url)
        return true
    }

    /// 数据回收：按 id 或 URL 定位帖子，写入互动数据并**追加一条快照**
    /// （nil = 该平台没有这项；快照全部保留，增长可比）。
    @discardableResult
    func recordMetrics(idOrURL: String, views: Int?, likes: Int?, comments: Int?) -> PromotionPost? {
        let trimmed = idOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let idx: Int?
        if let uuid = UUID(uuidString: trimmed) {
            idx = posts.firstIndex { $0.id == uuid }
        } else {
            idx = posts.firstIndex { $0.url == trimmed }
        }
        guard let idx else { return nil }
        let now = Date()
        var metrics = posts[idx].metrics ?? PromotionPost.Metrics()
        if let views { metrics.views = views }
        if let likes { metrics.likes = likes }
        if let comments { metrics.comments = comments }
        metrics.collectedAt = now
        posts[idx].metrics = metrics
        posts[idx].metricHistory.append(PromotionPost.MetricSnapshot(
            at: now, views: metrics.views, likes: metrics.likes, comments: metrics.comments))
        posts[idx].updatedAt = now
        persistPosts()
        return posts[idx]
    }

    func removePost(_ id: UUID) {
        posts.removeAll { $0.id == id }
        persistPosts()
    }

    func post(id: UUID) -> PromotionPost? { posts.first { $0.id == id } }

    // MARK: - 账号（自媒体/电商专项）

    /// 建档（同 domain+platform+handle 大小写不敏感 upsert，返回账号）。
    @discardableResult
    func saveAccount(domain: OperationDomain, platform: String, handle: String,
                     url: String? = nil, note: String = "") -> PromotionAccount? {
        let p = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !h.isEmpty else { return nil }
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = accounts.firstIndex(where: {
            $0.domain == domain && $0.platform.lowercased() == p.lowercased()
                && $0.handle.lowercased() == h.lowercased()
        }) {
            accounts[idx].url = (cleanURL?.isEmpty ?? true) ? accounts[idx].url : cleanURL
            if !note.isEmpty { accounts[idx].note = note }
            persistAccounts()
            return accounts[idx]
        }
        let account = PromotionAccount(domain: domain, platform: p, handle: h,
                                       url: (cleanURL?.isEmpty ?? true) ? nil : cleanURL,
                                       note: note)
        accounts.append(account)
        persistAccounts()
        return account
    }

    /// 账号数据回收：id / handle / url 定位，追加一条快照。
    @discardableResult
    func recordAccountMetrics(idOrHandle: String, followers: Int?, views: Int?,
                              likes: Int?) -> PromotionAccount? {
        let trimmed = idOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let idx: Int?
        if let uuid = UUID(uuidString: trimmed) {
            idx = accounts.firstIndex { $0.id == uuid }
        } else {
            let q = trimmed.lowercased()
            idx = accounts.firstIndex { $0.handle.lowercased() == q || $0.url == trimmed }
        }
        guard let idx else { return nil }
        accounts[idx].snapshots.append(PromotionAccount.Snapshot(
            at: Date(), followers: followers, views: views, likes: likes))
        persistAccounts()
        return accounts[idx]
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        persistAccounts()
    }

    // MARK: - 提及雷达来源（v0.8.2）

    private static let lastMentionScanKey = "promotion.mention.lastScan"
    private static let mentionQueryKey = "promotion.mention.query"

    /// 默认监控关键词（分享/提及雷达共用；可改后持久化）。
    var mentionQuery: String {
        let raw = UserDefaults.standard.string(forKey: Self.mentionQueryKey) ?? ""
        return raw.isEmpty ? "Desire" : raw
    }

    func setMentionQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: Self.mentionQueryKey)
    }

    var lastMentionScanAt: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastMentionScanKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    var enabledMentionSources: [MentionSource] {
        mentionSources.filter(\.isEnabled)
    }

    @discardableResult
    func addMentionSource(name: String, platform: String,
                          searchURL: String) -> MentionSource? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !u.isEmpty, URL(string: u) != nil else { return nil }
        if let existing = mentionSources.first(where: { $0.searchURL == u }) {
            return existing
        }
        let source = MentionSource(name: n, platform: p.isEmpty ? "Web" : p,
                                   searchURL: u)
        mentionSources.append(source)
        persistMentionSources()
        return source
    }

    func setMentionSourceEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = mentionSources.firstIndex(where: { $0.id == id }) else { return }
        mentionSources[idx].isEnabled = enabled
        persistMentionSources()
    }

    func removeMentionSource(_ id: UUID) {
        mentionSources.removeAll { $0.id == id }
        persistMentionSources()
    }

    func markMentionScan(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970,
                                  forKey: Self.lastMentionScanKey)
    }

    // MARK: - 互动台账（评论/私信/评价）

    /// 批量登记（巡检发现一条登记一条；url 或 平台+帖子+作者+正文 去重跳过）。
    /// 返回实际新增条数。
    @discardableResult
    func logInteractions(_ drafts: [PromotionInteraction]) -> Int {
        guard !drafts.isEmpty else { return 0 }
        var existing = Set(interactions.map(\.dedupeKey))
        var added = 0
        for var item in drafts {
            let key = item.dedupeKey
            guard !existing.contains(key) else { continue }
            existing.insert(key)
            if item.author.isEmpty { item.author = "?" }
            interactions.append(item)
            added += 1
        }
        if added > 0 { persistInteractions() }
        return added
    }

    /// 回复闭环：存拟稿 / 定状态。status=replied 记 repliedAt；status=pending 可回退。
    @discardableResult
    func replyInteraction(id: UUID, reply: String?, status: PromotionInteraction.Status?) -> PromotionInteraction? {
        guard let idx = interactions.firstIndex(where: { $0.id == id }) else { return nil }
        let now = Date()
        if let reply { interactions[idx].reply = reply }
        if let status {
            interactions[idx].status = status
            interactions[idx].repliedAt = status == .replied ? now : nil
        }
        interactions[idx].updatedAt = now
        persistInteractions()
        return interactions[idx]
    }

    func removeInteraction(_ id: UUID) {
        interactions.removeAll { $0.id == id }
        persistInteractions()
    }

    var pendingInteractionCount: Int {
        interactions.filter { $0.status == .pending }.count
    }

    // MARK: - 经验（持续学习）

    /// 记一条经验。完全重复（归一化后相同）直接跳过；返回 nil 表示重复。
    @discardableResult
    func addLesson(text: String, domain: OperationDomain? = nil, platform: String? = nil,
                   source: PromotionLesson.Source = .agent) -> PromotionLesson? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = Self.normalizeLesson(trimmed)
        if lessons.contains(where: { Self.normalizeLesson($0.text) == normalized }) { return nil }
        let cleanPlatform = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lesson = PromotionLesson(
            text: trimmed, domain: domain,
            platform: (cleanPlatform?.isEmpty ?? true) ? nil : cleanPlatform,
            source: source)
        lessons.append(lesson)
        persistLessons()
        return lesson
    }

    func removeLesson(_ id: UUID) {
        lessons.removeAll { $0.id == id }
        persistLessons()
    }

    /// 归一化（去空白/标点、小写）——查重口径与记忆系统同思路。
    static func normalizeLesson(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    // MARK: - 派生与摘要

    func digest() -> String {
        PromotionSummary.digest(goals: goals, posts: posts, accounts: accounts,
                                lessons: lessons, interactions: interactions)
    }

    var outstandingDraftCount: Int {
        posts.filter { $0.status == .draft }.count
    }

    // MARK: - 战役（v0.8.2）

    struct CampaignGeneration {
        let campaign: PromotionCampaign
        let posts: [PromotionPost]
    }

    func campaign(id: UUID) -> PromotionCampaign? {
        campaigns.first { $0.id == id }
    }

    func posts(inCampaign id: UUID) -> [PromotionPost] {
        posts.filter { $0.campaignID == id }
            .sorted { ($0.plannedFor ?? $0.createdAt) < ($1.plannedFor ?? $1.createdAt) }
    }

    /// 生成战役 + 各平台草稿（确定性；草稿一律 draft，绝不自动发布）。
    /// 返回 nil = 没有可用的亮点（避免生成一份空泛的营销稿）。
    @discardableResult
    func generateCampaign(_ brief: PromotionCampaignBuilder.Brief) -> CampaignGeneration? {
        let cleanedHighlights = brief.highlights
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedHighlights.isEmpty else { return nil }
        var brief = brief
        brief.highlights = cleanedHighlights
        let goal = brief.goalText.flatMap { matchGoal($0) }
        let plan = PromotionCampaignBuilder.makePlan(brief, goalID: goal?.id)
        campaigns.insert(plan.campaign, at: 0)
        persistCampaigns()
        var created: [PromotionPost] = []
        for draft in plan.drafts {
            let outcome = savePost(
                goalText: goal?.title,
                platform: draft.platform,
                title: draft.title,
                body: draft.body,
                status: .draft,
                url: nil,
                plannedFor: draft.plannedFor,
                campaignID: plan.campaign.id)
            created.append(outcome.post)
        }
        return CampaignGeneration(campaign: plan.campaign, posts: created)
    }

    @discardableResult
    func updateCampaignStatus(_ id: UUID, status: PromotionCampaign.Status) -> Bool {
        guard let idx = campaigns.firstIndex(where: { $0.id == id }) else { return false }
        campaigns[idx].status = status
        campaigns[idx].updatedAt = Date()
        persistCampaigns()
        return true
    }

    /// 载体编辑（标题/目标/排期/素材）；nil = 保持原值。
    @discardableResult
    func updateCampaign(_ id: UUID, title: String? = nil, objective: String? = nil,
                        startsAt: Date?? = nil, assets: [String]? = nil) -> PromotionCampaign? {
        guard let idx = campaigns.firstIndex(where: { $0.id == id }) else { return nil }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            campaigns[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let objective { campaigns[idx].objective = objective }
        if let startsAt { campaigns[idx].startsAt = startsAt }
        if let assets { campaigns[idx].assets = assets }
        campaigns[idx].updatedAt = Date()
        persistCampaigns()
        return campaigns[idx]
    }

    /// 删除战役不删帖子：历史内容保留，只解除关联（与删目标同口径）。
    func removeCampaign(_ id: UUID) {
        campaigns.removeAll { $0.id == id }
        var touched = false
        for i in posts.indices where posts[i].campaignID == id {
            posts[i].campaignID = nil
            touched = true
        }
        persistCampaigns()
        if touched { persistPosts() }
    }

    // MARK: - 持久化

    private func persistGoals() { DiskStore.save(goals, key: Self.goalsKey) }
    private func persistPosts() { DiskStore.save(posts, key: Self.postsKey) }
    private func persistAccounts() { DiskStore.save(accounts, key: Self.accountsKey) }
    private func persistLessons() { DiskStore.save(lessons, key: Self.lessonsKey) }
    private func persistInteractions() { DiskStore.save(interactions, key: Self.interactionsKey) }
    private func persistCampaigns() { DiskStore.save(campaigns, key: Self.campaignsKey) }
    private func persistMentionSources() {
        DiskStore.save(mentionSources, key: Self.mentionSourcesKey)
    }
}
