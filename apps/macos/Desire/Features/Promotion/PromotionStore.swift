import Combine
import Foundation

/// 推广工作台（自推广能力）：目标 + 帖子（草稿/已发/数据）的单一真相。
/// Agent 工具（promotionBrief / promotionSave / promotionMetrics）、斜杠
/// /promote、桥 /promotion/*、Agent 窗口「推广」页全部读写这一份；
/// 持久化走 DiskStore（goals/posts 两个键，量小，单文件数组）。
@MainActor
final class PromotionStore: ObservableObject {
    static let shared = PromotionStore()

    @Published private(set) var goals: [PromotionGoal] = []
    @Published private(set) var posts: [PromotionPost] = []

    private static let goalsKey = "promotion.goals"
    private static let postsKey = "promotion.posts"

    private init() {
        goals = DiskStore.load([PromotionGoal].self, key: Self.goalsKey) ?? []
        posts = DiskStore.load([PromotionPost].self, key: Self.postsKey) ?? []
    }

    // MARK: - 目标

    @discardableResult
    func addGoal(title: String, objective: String = "", platforms: [String] = [],
                 targetPosts: Int? = nil, dueDate: Date? = nil) -> PromotionGoal? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let goal = PromotionGoal(
            title: trimmed,
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
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
                  status: PromotionPost.Status, url: String?) -> SaveOutcome {
        var matched: PromotionGoal?
        let trimmedGoal = goalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedGoal.isEmpty { matched = matchGoal(trimmedGoal) }
        let now = Date()
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let post = PromotionPost(
            goalID: matched?.id,
            platform: platform.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            status: status,
            url: (cleanURL?.isEmpty ?? true) ? nil : cleanURL,
            publishedAt: status == .published ? now : nil,
            createdAt: now, updatedAt: now)
        posts.insert(post, at: 0)
        persistPosts()
        return SaveOutcome(post: post, matchedGoalTitle: matched?.title,
                           missedGoalText: matched == nil && !trimmedGoal.isEmpty ? trimmedGoal : nil)
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
        return true
    }

    /// 数据回收：按 id 或 URL 定位帖子，写入互动数据（nil = 该平台没有这项）。
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
        posts[idx].updatedAt = now
        persistPosts()
        return posts[idx]
    }

    func removePost(_ id: UUID) {
        posts.removeAll { $0.id == id }
        persistPosts()
    }

    func post(id: UUID) -> PromotionPost? { posts.first { $0.id == id } }

    // MARK: - 派生与摘要

    func digest() -> String {
        PromotionSummary.digest(goals: goals, posts: posts)
    }

    var outstandingDraftCount: Int {
        posts.filter { $0.status == .draft }.count
    }

    // MARK: - 持久化

    private func persistGoals() { DiskStore.save(goals, key: Self.goalsKey) }
    private func persistPosts() { DiskStore.save(posts, key: Self.postsKey) }
}
