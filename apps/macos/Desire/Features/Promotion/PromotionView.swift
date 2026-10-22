import AppKit
import Charts
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
    /// 点按「让智能体干活」的出口（Agent 窗口传入 store.sendMessage；
    /// 独立预览/桥快照可为 nil —— 按钮自动隐藏）。
    var onSendToAgent: ((String) -> Void)? = nil

    @State private var isCreatingGoal = false
    @State private var isCreatingCampaign = false
    @State private var isCreatingAccount = false
    @State private var publishingPost: PromotionPost?
    @State private var metricsEditorID: UUID?
    @State private var accountEditorID: UUID?
    @State private var lessonDraft = ""
    @State private var reportCopied = false
    /// 发布准备结果（填了 composer 后提示"还需你自己按发布"）。
    @State private var publishNote: String?
    @State private var isAddingMentionSource = false
    @State private var mentionQuery = "Desire"
    @State private var mentionScanning = false
    @State private var mentionNote: String?
    /// 自动化开关的刷新源（定时任务增删时重绘）。
    @ObservedObject private var scheduler = AgentScheduler.shared
    @ObservedObject private var playbookStore = PlaybookStore.shared
    @State private var runningPlaybook: Playbook?
    @State private var editingPlaybook: Playbook?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    goalsSection
                    campaignsSection
                    mentionRadarSection
                    accountsSection
                    interactionsSection
                    automationSection
                    playbooksSection
                    ideasSection
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
        .sheet(isPresented: $isCreatingCampaign) { PromotionCampaignEditorSheet() }
        .sheet(item: $runningPlaybook) { playbook in
            PlaybookRunSheet(playbook: playbook) { prompt in
                onSendToAgent?(prompt)
            }
        }
        .sheet(item: $editingPlaybook) { playbook in
            PlaybookEditorSheet(playbook: playbook) { updated in
                _ = playbookStore.save(updated)
            }
        }
        .sheet(isPresented: $isCreatingAccount) { PromotionAccountEditorSheet() }
        .sheet(isPresented: $isAddingMentionSource) { MentionSourceEditorSheet() }
        .sheet(item: $publishingPost) { post in
            PromotionPublishSheet(post: post)
        }
        .alert(String(localized: "Prepare to publish"),
               isPresented: Binding(get: { publishNote != nil },
                                    set: { if !$0 { publishNote = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { publishNote = nil }
        } message: {
            Text(publishNote ?? "")
        }
        .onAppear {
            if mentionQuery == "Desire" { mentionQuery = store.mentionQuery }
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
            HoverIcon(systemName: reportCopied ? "checkmark.circle" : "doc.text",
                      action: copyReport,
                      help: String(localized: "Copy weekly report"))
            HoverIcon(systemName: "megaphone.fill", action: { isCreatingCampaign = true },
                      help: String(localized: "New Campaign"))
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
            Text("Tell the agent to run your operations — goals, accounts, content and lessons all live here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// 复制运营周报（Markdown）到剪贴板——与 promotionReport 工具、桥 /promotion/report 同源。
    private func copyReport() {
        let markdown = PromotionReport.markdown(
            goals: store.goals, posts: store.posts,
            accounts: store.accounts, lessons: store.lessons,
            interactions: store.interactions)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        withAnimation(.transitionNormal) { reportCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.transitionNormal) { reportCopied = false }
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

    // MARK: - Campaigns（v0.8.2）

    @ViewBuilder
    private var campaignsSection: some View {
        if !store.campaigns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader(String(localized: "Campaigns"), count: store.campaigns.count)
                    Spacer()
                    Button(String(localized: "New Campaign")) { isCreatingCampaign = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(appAccent)
                }
                ForEach(store.campaigns) { campaign in
                    campaignRow(campaign)
                }
            }
        }
    }

    private func campaignRow(_ campaign: PromotionCampaign) -> some View {
        let linked = store.posts(inCampaign: campaign.id)
        let drafts = linked.filter { $0.status == .draft }
        let published = linked.filter { $0.status == .published }
        let next = drafts.compactMap(\.plannedFor).min()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.title)
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 6) {
                    Text(campaign.platforms.joined(separator: " / "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let version = campaign.version, !version.isEmpty {
                        Text("v\(version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("\(published.count)/\(linked.count) " + String(localized: "published")
                     + " · \(drafts.count) " + String(localized: "draft(s)")
                     + (next.map { " · " + String(localized: "next") + " " + PromotionSummary.shortDate($0) } ?? ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if !campaign.objective.isEmpty {
                    Text(campaign.objective)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(PromotionCampaign.Status.allCases, id: \.self) { status in
                    Button(status.label) {
                        store.updateCampaignStatus(campaign.id, status: status)
                    }
                    .disabled(campaign.status == status)
                }
                if let onSendToAgent {
                    Divider()
                    Button(String(localized: "Ask Agent to continue…")) {
                        onSendToAgent("继续推进运营战役「\(campaign.title)」：先看这条战役下的草稿与目标，按平台逐条检查/润色待审内容；任何发布或回复都必须先问我。")
                    }
                }
                Divider()
                Button(String(localized: "Delete campaign"), role: .destructive) {
                    store.removeCampaign(campaign.id)
                }
            } label: {
                Text(campaign.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Mention Radar（v0.8.2）

    @ViewBuilder
    private var mentionRadarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionHeader(String(localized: "Mention Radar"), count: store.mentionSources.count)
                Spacer()
                Menu(String(localized: "Add Source")) {
                    ForEach(MentionSource.presets) { preset in
                        Button(preset.name) {
                            _ = store.addMentionSource(name: preset.name,
                                                       platform: preset.platform,
                                                       searchURL: preset.searchURL)
                        }
                    }
                    Divider()
                    Button(String(localized: "Custom…")) { isAddingMentionSource = true }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10.5))
            }
            if store.mentionSources.isEmpty {
                Text(String(localized: "Add a search or community entry to watch for mentions. Hits land in the interaction ledger — replies are always drafted first."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.mentionSources) { source in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { store.setMentionSourceEnabled(source.id, enabled: $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(source.searchURL)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        HoverIcon(systemName: "trash", action: {
                            store.removeMentionSource(source.id)
                        }, help: String(localized: "Remove source"))
                    }
                    .padding(8)
                    .background(cardBackground)
                }
            }
            HStack(spacing: 8) {
                TextField(String(localized: "Keyword"), text: $mentionQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button(mentionScanning ? String(localized: "Scanning…") : String(localized: "Scan Now")) {
                    scanMentions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(mentionScanning || store.enabledMentionSources.isEmpty
                          || mentionQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                if let last = store.lastMentionScanAt {
                    Text(String(localized: "Last scan \(PromotionSummary.shortDate(last))"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            if let mentionNote {
                Text(mentionNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scanMentions() {
        let query = mentionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        store.setMentionQuery(query)
        mentionScanning = true
        mentionNote = nil
        Task { @MainActor in
            let result = await MentionRadarScanner.scan(
                query: query, sources: store.mentionSources)
            mentionScanning = false
            mentionNote = String(localized: "Scanned \(result.scannedSources) source(s), added \(result.added) new mention(s).")
                + (result.errors.isEmpty ? "" : " · " + result.errors.prefix(2).joined(separator: "; "))
        }
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
                    let trend = accountTrendPoints(account)
                    if trend.count >= 2 {
                        PromotionSparkline(points: trend, tint: appAccent)
                    }
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

    // MARK: - Interactions（互动台账）

    @ViewBuilder
    private var interactionsSection: some View {
        let inbox = PromotionSummary.inbox(store.interactions)
        let pending = store.pendingInteractionCount
        sectionHeader(String(localized: "Interactions"),
                      count: pending > 0 ? pending : store.interactions.count)
        if store.interactions.isEmpty {
            Text("Comments and inquiries the agent finds land here — review replies before they go out.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 4) {
                ForEach(inbox.prefix(30)) { item in
                    interactionRow(item)
                }
            }
        }
    }

    private func interactionRow(_ item: PromotionInteraction) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: interactionIcon(item.kind))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.platform)
                        .font(.system(size: 10))
                        .foregroundStyle(appAccent)
                    Text(item.author)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    statusChip(item.status)
                    Spacer(minLength: 0)
                }
                Text(item.text)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                if let post = item.postTitle, !post.isEmpty {
                    Text("「\(post)」")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let reply = item.reply, !reply.isEmpty {
                    Text(String(localized: "Reply") + "：" + reply)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.status == .pending, onSendToAgent != nil {
                HoverIcon(systemName: "paperplane", action: {
                    var ask = "处理互动台账里的这条（id=\(item.id.uuidString)）：[\(item.platform)] \(item.author) 说「\(item.text)」"
                    if let url = item.url { ask += "（\(url)）" }
                    ask += "。拟一条回复贴给我确认；我点头后发出去，再用 promotionInteractionReply 标记 replied；我不想回的标 ignored。"
                    onSendToAgent?(ask)
                }, help: String(localized: "Reply with the agent"))
                HoverIcon(systemName: "xmark.circle", action: {
                    _ = store.replyInteraction(id: item.id, reply: nil, status: .ignored)
                }, help: String(localized: "Mark ignored"))
            }
            HoverIcon(systemName: "trash", action: { store.removeInteraction(item.id) },
                      help: String(localized: "Delete"))
        }
        .padding(8)
        .background(cardBackground)
    }

    private func interactionIcon(_ kind: PromotionInteraction.Kind) -> String {
        switch kind {
        case .comment: return "bubble.left"
        case .dm: return "envelope"
        case .mention: return "at"
        case .review: return "star"
        }
    }

    private func statusChip(_ status: PromotionInteraction.Status) -> some View {
        let label: String
        let color: Color
        switch status {
        case .pending: label = String(localized: "Pending reply"); color = .orange
        case .replied: label = String(localized: "Replied"); color = .green
        case .ignored: label = String(localized: "Ignored"); color = .secondary
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Automation（持续学习闭环的自动部分）

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(String(localized: "Automation"), count: 0)
            automationRow(.dailyCollect,
                          icon: "sun.max",
                          label: String(localized: "Daily collection"),
                          detail: String(localized: "21:00 daily — refresh account/post numbers so growth curves stay continuous"))
            automationRow(.weeklyReview,
                          icon: "calendar.badge.clock",
                          label: String(localized: "Weekly review"),
                          detail: String(localized: "Monday 10:00 — compare growth, distil lessons, plan next week"))
            automationRow(.dailyTopics,
                          icon: "flame",
                          label: String(localized: "Daily topic scout"),
                          detail: String(localized: "09:30 daily — scan hot lists and stock 3-5 ideas into the idea backlog"))
            automationRow(.mentionScan,
                          icon: "dot.radiowaves.left.and.right",
                          label: String(localized: "Mention radar (daily)"),
                          detail: String(localized: "09:45 daily — scan the sources above for new mentions (no model, no window needed)"))
        }
    }

    private func automationRow(_ kind: PromotionAutomation.Kind, icon: String,
                               label: String, detail: String) -> some View {
        let isOn = PromotionAutomation.isScheduled(kind)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? appAccent : Color.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { PromotionAutomation.isScheduled(kind) },
                set: { on in
                    if on { PromotionAutomation.schedule(kind) }
                    else { PromotionAutomation.remove(kind) }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Playbooks（v0.8.2）

    @ViewBuilder
    private var playbooksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionHeader(String(localized: "Playbooks"), count: playbookStore.playbooks.count)
                Spacer()
                Button(String(localized: "New")) {
                    editingPlaybook = Playbook(name: "", instructions: "")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(appAccent)
                Menu(String(localized: "Add Template")) {
                    ForEach(PlaybookTemplate.all(version: WhatsNewStore.shared.versionName)) { template in
                        Button(template.name) {
                            _ = playbookStore.save(template)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 10.5))
            }
            if playbookStore.playbooks.isEmpty {
                Text(String(localized: "No playbooks — add a template or ask the agent to create one."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playbookStore.playbooks) { playbook in
                    HStack(spacing: 8) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(playbook.name)
                                .font(.system(size: 11.5, weight: .medium))
                            if !playbook.summary.isEmpty {
                                Text(playbook.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button(String(localized: "Run")) {
                            runningPlaybook = playbook
                        }
                        .controlSize(.small)
                        .disabled(onSendToAgent == nil)
                        Menu {
                            if let task = playbookStore.scheduledTask(for: playbook) {
                                Text(String(localized: "Scheduled: \(task.recurrenceText)"))
                                Button(String(localized: "Remove schedule"), role: .destructive) {
                                    playbookStore.unschedule(playbook)
                                }
                                Divider()
                            }
                            Button(String(localized: "Daily at 09:00")) {
                                playbookStore.schedule(playbook, recurrence: .daily(hour: 9, minute: 0))
                            }
                            Button(String(localized: "Weekly on Monday 10:00")) {
                                playbookStore.schedule(playbook, recurrence: .weekly(weekday: 2, hour: 10, minute: 0))
                            }
                        } label: {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!PlaybookRun.missingRequired(playbook, values: [:]).isEmpty)
                        .help("Schedule with default parameter values")
                        HoverIcon(systemName: "pencil", action: {
                            editingPlaybook = playbook
                        }, help: String(localized: "Edit playbook"))
                        HoverIcon(systemName: "trash", action: {
                            playbookStore.delete(playbook.id)
                        }, help: String(localized: "Delete playbook"))
                    }
                    .padding(8)
                    .background(cardBackground)
                }
            }
        }
    }

    // MARK: - Ideas（选题库）

    @ViewBuilder
    private var ideasSection: some View {
        let ideas = PromotionSummary.ideas(posts: store.posts)
        if !ideas.isEmpty {
            sectionHeader(String(localized: "Ideas"), count: ideas.count)
            VStack(spacing: 4) {
                ForEach(ideas) { idea in
                    ideaRow(idea)
                }
            }
        }
    }

    private func ideaRow(_ idea: PromotionPost) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(idea.title)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(idea.platform)
                .font(.system(size: 10))
                .foregroundStyle(appAccent)
            if onSendToAgent != nil {
                HoverIcon(systemName: "square.and.pencil", action: {
                    onSendToAgent?("用 promotion 技能把选题「\(idea.title)」（\(idea.platform)）起草成草稿（先给我看全文，别发布）——写成后 promotionSave 用 id 更新这个选题为 draft。")
                }, help: String(localized: "Draft this idea with the agent"))
            }
            HoverIcon(systemName: "doc.on.doc", action: { copyTitle(idea) },
                      help: String(localized: "Copy"))
            HoverIcon(systemName: "trash", action: { store.removePost(idea.id) },
                      help: String(localized: "Delete"))
        }
        .padding(8)
        .background(cardBackground)
    }

    private func copyTitle(_ post: PromotionPost) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(post.title, forType: .string)
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
                    if let variant = post.variantLabel {
                        Text(variant)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .foregroundStyle(.secondary)
                    }
                    Text(PromotionSummary.shortDate(post.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let planned = post.plannedFor {
                        Text(String(localized: "Planned \(PromotionSummary.shortDate(planned))"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 4)
            if onSendToAgent != nil {
                HoverIcon(systemName: "paperplane", action: {
                    onSendToAgent?("把草稿「\(post.title)」（\(post.platform)）按 promotion 流程推进：先给我确认最终稿，我点头后发布；发布成功用 promotionSave 更新为 published 并带上 URL。")
                }, help: String(localized: "Let the agent publish this draft"))
            }
            HoverIcon(systemName: "doc.on.doc", action: { copyBody(post) },
                      help: String(localized: "Copy Body"))
            HoverIcon(systemName: "safari", action: { prepare(post) },
                      help: String(localized: "Open the composer and fill this draft (you press Publish)"))
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
                        if let variant = post.variantLabel {
                            Text(variant)
                                .font(.system(size: 9.5, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .foregroundStyle(.secondary)
                        }
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
                if onSendToAgent != nil {
                    HoverIcon(systemName: "arrow.clockwise", action: {
                        let target = post.url ?? "帖子页"
                        onSendToAgent?("刷新帖子「\(post.title)」的数据：回访 \(target)（有适配包用视图，否则 getPageText）读浏览/点赞/评论，用 promotionMetrics 写回。")
                    }, help: String(localized: "Ask the agent to refresh metrics"))
                }
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
        if let m = post.latestMetrics, !m.isEmpty {
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
                    let trend = postTrendPoints(post)
                    if trend.count >= 2 {
                        PromotionSparkline(points: trend, tint: appAccent)
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

    /// 发布准备：开 composer 并填入草稿；最终发布按钮仍由用户按。
    private func prepare(_ post: PromotionPost) {
        publishNote = String(localized: "Opening the composer…")
        Task { @MainActor in
            let result = await PromotionPublishHelper.prepare(post: post)
            publishNote = result.message
        }
    }

    private func accountTrendPoints(_ account: PromotionAccount) -> [(Date, Double)] {
        account.snapshots.compactMap { snapshot in
            snapshot.followers.map { (snapshot.at, Double($0)) }
        }
    }

    private func postTrendPoints(_ post: PromotionPost) -> [(Date, Double)] {
        post.metricHistory.compactMap { snapshot in
            snapshot.views.map { (snapshot.at, Double($0)) }
        }
    }
}

// MARK: - 迷你趋势（账号粉丝 / 帖子浏览的快照序列）

private struct PromotionSparkline: View {
    let points: [(Date, Double)]
    var tint: Color

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("t", point.0), y: .value("v", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in plot.background(Color.clear) }
        .frame(width: 68, height: 20)
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
