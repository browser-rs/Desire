import SwiftUI

/// 历史洞察（v0.8.25）：总访问 / 站点数 / Top 站点 / 24 小时 / 最近 7 天。
/// 数据由 HistoryInsightsBuilder 派生（与桥 `/history/insights` 同源），
/// 本视图只负责渲染。
struct HistoryInsightsView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    let entries: [HistoryEntry]

    private var insights: HistoryInsights {
        HistoryInsightsBuilder.build(from: entries)
    }

    var body: some View {
        let data = insights
        VStack(spacing: 0) {
            header(data)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topSitesSection(data.topSites)
                    hourlySection(data.hourly)
                    weekSection(data.lastSevenDays)
                }
                .padding(14)
            }
        }
        .frame(width: 460, height: 520)
    }

    private func header(_ data: HistoryInsights) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text(String(localized: "History Insights"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(String(localized: "\(data.totalVisits) visits · \(data.uniqueSites) sites"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button(String(localized: "Close")) { dismiss() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func topSitesSection(_ sites: [HistoryInsights.Site]) -> some View {
        let peak = max(1, sites.first?.visits ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "Top Sites"), detail: "\(sites.count)")
            if sites.isEmpty {
                emptyRow
            } else {
                ForEach(sites, id: \.host) { site in
                    HStack(spacing: 8) {
                        Text(site.host)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(appAccent.opacity(0.55))
                                .frame(width: max(2, geo.size.width * CGFloat(site.visits) / CGFloat(peak)))
                        }
                        .frame(height: 8)
                        Text("\(site.visits)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 24 小时分布：0–23 点各一根柱，峰值归一。
    private func hourlySection(_ hourly: [Int]) -> some View {
        let peak = max(1, hourly.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "By Hour of Day"), detail: "")
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = hourly.indices.contains(hour) ? hourly[hour] : 0
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(count == 0 ? Color.secondary.opacity(0.15) : appAccent.opacity(0.65))
                            .frame(height: 4 + CGFloat(count) / CGFloat(peak) * 42)
                            .frame(maxHeight: 46, alignment: .bottom)
                        Text(hour % 3 == 0 ? "\(hour)" : " ")
                            .font(.system(size: 7.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: String(localized: "%02d:00 — %d visit(s)"), hour, count))
                }
            }
            .frame(height: 60)
        }
    }

    /// 最近 7 天（旧 → 新，末尾是今天）。
    private func weekSection(_ days: [Int]) -> some View {
        let peak = max(1, days.max() ?? 1)
        let labels = Self.weekdayLabels(count: days.count)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(String(localized: "Last 7 Days"), detail: "")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, count in
                    VStack(spacing: 3) {
                        Text("\(count)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(appAccent.opacity(count == 0 ? 0.15 : 0.65))
                            .frame(height: 4 + CGFloat(count) / CGFloat(peak) * 44)
                            .frame(maxHeight: 48, alignment: .bottom)
                        Text(labels.indices.contains(index) ? labels[index] : "")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76)
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var emptyRow: some View {
        Text(String(localized: "Not enough history yet."))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    /// 最近 N 天的星期标签（末尾 = 今天）。
    private static func weekdayLabels(count: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return (0..<count).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return "" }
            return formatter.string(from: day)
        }
    }
}
