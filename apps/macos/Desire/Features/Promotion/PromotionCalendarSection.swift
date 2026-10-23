import SwiftUI

/// 运营日历（v0.8.3）：月视图 + 今日队列 + 草稿改期入口。
/// 数据来自 `PromotionCalendar`（纯逻辑），本视图只渲染与转发动作。
struct PromotionCalendarSection: View {
    @ObservedObject private var store = PromotionStore.shared
    @Environment(\.appAccent) private var appAccent
    let onSendToAgent: ((String) -> Void)?

    @State private var month = Date()
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { Calendar.current }
    private var entries: [PromotionCalendar.Entry] {
        PromotionCalendar.entries(posts: store.posts, campaigns: store.campaigns, now: Date())
    }
    private var queue: [PromotionCalendar.Entry] {
        PromotionCalendar.todayQueue(entries, now: Date())
    }
    private var grid: [PromotionCalendar.Day] {
        PromotionCalendar.monthGrid(containing: month, entries: entries, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !queue.isEmpty { todayQueue }
            weekdayHeader
            monthGrid
            dayDetail
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appAccent)
            Text(String(localized: "Calendar"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                month = calendar.date(byAdding: .month, value: -1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Previous month"))
            Button {
                month = Date()
                selectedDay = calendar.startOfDay(for: Date())
            } label: {
                Text(Self.monthTitle(month))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Back to this month"))
            Button {
                month = calendar.date(byAdding: .month, value: 1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Next month"))
        }
    }

    private var todayQueue: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                Text(String(localized: "Today"))
                    .font(.system(size: 11, weight: .semibold))
                let overdue = queue.filter(\.overdue).count
                if overdue > 0 {
                    Text(String(localized: "\(overdue) overdue"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            ForEach(queue.prefix(6)) { entry in
                queueRow(entry)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private func queueRow(_ entry: PromotionCalendar.Entry) -> some View {
        HStack(spacing: 5) {
            Image(systemName: entry.kind == .draft ? "square.and.pencil" : "checklist")
                .font(.system(size: 9))
                .foregroundStyle(entry.overdue ? .red : .secondary)
            Text(entry.title)
                .font(.system(size: 10.5))
                .lineLimit(1)
            if !entry.platform.isEmpty {
                Text(entry.platform)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 2)
            if let postID = entry.postID {
                Menu {
                    Button(String(localized: "Tomorrow")) {
                        store.reschedule(postID: postID, to: calendar.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())))
                    }
                    Button(String(localized: "Next week")) {
                        store.reschedule(postID: postID, to: calendar.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())))
                    }
                    Button(String(localized: "Clear date")) {
                        store.reschedule(postID: postID, to: nil)
                    }
                } label: {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 9))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "Reschedule"))
            }
            if let onSendToAgent {
                Button {
                    onSendToAgent(prompt(for: entry))
                } label: {
                    Image(systemName: "paperplane").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .help(String(localized: "Send to agent"))
            }
        }
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        return HStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            ForEach(grid) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: PromotionCalendar.Day) -> some View {
        let selected = calendar.isDate(day.date, inSameDayAs: selectedDay)
        let kinds = Array(Set(day.entries.map(\.kind))).sorted()
        return Button {
            selectedDay = calendar.startOfDay(for: day.date)
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day.date))")
                    .font(.system(size: 9.5, weight: day.isToday ? .bold : .regular))
                    .foregroundStyle(day.isInMonth ? (day.isToday ? appAccent : .primary)
                                                   : Color.secondary.opacity(0.45))
                HStack(spacing: 2) {
                    ForEach(Array(kinds.prefix(3).enumerated()), id: \.offset) { _, kind in
                        Circle().fill(color(for: kind)).frame(width: 3, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? appAccent.opacity(0.16)
                                   : (day.isToday ? appAccent.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(selected ? appAccent.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .help("\(day.entries.count) " + String(localized: "entry(ies)"))
    }

    @ViewBuilder
    private var dayDetail: some View {
        let dayEntries = entries.filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.dayTitle(selectedDay))
                    .font(.system(size: 10.5, weight: .semibold))
                Text("\(dayEntries.count)")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            if dayEntries.isEmpty {
                Text(String(localized: "Nothing scheduled."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(dayEntries) { entry in
                    dayRow(entry)
                }
            }
        }
    }

    private func dayRow(_ entry: PromotionCalendar.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon(for: entry.kind))
                .font(.system(size: 9.5))
                .foregroundStyle(color(for: entry.kind))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 10.5, weight: entry.kind == .published ? .regular : .medium))
                    .strikethrough(entry.kind == .published || entry.done, color: .secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if !entry.platform.isEmpty {
                        Text(entry.platform)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if entry.overdue {
                        Text(String(localized: "overdue"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    if entry.kind == .runbook, let stepID = entry.stepID,
                       let campaignID = entry.campaignID, !entry.done {
                        Button(String(localized: "Mark done")) {
                            _ = store.markRunbookStep(campaignID, stepID: stepID, done: true)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(appAccent)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 2)
            if let onSendToAgent {
                Button {
                    onSendToAgent(prompt(for: entry))
                } label: {
                    Image(systemName: "paperplane").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .help(String(localized: "Send to agent"))
            }
        }
    }

    // MARK: - Helpers

    private func prompt(for entry: PromotionCalendar.Entry) -> String {
        switch entry.kind {
        case .draft:
            return "按运营日历推进草稿「\(entry.title)」（\(entry.platform)）：先检查平台适配/预检，把最终稿贴给我确认；我点头后再发布。"
        case .runbook:
            return "执行运营 Runbook 步骤「\(entry.title)」（\(entry.platform)）：需要发布/回复的动作先问我；数据类步骤直接采并汇报。"
        case .campaign:
            return "检查运营战役「\(entry.title)」：看排期、草稿与数据，列出今天该做的事；发布/回复先问我。"
        case .published:
            return "回访已发内容「\(entry.title)」：采集最新数据并检查互动台账。"
        }
    }

    private func icon(for kind: PromotionCalendar.Kind) -> String {
        switch kind {
        case .campaign: "flag.checkered"
        case .draft: "square.and.pencil"
        case .runbook: "checklist"
        case .published: "paperplane.fill"
        }
    }

    private func color(for kind: PromotionCalendar.Kind) -> Color {
        switch kind {
        case .campaign: appAccent
        case .draft: .orange
        case .runbook: .blue
        case .published: .green
        }
    }

    private static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMM")
        return formatter.string(from: date)
    }

    private static func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return formatter.string(from: date)
    }
}
