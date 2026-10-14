import AppKit
import SwiftUI

/// 运营中心页（Agent 窗口侧栏「运营」目的地）：推广 / 自媒体 / 电商三专项
/// 共用一块工作台——目标、账号、帖子（草稿/已发/增长）、运营经验。
/// 数据全部来自 `PromotionStore`（与 Agent 工具、斜杠 /promote、桥
/// /promotion/* 同源）。起草、发布、采集、复盘这些"动作"走 Agent 对话
/// （promotion / media-operations / ecommerce-operations 技能），这里管台账
/// 与人工修正；「安排每周复盘」把持续学习闭环挂进定时任务。
struct PromotionView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = PromotionStore.shared
    var onBack: () -> Void

    @State private var isCreatingGoal = false
    @State private var isCreatingAccount = false
    @State private var publishingPost: PromotionPost?
    @State private var metricsEditorID: UUID?
    @State private var accountEditorID: UUID?
    @State private var lessonDraft = ""
    @State private var reviewScheduled = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    goalsSection
                    accountsSection
                    draftsSection
                    publishedSection
                    lessonsSection
                    if store.goals.isEmpty && store.posts.isEmpty && store.accounts.isEmpty {
                        emptyState
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isCreatingGoal) { PromotionGoalEditorSheet() }
        .sheet(isPresented: $isCreatingAccount) { PromotionAccountEditorSheet() }
        .sheet(item: $publishingPost) { post in
            PromotionPublishSheet(post: post)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "megaphone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text("Operations")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HoverIcon(systemName: reviewScheduled ? "checkmark.circle" : "calendar.badge.clock",
                      action: scheduleWeeklyReview,
                      help: String(localized: "Schedule weekly review"))
            HoverIcon(systemName: "plus", action: { isCreatingGoal = true },
                      help: String(localized: "New Goal"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "megaphone")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No goals or posts yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Tell the agent to promote Desire — it drafts posts, asks for your approval, publishes, and tracks the numbers.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// 安排每周复盘（周一 10:00）：幂等——同名任务先删再建。
    private func scheduleWeeklyReview() {
        let scheduler = AgentScheduler.shared
        let name = String(localized: "Operations review (weekly)")
        _ = scheduler.remove(named: name)
        let prompt = """
        运营复盘（每周）：先调用 promotionBrief 读取运营工作台（目标进度、账号与帖子的最新数据与增长、历史经验）。然后：
        1) 回访各账号主页与已发帖子页（有 DPP 适配包用适配视图，否则 getPageText），用 promotionAccountMetrics / promotionMetrics 采集最新数据——同一账号/帖子要多采几次才形成增长曲线；
        2) 对比快照增长，总结本周有效/无效的做法；
        3) 用 promotionLesson 记录可复用的结论（平台偏好、选题、发布时间、标题风格等），完全重复的会被自动跳过；
        4) 给出下周行动计划。没有数据可复盘就回复「暂无运营数据」并结束。
        """
        _ = scheduler.add(name: name, prompt: prompt,
                          recurrence: .weekly(weekday: 2, hour: 10, minute: 0))
        withAnimation(.transitionNormal) { reviewScheduled = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.transitionNormal) { reviewScheduled = false }
        }
    }

    // MARK: - Goals

    private var activeProgress: [PromotionSummary.GoalProgress] {
        PromotionSummary.progress(goals: store.goals, posts: store.posts)
    }

    @ViewBuilder
    private var goalsSection: some View {
        if !store.goals.isEmpty {
            sectionHeader(String(localized: "Goals"), count: store.goals.count)
            VStack(spacing: 6) {
                ForEach(store.goals) { goal in
                    goalRow(goal)
                }
            }
        }
    }

    private func goalRow(_ goal: PromotionGoal) -> some View {
        let progress = activeProgress.first { $0.goalID == goal.id }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(goal.isActive ? appAccent : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(goal.domain.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(appAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(appAccent.opacity(0.12)))
                Text(goal.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if progress?.isOverdue == true {
                    Text("⚠️ " + String(localized: "Overdue"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                HoverIcon(systemName: goal.isActive ? "pause.fill" : "play.fill",
                          action: { store.setGoalActive(goal.id, active: !goal.isActive) },
                          help: goal.isActive ? String(localized: "Pause") : String(localized: "Resume"))
                HoverIcon(systemName: "trash", action: { store.removeGoal(goal.id) },
                          help: String(localized: "Delete"))
            }
            if !goal.objective.isEmpty {
                Text(goal.objective)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if !goal.platforms.isEmpty {
                    Text(goal.platforms.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let target = goal.targetPosts {
                    Text(String(localized: "Published \(progress?.publishedCount ?? 0) / \(target)"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(progress?.isComplete == true ? appAccent : .secondary)
                } else if let count = progress?.publishedCount, count > 0 {
                    Text(String(localized: "\(count) published"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let due = goal.dueDate {
                    Text(String(localized: "Due \(PromotionSummary.shortDate(due))"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let draftCount = progress?.draftCount, draftCount > 0 {
                    Text(String(localized: "\(draftCount) drafts"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 12)
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Accounts（自媒体 / 电商专项）

    @ViewBuilder
    private var accountsSection: some View {
        HStack(spacing: 5) {
            sectionHeader(String(localized: "Accounts"), count: store.accounts.count)
            Spacer()
            HoverIcon(systemName: "plus.circle", action: { isCreatingAccount = true },
                      help: String(localized: "New Account"))
        }
        if store.accounts.isEmpty {
            Text("Add the accounts you run (掘金 / 公众号 / 小红书 / store…) — the agent tracks their growth from here.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 6) {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
        }
    }

    private func accountRow(_ account: PromotionAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.domain.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(appAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(appAccent.opacity(0.12)))
                Text("\(account.platform) · \(account.handle)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let urlString = account.url, let link = URL(string: urlString) {
                    Link(destination: link) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Button(String(localized: "Record Metrics")) {
                    withAnimation(.transitionNormal) {
                        accountEditorID = accountEditorID == account.id ? nil : account.id
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HoverIcon(systemName: "trash", action: { store.removeAccount(account.id) },
                          help: String(localized: "Delete"))
            }
            HStack(spacing: 10) {
                if let latest = account.latest {
                    if let followers = latest.followers {
                        HStack(spacing: 3) {
                            Text(String(localized: "Followers"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("\(followers)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            if let growth = account.followersGrowth, growth != 0 {
                                Text(growth > 0 ? "+\(growth)" : "\(growth)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(growth > 0 ? appAccent : .orange)
                            }
                        }
                    }
                    Text(PromotionSummary.shortDate(latest.at))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(account.snapshots.count) " + String(localized: "snapshots"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No metrics yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            if !account.note.isEmpty {
                Text(account.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 10)
            }
            if accountEditorID == account.id {
                PromotionAccountMetricsEditor(account: account) {
                    accountEditorID = nil
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Drafts

    @ViewBuilder
    private var draftsSection: some View {
        let drafts = PromotionSummary.outstandingDrafts(posts: store.posts)
        if !drafts.isEmpty {
            sectionHeader(String(localized: "Drafts"), count: drafts.count)
            VStack(spacing: 6) {
                ForEach(drafts) { post in
                    draftRow(post)
                }
            }
        }
    }

    private func draftRow(_ post: PromotionPost) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(post.platform)
                        .font(.system(size: 10))
                        .foregroundStyle(appAccent)
                    Text(PromotionSummary.shortDate(post.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            HoverIcon(systemName: "doc.on.doc", action: { copyBody(post) },
                      help: String(localized: "Copy Body"))
            Button(String(localized: "Mark Published")) {
                publishingPost = post
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            HoverIcon(systemName: "trash", action: { store.removePost(post.id) },
                      help: String(localized: "Delete"))
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Published

    @ViewBuilder
    private var publishedSection: some View {
        let published = PromotionSummary.recentPublished(posts: store.posts, limit: 50)
        if !published.isEmpty {
            sectionHeader(String(localized: "Published"), count: published.count)
            VStack(spacing: 6) {
                ForEach(published) { post in
                    publishedRow(post)
                }
            }
        }
    }

    private func publishedRow(_ post: PromotionPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(post.platform)
                            .font(.system(size: 10))
                            .foregroundStyle(appAccent)
                        if let date = post.publishedAt {
                            Text(PromotionSummary.shortDate(date))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        if let urlString = post.url, let link = URL(string: urlString) {
                            Link(link.host() ?? urlString, destination: link)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                if !post.body.isEmpty {
                    HoverIcon(systemName: "doc.on.doc", action: { copyBody(post) },
                              help: String(localized: "Copy Body"))
                }
                Button(String(localized: "Record Metrics")) {
                    withAnimation(.transitionNormal) {
                        metricsEditorID = metricsEditorID == post.id ? nil : post.id
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HoverIcon(systemName: "trash", action: { store.removePost(post.id) },
                          help: String(localized: "Delete"))
            }
            metricsLine(post)
            if metricsEditorID == post.id {
                PromotionMetricsEditor(post: post) {
                    metricsEditorID = nil
                }
            }
        }
        .padding(10)
        .background(cardBackground)
    }

    @ViewBuilder
    private func metricsLine(_ post: PromotionPost) -> some View {
        if let m = post.metrics, !m.isEmpty {
            HStack(spacing: 10) {
                if let v = m.views {
                    HStack(spacing: 3) {
                        metric(String(localized: "Views"), v)
                        if let growth = post.viewsGrowth, growth != 0 {
                            Text(growth > 0 ? "+\(growth)" : "\(growth)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(growth > 0 ? appAccent : .orange)
                        }
                    }
                }
                if let l = m.likes { metric(String(localized: "Likes"), l) }
                if let c = m.comments { metric(String(localized: "Comments"), c) }
                if let at = m.collectedAt {
                    Text(PromotionSummary.shortDate(at))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 10)
        } else {
            Text("No metrics yet")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        }
    }

    // MARK: - Lessons（持续学习）

    private var lessonsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(String(localized: "Lessons"), count: store.lessons.count)
            HStack(spacing: 6) {
                TextField(String(localized: "Record a reusable lesson from the data…"), text: $lessonDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { addLesson() }
                Button(String(localized: "Add")) { addLesson() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(lessonDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if store.lessons.isEmpty {
                Text("Findings distilled during reviews land here and are fed back into the next drafts.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.lessons.sorted(by: { $0.createdAt > $1.createdAt })) { lesson in
                        lessonRow(lesson)
                    }
                }
            }
        }
    }

    private func lessonRow(_ lesson: PromotionLesson) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: lesson.source == .user ? "person.fill" : "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(lesson.text)
                    .font(.system(size: 11.5))
                    .lineLimit(3)
                HStack(spacing: 6) {
                    if let domain = lesson.domain {
                        Text(domain.label)
                            .font(.system(size: 9.5))
                            .foregroundStyle(appAccent)
                    }
                    if let platform = lesson.platform {
                        Text(platform)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(PromotionSummary.shortDate(lesson.createdAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            HoverIcon(systemName: "trash", action: { store.removeLesson(lesson.id) },
                      help: String(localized: "Delete"))
        }
        .padding(8)
        .background(cardBackground)
    }

    private func addLesson() {
        let text = lessonDraft
        lessonDraft = ""
        _ = store.addLesson(text: text, source: .user)
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func copyBody(_ post: PromotionPost) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(post.body, forType: .string)
    }
}

// MARK: - 新建目标（Sheet）

/// 目标编辑器：标题/说明/领域/平台/条数/截止。保存走 PromotionStore.addGoal。
private struct PromotionGoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var objective = ""
    @State private var domain: OperationDomain = .promotion
    @State private var platforms = ""
    @State private var hasTarget = false
    @State private var target = 2
    @State private var hasDue = false
    @State private var due = Date().addingTimeInterval(7 * 86_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Goal")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $domain) {
                    ForEach(OperationDomain.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField(String(localized: "Title"), text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Objective"), text: $objective)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Platforms"), text: $platforms)
                    .textFieldStyle(.roundedBorder)
                Toggle(String(localized: "Target posts"), isOn: $hasTarget)
                if hasTarget {
                    Stepper("\(target)", value: $target, in: 1...100)
                }
                Toggle(String(localized: "Due date"), isOn: $hasDue)
                if hasDue {
                    DatePicker("", selection: $due, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Add")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func save() {
        PromotionStore.shared.addGoal(
            title: title,
            objective: objective,
            domain: domain,
            platforms: platforms.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            targetPosts: hasTarget ? target : nil,
            dueDate: hasDue ? due : nil)
        dismiss()
    }
}

// MARK: - 新建账号（Sheet）

/// 账号建档：领域/平台/账号名/主页/备注。保存走 PromotionStore.saveAccount（upsert）。
private struct PromotionAccountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var domain: OperationDomain = .media
    @State private var platform = ""
    @State private var handle = ""
    @State private var url = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Account")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $domain) {
                    ForEach(OperationDomain.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField(String(localized: "Platform"), text: $platform)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Handle"), text: $handle)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Profile URL"), text: $url)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Note"), text: $note)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Add")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(platform.trimmingCharacters(in: .whitespaces).isEmpty
                              || handle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func save() {
        PromotionStore.shared.saveAccount(domain: domain, platform: platform,
                                           handle: handle, url: url, note: note)
        dismiss()
    }
}

// MARK: - 标记已发布（Sheet）

/// 把草稿标记为已发布：内容已在站点上线后调用，附上帖子 URL。
private struct PromotionPublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    let post: PromotionPost
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mark Published")
                .font(.system(size: 14, weight: .semibold))
            Text("[\(post.platform)] \(post.title)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField(String(localized: "Post URL"), text: $url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Mark Published")) {
                    PromotionStore.shared.markPublished(post.id, url: url)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - 帖子数据编辑（行内）

/// 已发帖的互动数据录入：浏览/点赞/评论三个数字（留空 = 该平台没这项）。
private struct PromotionMetricsEditor: View {
    let post: PromotionPost
    var onDone: () -> Void

    @State private var views = ""
    @State private var likes = ""
    @State private var comments = ""

    var body: some View {
        HStack(spacing: 8) {
            field(String(localized: "Views"), text: $views)
            field(String(localized: "Likes"), text: $likes)
            field(String(localized: "Comments"), text: $comments)
            Button(String(localized: "Save")) { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(String(localized: "Cancel")) { onDone() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.leading, 10)
        .onAppear {
            views = post.metrics?.views.map(String.init) ?? ""
            likes = post.metrics?.likes.map(String.init) ?? ""
            comments = post.metrics?.comments.map(String.init) ?? ""
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("–", text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 64)
        }
    }

    private func save() {
        PromotionStore.shared.recordMetrics(
            idOrURL: post.id.uuidString,
            views: Int(views.trimmingCharacters(in: .whitespaces)),
            likes: Int(likes.trimmingCharacters(in: .whitespaces)),
            comments: Int(comments.trimmingCharacters(in: .whitespaces)))
        onDone()
    }
}

// MARK: - 账号数据编辑（行内）

/// 账号快照录入：粉丝/近期浏览/近期点赞（留空 = 该平台没这项）。
private struct PromotionAccountMetricsEditor: View {
    let account: PromotionAccount
    var onDone: () -> Void

    @State private var followers = ""
    @State private var views = ""
    @State private var likes = ""

    var body: some View {
        HStack(spacing: 8) {
            field(String(localized: "Followers"), text: $followers)
            field(String(localized: "Views"), text: $views)
            field(String(localized: "Likes"), text: $likes)
            Button(String(localized: "Save")) { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(String(localized: "Cancel")) { onDone() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.leading, 10)
        .onAppear {
            followers = account.latest?.followers.map(String.init) ?? ""
            views = account.latest?.views.map(String.init) ?? ""
            likes = account.latest?.likes.map(String.init) ?? ""
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("–", text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 64)
        }
    }

    private func save() {
        PromotionStore.shared.recordAccountMetrics(
            idOrHandle: account.id.uuidString,
            followers: Int(followers.trimmingCharacters(in: .whitespaces)),
            views: Int(views.trimmingCharacters(in: .whitespaces)),
            likes: Int(likes.trimmingCharacters(in: .whitespaces)))
        onDone()
    }
}
