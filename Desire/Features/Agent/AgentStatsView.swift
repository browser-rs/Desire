import Charts
import SwiftUI

/// Token 使用统计面板：头条指标 + 活动热力图 + 每日趋势 + 模型用量。
///
/// 数据全部**从已存盘的会话派生**（`UsageStats`），与轨迹页同一个原则——不另存计数，
/// 所以统计和聊天记录永远对得上。两条必须说清的前提（写在页脚）：只有服务端上报过用量
/// 的调用才有数字，且**更早的历史对话没有记录**。
///
/// 布局要能应付**从 380pt 到 2000pt+ 的面板宽度**（用户："还要考虑窗口是可以拉宽的"）：
/// ① 内容限宽居中（`contentMaxWidth`）——不限宽的话热力图/图表会被拉到几千点、右边空一大片；
/// ② 每个区块自己按可用宽度换档：头条指标条换列数、热力图换格子大小与周数、
///    模型列表铺满剩余宽度（不再限宽）。
struct AgentStatsView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var conversationStore: ConversationStore
    /// 单价表：有配的话额外汇总一个金额（没配就只有 token，不显示 $0）。
    @ObservedObject var preference: AgentPreferenceStore
    var onBack: () -> Void

    /// 内容最大宽度：超过就居中留白。**不限宽不行**——热力图最多 53 周，拉到 2000pt 时
    /// 右边会空掉一大半（比对称留白更难看）。
    static let contentMaxWidth: CGFloat = 1100

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

    /// 会用到的模型（按 token 降序），超过 5 个时只画前 5 条线。
    private var seriesModels: [UsageModelStat] { Array(stats.models.prefix(5)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if stats.isEmpty {
                        emptyCard
                    } else {
                        headlineCard
                        activityCard
                        trendCard
                        modelsCard
                    }
                    footnote
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                // 限宽后再居中：面板很宽时内容居中、两边留白对称（而不是全挤在左边）。
                .frame(maxWidth: .infinity, alignment: .center)
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

    // MARK: - Cards

    /// 统一卡片：淡底 + 发丝描边 + 12pt 圆角（比轨迹页的回合卡略大，仪表盘用）。
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.5)
            )
    }

    /// 卡片内的标题行（图标 + 标题 + 右侧控件），参照仪表盘的分区头。
    private func cardHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: - Headline

    private struct StatItem {
        let title: LocalizedStringKey
        let value: String
        var tint: Color = .primary
        var help: String?
    }

    private var statItems: [StatItem] {
        var items: [StatItem] = [
            StatItem(title: "Total tokens", value: AgentUsage.formatTokens(stats.totalTokens)),
            StatItem(title: "Peak day", value: stats.peakDayTokens > 0
                     ? AgentUsage.formatTokens(stats.peakDayTokens) : "—"),
            StatItem(title: "Longest chat", value: durationText(stats.longestConversation)),
            StatItem(title: "Current streak", value: daysText(stats.currentStreak)),
            StatItem(title: "Longest streak", value: daysText(stats.longestStreak)),
        ]
        if let cost = stats.cost {
            items.append(StatItem(title: "Cost", value: AgentUsage.formatUSD(cost), tint: appAccent))
        } else if stats.unpricedTokens > 0 {
            items.append(StatItem(
                title: "Cost",
                value: String(localized: "price not set"),
                tint: .secondary,
                help: String(localized: "Token prices are not filled in yet — set them in Settings → Agent → Cost to see what this costs.")))
        }
        return items
    }

    /// 头条指标条：**一条卡片里按列数排开、列间竖分隔线**（参照仪表盘的观感）。
    /// 列数由可用宽度决定，所以宽面板是一行六格、窄面板自动变两行。
    private var headlineCard: some View {
        card {
            ViewThatFits(in: .horizontal) {
                statBar(columns: 6)
                statBar(columns: 4)
                statBar(columns: 3)
                statBar(columns: 2)
            }
        }
    }

    private func statBar(columns: Int) -> some View {
        let items = statItems
        let rows = stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(start + columns, items.count)])
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 0) {
                    ForEach(rows[rowIndex].indices, id: \.self) { index in
                        if index > 0 {
                            Divider().frame(height: 30)
                        }
                        statCell(rows[rowIndex][index])
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider().padding(.vertical, 10)
                }
            }
        }
        // 让 ViewThatFits 有"理想宽度"可比：每列至少 150pt 宽。
        .frame(minWidth: CGFloat(columns) * 150, alignment: .leading)
    }

    private func statCell(_ item: StatItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(item.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(item.help ?? "")
    }

    // MARK: - Empty state

    /// 一条用量都还没有时（本功能上线前的历史对话全是 0），别给用户看一张空仪表盘。
    private var emptyCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(appAccent.opacity(0.85))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No token usage recorded yet.")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Only calls whose service reports token usage are counted, so conversations from before this was recorded stay at 0.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if stats.turns > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(verbatim: "\(stats.turns)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                            Text("turns saved so far")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Activity heatmap

    private var activityCard: some View {
        card {
            cardHeader("Token activity", systemImage: "square.grid.3x3.fill")
            heatmap.padding(.top, 10)
        }
    }

    /// GitHub 风格格子：列 = 周、行 = 周一…周日。**按可用宽度换档**（格子 11→18、
    /// 周数 53→10），窄面板也填得满、宽面板也不会只在左边一小块。每档高度固定，
    /// 所以不需要测量（`ViewThatFits` 按理想宽度挑第一档放得下的）。
    private var heatmap: some View {
        ViewThatFits(in: .horizontal) {
            heatGrid(weeks: 53, cell: 18)
            heatGrid(weeks: 53, cell: 15)
            heatGrid(weeks: 44, cell: 14)
            heatGrid(weeks: 34, cell: 13)
            heatGrid(weeks: 30, cell: 12)
            heatGrid(weeks: 26, cell: 12)
            heatGrid(weeks: 22, cell: 12)
            heatGrid(weeks: 18, cell: 11)
            heatGrid(weeks: 14, cell: 11)
            heatGrid(weeks: 10, cell: 11)
        }
    }

    private func heatGrid(weeks: Int, cell: CGFloat) -> some View {
        let gap: CGFloat = 2
        let days = trailingWeeks(weeks)
        let maxTokens = max(1, days.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
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
        // 关键：理想宽度 = 网格真实宽度，`ViewThatFits` 才能按宽度挑档。
        .fixedSize()
    }

    private func cellView(_ day: UsageDayStat, maxTokens: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
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
            // 与上一个标签至少隔 3 列：月初恰好落在相邻两列时标签会撞在一起（"5月6月"）。
            if month != lastMonth, labels.last.map({ index / 7 - $0.index >= 3 }) ?? true {
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
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7  // 周一 = 0
        let weekStart = calendar.date(byAdding: .day, value: -weekday, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: weekStart) ?? weekStart
        return stats.dayRange(from: start, to: today)
    }

    // MARK: - Trend

    private var trendCard: some View {
        card {
            cardHeader("Daily tokens", systemImage: "chart.xyaxis.line") {
                HStack(spacing: 2) {
                    ForEach(Range.allCases) { option in
                        rangeButton(option)
                    }
                }
            }
            trendChart.padding(.top, 6)
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

    /// 每天一条线（按模型分色）。只画前 5 个模型——线太多就分不清了，
    /// 完整明细在下面的模型用量里。
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
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
        // 图例只列**画出来的**模型：Charts 是按 domain 出图例的，把全部模型都塞进
        // domain 会列出没画线的模型（第一版就是这样，7 个图例 5 条线）。
        .chartForegroundStyleScale(domain: trendDomain, range: trendColors)
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
        .frame(height: 170)
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
                out.append(TrendPoint(id: "\(day.id.timeIntervalSince1970)-\(model.id)",
                                      date: day.id,
                                      label: displayName(for: model.id),
                                      tokens: day.byModel[model.id] ?? 0))
            }
        }
        return out
    }

    // MARK: - Models

    private var modelsCard: some View {
        card {
            cardHeader("Models", systemImage: "chart.pie.fill")
            if stats.models.isEmpty {
                Text("No token usage recorded yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 22) {
                        donut.frame(width: 186, height: 186)
                        // 列表**铺满剩余宽度**（参照仪表盘：名字靠左、百分比靠右）。
                        modelList.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        donut.frame(width: 186, height: 186)
                        modelList
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var donut: some View {
        Chart {
            ForEach(stats.models) { model in
                SectorMark(
                    angle: .value("Tokens", model.tokens),
                    innerRadius: .ratio(0.64),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Model", displayName(for: model.id)))
            }
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleColors)
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 1) {
                Text(AgentUsage.formatTokens(stats.totalTokens))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(stats.models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(seriesColor(for: model.id))
                            .frame(width: 8, height: 8)
                        Text(displayName(for: model.id))
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 10)
                        Text(percentText(model))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(tokenDetail(model))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 15)
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

    /// 折线、环形图、列表圆点必须用**同一套固定配色**（Charts 默认按出现顺序自动配色，
    /// 会和列表里我们自己画的圆点对不上，所以显式给 domain/range 映射）。
    /// 环形图给全量（它画所有模型），折线图只给前 5 个（它只画前 5 条）。
    private var styleDomain: [String] { stats.models.map { displayName(for: $0.id) } }
    private var styleColors: [Color] { stats.models.map { seriesColor(for: $0.id) } }
    private var trendDomain: [String] { seriesModels.map { displayName(for: $0.id) } }
    private var trendColors: [Color] { seriesModels.map { seriesColor(for: $0.id) } }

    private var footnote: some View {
        Text("Derived from saved conversations. Only calls that reported usage count — conversations from before this was recorded show 0.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private func displayName(for key: String) -> String {
        key == UsageStats.subagentModelKey ? String(localized: "Subagent") : key
    }

    /// 图例/列表里的圆点颜色与 Charts 的配色必须一致，所以自己定义一份调色板
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
