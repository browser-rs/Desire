import Charts
import SwiftUI

/// 归因仪表盘（v0.8.3）：页面浏览 → 下载点击 → 首次启动的匿名漏斗。
/// 数据来自 desire-api `/growth/summary`（与同步共用登录态）；没有数据时
/// 明确说"未配置/还没有事件"，不编造漏斗。
struct PromotionGrowthSection: View {
    private var sync: SyncStore? { AppState.live?.syncStore }
    @Environment(\.appAccent) private var appAccent
    @AppStorage("growth.telemetryEnabled") private var telemetryEnabled = true

    @State private var summary: GrowthSummary?
    @State private var loading = false
    @State private var error: String?
    @State private var days = 30

    private var isSignedIn: Bool {
        guard let sync else { return false }
        if case .signedIn = sync.authState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !isSignedIn {
                Text(String(localized: "Sign in to Sync (Settings › Sync) to load anonymous attribution. No personal data is stored — only event counts."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else if loading && summary == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading attribution…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Retry")) { load() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(appAccent)
                }
            } else if let summary {
                if summary.isEmpty {
                    Text(String(localized: "No events yet. Deploy the product-page beacon (website/growth-beacon.js) and the first-launch reporter will feed the funnel."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    totals(summary)
                    chart(summary)
                    breakdown(summary)
                }
                Text(String(localized: "Anonymous aggregate only: event counts + UTM labels. No IP, cookies, UA or account identifiers are stored."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Toggle(String(localized: "Send anonymous first-launch event from this app"), isOn: $telemetryEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
        }
        .onAppear {
            if summary == nil { load() }
        }
        .onChange(of: days) { _, _ in load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appAccent)
            Text(String(localized: "Attribution"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker("", selection: $days) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
            if isSignedIn {
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .help(String(localized: "Refresh"))
            }
        }
    }

    private func totals(_ summary: GrowthSummary) -> some View {
        HStack(spacing: 8) {
            metricCard(String(localized: "Page views"), value: summary.totals.pageView, tint: appAccent)
            metricCard(String(localized: "Download clicks"), value: summary.totals.downloadClick, tint: .green)
            metricCard(String(localized: "First launches"), value: summary.totals.firstLaunch, tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(rateLine(summary))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricCard(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.08)))
    }

    private func rateLine(_ summary: GrowthSummary) -> String {
        var parts: [String] = []
        if let click = summary.clickRate {
            parts.append(String(format: String(localized: "Click rate %.1f%%"), click * 100))
        }
        if let install = summary.installRate {
            parts.append(String(format: String(localized: "Install rate %.1f%%"), install * 100))
        }
        if parts.isEmpty { return String(localized: "No conversion data yet") }
        return parts.joined(separator: " · ")
    }

    private func chart(_ summary: GrowthSummary) -> some View {
        let points = GrowthSummary.paddedDaily(summary)
        return Chart(points) { day in
            BarMark(x: .value("Day", day.day),
                    y: .value("Page views", day.pageView))
                .foregroundStyle(appAccent.opacity(0.75))
                .cornerRadius(1.5)
        }
        .frame(height: 110)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.system(size: 8))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let first = points.first?.day, let last = points.last?.day {
                Text("\(first) → \(last)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func breakdown(_ summary: GrowthSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            breakdownColumn(String(localized: "Campaigns"), rows: summary.campaigns)
            breakdownColumn(String(localized: "Sources"), rows: summary.sources)
        }
    }

    private func breakdownColumn(_ title: String, rows: [GrowthSummary.Breakdown]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows.prefix(5)) { row in
                    HStack(spacing: 6) {
                        Text(row.key)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(row.pageView)/\(row.downloadClick)/\(row.firstLaunch)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        guard let sync, isSignedIn else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                summary = try await sync.fetchGrowthSummary(days: days)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
