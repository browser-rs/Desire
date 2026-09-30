import SwiftUI

/// 广告拦截统计面板：今日/累计大数字、站点排行、最近拦截记录、清零。
/// 数据全部来自 `AdBlockStatsStore`（init 即读盘——离屏快照可拍）。
struct AdBlockPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var stats = AdBlockStatsStore.shared
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onAppear { stats.rollDay() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    bigStats
                    topSites
                    recentList
                    scopeNote
                }
                .padding(14)
            }
        }
        .frame(width: 440, height: 520)
        .alert("Clear Stats", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { stats.clear() }
        } message: {
            Text("This resets the counters and the recent list. It cannot be undone.")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(appAccent.opacity(0.15))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appAccent)
            }
            .frame(width: 28, height: 28)

            Text("Ad Blocking")
                .font(.system(size: 14, weight: .semibold))

            Spacer(minLength: 8)

            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(stats.total == 0)
            .help("Clear Stats")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 大数字

    private var bigStats: some View {
        HStack(spacing: 12) {
            statCard(
                title: String(localized: "Today"),
                value: stats.todayCount,
                tint: appAccent
            )
            statCard(
                title: String(localized: "All Time"),
                value: stats.total,
                tint: .secondary
            )
        }
    }

    private func statCard(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(verbatim: value.description)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - 站点排行

    @ViewBuilder
    private var topSites: some View {
        let entries = stats.perDomain.sorted { $0.value > $1.value }.prefix(8)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Sites")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                let maxValue = max(entries.first?.value ?? 1, 1)
                ForEach(entries, id: \.key) { site, count in
                    HStack(spacing: 8) {
                        Text(AdBlockStatsStore.displayName(forSite: site))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                Capsule()
                                    .fill(appAccent.opacity(0.75))
                                    .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(maxValue)))
                            }
                        }
                        .frame(height: 8)
                        Text(verbatim: count.description)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - 最近拦截

    @ViewBuilder
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Blocks")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            if stats.recent.isEmpty {
                Text("No ads blocked yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(stats.recent.prefix(30)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: Self.timeText(event.at))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .leading)
                        Text(AdBlockStatsStore.displayName(forSite: event.site))
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text(verbatim: "+\(event.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(appAccent)
                        if !event.action.isEmpty {
                            Text(verbatim: actionSuffix(event.action))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// 统计口径的诚实标注：EasyList 在 WebKit 引擎内执行，无逐请求回调。
    private var scopeNote: some View {
        Text("Stats Scope Note")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )
    }

    // MARK: - 共用

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 与 toast 一致的动作后缀。
    private func actionSuffix(_ action: String) -> String {
        switch action {
        case "skip": String(localized: "（已跳过）")
        case "seek": String(localized: "（已快进）")
        case "click-hijack": String(localized: "（首次点击防护）")
        default: ""
        }
    }
}
