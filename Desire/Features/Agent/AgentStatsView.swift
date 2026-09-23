import Charts
import SwiftUI

/// Token 使用统计面板：头条指标 + 活动热力图 + 每日趋势 + 模型用量。
///
/// 数据全部**从已存盘的会话派生**（`UsageStats`），与轨迹页同一个原则——不另存计数，
/// 所以统计和聊天记录永远对得上。两条必须说清的前提（写在页脚）：只有服务端上报过用量
/// 的调用才有数字，且**更早的历史对话没有记录**。
struct AgentStatsView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var conversationStore: ConversationStore
    /// 单价表：有配的话额外汇总一个金额（没配就只有 token，不显示 $0）。
    @ObservedObject var preference: AgentPreferenceStore
    var onBack: () -> Void

    /// 趋势图的窗口（天）。热力图固定看最近若干周，不受它影响。
    private enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: String(localized: "Last 7 days")
            case .month: String(localized: "Last 30 days")
            }
        }
    }

    @State private var stats: UsageStats
    @State private var range: Range = .week

    /// 数据在 **init 里就备好**：`.onAppear` 只挂在真实窗口上，离屏宿主（桥的
    /// `/panel/snapshot`）不触发它——那种情况下页面会是空的，看着像功能坏了。
    /// 顺带也没有"第一帧空"的闪动。
    init(conversationStore: ConversationStore,
         preference: AgentPreferenceStore,
         onBack: @escaping () -> Void) {
        self.conversationStore = conversationStore
        self.preference = preference
        self.onBack = onBack
        _stats = State(initialValue: UsageStats.derive(
            from: conversationStore.conversations,
            price: preference.usagePrice(for:)))
    }

    /// 会用到的模型（按 token 降序），超过 5 个时只画前 5 条线，其余在图例里合并。
    private var seriesModels: [UsageModelStat] { Array(stats.models.prefix(5)) }
    private var otherTokens: Int { stats.models.dropFirst(5).reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headlineSection
                    activitySection
                    trendSection
                    modelsSection
                    footnote
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }   // 从别的页切回来时刷新（首帧已在 init 备好）
        .onChange(of: conversationStore.conversations.count) { _, _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HoverIcon(systemName: "arrow.clockwise", action: reload, help: "Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    // MARK: - Headline

    private var headlineSection: some View {
        FlowRow(spacing: 6) {
            headline("Total tokens", AgentUsage.formatTokens(stats.totalTokens))
            headline("Peak day", stats.peakDayTokens > 0
                     ? AgentUsage.formatTokens(stats.peakDayTokens) : "—")
            headline("Longest chat", durationText(stats.longestConversation))
            headline("Current streak", daysText(stats.currentStreak))
            headline("Longest streak", daysText(stats.longestStreak))
            if let cost = stats.cost {
                headline("Cost", AgentUsage.formatUSD(cost), tint: appAccent)
            }
            if stats.totalTokens > 0, stats.cost == nil, stats.unpricedTokens > 0 {
                headline("Cost", String(localized: "price not set"), tint: .secondary)
            }
        }
    }

    private func headline(_ title: LocalizedStringKey, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Activity heatmap

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Token activity")
            heatmap
        }
    }

    /// GitHub 风格格子：**列 = 周、行 = 周一…周日**，颜色深浅按当天 token。
    /// 格子宽固定（11pt），能显示几周由可用宽度决定——面板可拖宽拖窄，格子跟着变会
    /// 一直在抖，所以宁可变"看多少周"。
    private var heatmap: some View {
        GeometryReader { geometry in
            let cell: CGFloat = 11
            let gap: CGFloat = 2
            let weeks = min(53, max(8, Int((geometry.size.width + gap) / (cell + gap))))
            let days = trailingWeeks(weeks)
            let maxTokens = max(1, days.map(\.tokens).max() ?? 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(stride(from: 0, to: days.count, by: 7)), id: \.self) { start in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = start + row
                                if index < days.count {
                                    cellView(days[index], maxTokens: maxTokens, size: cell)
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
                monthLabels(days: days, cell: cell, gap: gap)
            }
        }
        .frame(height: 7 * 11 + 6 * 2 + 16)
    }

    private func cellView(_ day: UsageDayStat, maxTokens: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(heatColor(tokens: day.tokens, maxTokens: maxTokens))
            .frame(width: size, height: size)
            .help(heatHelp(day))
    }

    /// 四档深浅（参照 GitHub 的观感），0 一律是最浅的一档而不是透明——
    /// 空格子也要能看见"这天在统计范围内"。
    private func heatColor(tokens: Int, maxTokens: Int) -> Color {
        guard tokens > 0 else { return Color.secondary.opacity(0.10) }
        let ratio = Double(tokens) / Double(maxTokens)
        switch ratio {
        case ..<0.25: return appAccent.opacity(0.30)
        case ..<0.5: return appAccent.opacity(0.50)
        case ..<0.75: return appAccent.opacity(0.72)
        default: return appAccent
        }
    }

    private func heatHelp(_ day: UsageDayStat) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var text = formatter.string(from: day.id)
        text += String(format: " · %@ tokens", AgentUsage.formatTokens(day.tokens))
        text += String(format: " · %d ", day.turns) + String(localized: "turns")
        return text
    }

    /// 月份标签：只在**月份变化的那一列**上打，避免每列都写。
    private func monthLabels(days: [UsageDayStat], cell: CGFloat, gap: CGFloat) -> some View {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        var labels: [(index: Int, text: String)] = []
        var lastMonth = -1
        for (index, day) in days.enumerated() where index % 7 == 0 {
            let month = Calendar.current.component(.month, from: day.id)
            if month != lastMonth {
                labels.append((index / 7, formatter.string(from: day.id)))
                lastMonth = month
            }
        }
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 12)
            ForEach(labels, id: \.index) { label in
                Text(label.text)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(x: CGFloat(label.index) * (cell + gap))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 最近 `weeks` 周（周一对齐、到今天为止）的逐日用量。
    private func trailingWeeks(_ weeks: Int) -> [UsageDayStat] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 找到本周的周一（firstWeekday 依地区不同，按 ISO 用周一 → 行序稳定）
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7  // 周一 = 0
        let weekStart = calendar.date(byAdding: .day, value: -weekday, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: weekStart) ?? weekStart
        return stats.dayRange(from: start, to: today)
    }

    // MARK: - Trend

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Daily tokens")
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Range.allCases) { option in
                        rangeButton(option)
                    }
                }
            }
            trendChart
        }
    }

    private func rangeButton(_ option: Range) -> some View {
        Button {
            range = option
        } label: {
            Text(option.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(range == option ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(range == option ? AnyShapeStyle(appAccent.opacity(0.18)) : AnyShapeStyle(Color.clear))
                )
        }
        .buttonStyle(.plain)
    }

    /// 每天一条线（按模型分色）。只画前 5 个模型，其余在图注里写明还有多少——
    /// 线太多就分不清了，而完整明细在下面的模型用量里。
    private var trendChart: some View {
        let days = stats.recentDays(range.rawValue)
        let points = trendPoints(days: days)
        return Chart {
            ForEach(points, id: \.id) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(by: .value("Model", point.label))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleColors)
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(AgentUsage.formatTokens(tokens)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(shortDate(date)).font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 160)
    }

    private struct TrendPoint: Identifiable {
        let id: String
        let date: Date
        let label: String
        let tokens: Int
    }

    private func trendPoints(days: [UsageDayStat]) -> [TrendPoint] {
        var out: [TrendPoint] = []
        for day in days {
            for model in seriesModels {
                let tokens = day.byModel[model.id] ?? 0
                out.append(TrendPoint(id: "\(day.id.timeIntervalSince1970)-\(model.id)",
                                      date: day.id,
                                      label: displayName(for: model.id),
                                      tokens: tokens))
            }
        }
        return out
    }

    // MARK: - Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Models")
            if stats.models.isEmpty {
                Text("No token usage recorded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        donut.frame(width: 170, height: 170)
                        // 列表别跟着面板一起拉满：宽面板下名字和百分比会被拉成天各一方。
                        modelList.frame(maxWidth: 420, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        donut.frame(width: 170, height: 170)
                        modelList
                    }
                }
            }
        }
    }

    private var donut: some View {
        Chart {
            ForEach(stats.models) { model in
                SectorMark(
                    angle: .value("Tokens", model.tokens),
                    innerRadius: .ratio(0.62),
                    angularInset: 1
                )
                .cornerRadius(2)
                .foregroundStyle(by: .value("Model", displayName(for: model.id)))
            }
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleColors)
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 1) {
                Text(AgentUsage.formatTokens(stats.totalTokens))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("tokens")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(stats.models) { model in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(seriesColor(for: model.id))
                            .frame(width: 7, height: 7)
                        Text(displayName(for: model.id))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(percentText(model))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(tokenDetail(model))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 13)
                }
            }
        }
    }

    private func percentText(_ model: UsageModelStat) -> String {
        guard stats.totalTokens > 0 else { return "0%" }
        let percent = Double(model.tokens) / Double(stats.totalTokens) * 100
        return percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    private func tokenDetail(_ model: UsageModelStat) -> String {
        var text = String(format: "%@ tokens", AgentUsage.formatTokens(model.tokens))
        if let cost = model.cost { text += String(format: " · %@", AgentUsage.formatUSD(cost)) }
        return text
    }

    // MARK: - Helpers

    private var footnote: some View {
        Text("Derived from saved conversations. Only calls that reported usage count — conversations from before this was recorded show 0.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 折线、环形图、列表圆点必须用**同一套固定配色**（Charts 默认按出现顺序自动配色，
    /// 会和列表里我们自己画的圆点对不上，所以显式给 domain/range 映射）。
    private var styleDomain: [String] { stats.models.map { displayName(for: $0.id) } }
    private var styleColors: [Color] { stats.models.map { seriesColor(for: $0.id) } }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func displayName(for key: String) -> String {
        key == UsageStats.subagentModelKey ? String(localized: "Subagent") : key
    }

    /// 图例/列表里的圆点颜色与 Charts 的自动配色必须一致，所以自己定义一份调色板
    /// （按 `stats.models` 的顺序取）。
    private func seriesColor(for key: String) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .orange, .pink, .teal, .yellow]
        guard let index = stats.models.firstIndex(where: { $0.id == key }) else { return .secondary }
        return palette[index % palette.count]
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }

    /// 超过一天要给"天"——只按小时算会得到 "600 小时 5 分钟" 这种没法读的数。
    private func durationText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        if seconds >= 86_400 {
            formatter.allowedUnits = [.day, .hour]
        } else if seconds >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
        } else {
            formatter.allowedUnits = [.minute]
        }
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 0)) ?? "—"
    }

    private func daysText(_ count: Int) -> String {
        String(format: "%d ", count) + String(localized: "days")
    }

    private func reload() {
        stats = UsageStats.derive(from: conversationStore.conversations,
                                  price: preference.usagePrice(for:))
    }
}
