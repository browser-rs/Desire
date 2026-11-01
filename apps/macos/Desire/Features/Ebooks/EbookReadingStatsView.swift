import SwiftUI

/// 阅读统计（v0.8.35）：总时长/本周/连续天数/读完书数 + 近 14 天柱状 + 最多阅读。
struct EbookReadingStatsView: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var stats = ReadingStatsStore.shared
    @ObservedObject private var library = EbookLibraryStore.shared
    let onClose: () -> Void

    private var weekMinutes: Int { stats.weekSeconds / 60 }
    private var totalMinutes: Int { stats.totalSeconds / 60 }
    private var finishedCount: Int { library.books.filter { $0.progress >= 0.99 }.count }
    private var days: [(date: Date, seconds: Int)] { stats.recentDays(14) }
    private var maxSeconds: Int { max(1, days.map { $0.seconds }.max() ?? 1) }
    private var hasData: Bool { stats.totalSeconds > 0 || stats.totalPages > 0 }

    private var topBooks: [(book: Ebook, stat: ReadingStats.Book)] {
        let entries: [(book: Ebook, stat: ReadingStats.Book)] = library.books.compactMap { book in
            guard let stat = stats.stats.books[book.id.uuidString] else { return nil }
            return (book: book, stat: stat)
        }
        return Array(entries.sorted { $0.stat.seconds > $1.stat.seconds }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Reading Stats"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            Divider()
            if !hasData {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        metrics
                        chart
                        mostRead
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 640, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No reading stats yet"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metricCard(String(localized: "Total"), value: "\(totalMinutes)",
                       unit: String(localized: "min"))
            metricCard(String(localized: "This week"), value: "\(weekMinutes)",
                       unit: String(localized: "min"))
            metricCard(String(localized: "Day streak"), value: "\(stats.streakDays)",
                       unit: String(localized: "days"))
            metricCard(String(localized: "Finished"), value: "\(finishedCount)",
                       unit: String(localized: "books"))
        }
    }

    private func metricCard(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(appAccent)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.07)))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Last 14 days"))
                .font(.system(size: 11.5, weight: .semibold))
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(appAccent.opacity(day.seconds > 0 ? 0.85 : 0.15))
                            .frame(height: max(2, 70 * CGFloat(day.seconds) / CGFloat(maxSeconds)))
                        Text(verbatim: "\(Calendar.current.component(.day, from: day.date))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
    }

    private var mostRead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Most read"))
                .font(.system(size: 11.5, weight: .semibold))
            if topBooks.isEmpty {
                Text(String(localized: "No reading stats yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(topBooks, id: \.book.id) { entry in
                    HStack(spacing: 8) {
                        Text(entry.book.title)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: "\(entry.stat.seconds / 60) \(String(localized: "min"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}
