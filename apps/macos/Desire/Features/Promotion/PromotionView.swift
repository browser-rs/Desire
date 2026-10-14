import AppKit
import SwiftUI

/// 推广工作台页（Agent 窗口侧栏「推广」目的地，自推广能力）。
/// 目标管理 + 草稿/已发记录 + 数据回收；数据全部来自 `PromotionStore`
/// （与 Agent 工具 promotionBrief/Save/Metrics、斜杠 /promote、桥 /promotion/*
/// 同源）。起草与发布本身走 Agent 对话（promotion 技能），这里不重复造编辑器。
struct PromotionView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = PromotionStore.shared
    var onBack: () -> Void

    @State private var isCreatingGoal = false
    @State private var publishingPost: PromotionPost?
    @State private var metricsEditorID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    goalsSection
                    draftsSection
                    publishedSection
                    if store.goals.isEmpty && store.posts.isEmpty {
                        emptyState
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isCreatingGoal) { PromotionGoalEditorSheet() }
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
            Text("Promotion")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
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
        .padding(.vertical, 40)
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
                if let v = m.views { metric(String(localized: "Views"), v) }
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

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
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

/// 目标编辑器：标题/说明/平台/条数/截止。保存走 PromotionStore.addGoal。
private struct PromotionGoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var objective = ""
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
            platforms: platforms.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            targetPosts: hasTarget ? target : nil,
            dueDate: hasDue ? due : nil)
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

// MARK: - 数据编辑（行内）

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
