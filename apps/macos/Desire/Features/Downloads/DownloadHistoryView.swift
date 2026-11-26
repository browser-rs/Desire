import Combine
import SwiftUI

/// 设置 ▸ 批量下载 ›「下载记录」（v0.8.79）：按站点聚合的成功率、体积、平均速度与
/// 实际用过的引擎。数据从已保存的批次派生（`DownloadHistory`），与桥
/// `GET /downloads/history` 同一份。
///
/// 只读视图：不做持久化、不发请求。空态明确说明"这里只覆盖还留在盘上的批次"，
/// 避免被读成"全部历史上都没下载过"。
struct DownloadHistorySection: View {
    @ObservedObject private var store = BatchMediaExportStore.shared

    var body: some View {
        let history = DownloadHistory.derive(from: store.batches)
        SettingsSection(
            title: String(localized: "Download History"),
            subtitle: String(localized: "Per-site results derived from the batches kept on disk (running + the most recent finished ones). Older batches live in their archived logs."),
            icon: "clock.arrow.circlepath"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if history.sites.isEmpty {
                    Text(String(localized: "No completed batch downloads yet."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    headerRow
                    SettingsRowDivider()
                    ForEach(history.sites) { site in
                        siteRow(site)
                        if site.id != history.sites.last?.id {
                            SettingsRowDivider()
                        }
                    }
                    SettingsRowDivider()
                    totalsRow(history)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Site"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Done"))
                .frame(width: 44, alignment: .trailing)
            Text(String(localized: "Failed"))
                .frame(width: 44, alignment: .trailing)
            Text(String(localized: "Bytes"))
                .frame(width: 78, alignment: .trailing)
            Text(String(localized: "Avg speed"))
                .frame(width: 84, alignment: .trailing)
            Text(String(localized: "Avg time"))
                .frame(width: 64, alignment: .trailing)
            Text(String(localized: "Method"))
                .frame(width: 88, alignment: .trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }

    private func siteRow(_ site: DownloadHistory.Site) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(site.skipped > 0
                     ? site.host + " · " + String(format: String(localized: "%lld skipped"), site.skipped)
                     : site.host)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let hint = site.hint {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(site.finished)")
                .frame(width: 44, alignment: .trailing)
            Text("\(site.failed)")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(site.failed > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Text(bytesLabel(site.bytes))
                .frame(width: 78, alignment: .trailing)
            Text(speedLabel(site.averageBytesPerSecond))
                .frame(width: 84, alignment: .trailing)
            Text(timeLabel(site.averageSeconds))
                .frame(width: 64, alignment: .trailing)
            Text(engineLabel(site.engines, connections: site.connections))
                .frame(width: 88, alignment: .trailing)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }

    private func totalsRow(_ history: DownloadHistory) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "All sites"))
                .font(.system(size: 10.5, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(history.finished)")
                .frame(width: 44, alignment: .trailing)
            Text("\(history.failed)")
                .frame(width: 44, alignment: .trailing)
            Text(bytesLabel(history.bytes))
                .frame(width: 78, alignment: .trailing)
            Spacer(minLength: 0)
                .frame(width: 84 + 64 + 88)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func speedLabel(_ speed: Double?) -> String {
        guard let speed, speed > 0 else { return "—" }
        return String(format: "%.1f MB/s", speed / 1_048_576)
    }

    private func timeLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    private func engineLabel(_ engines: [String: Int], connections: Int?) -> String {
        guard let top = engines.max(by: { $0.value < $1.value })?.key else { return "—" }
        let name: String
        switch top {
        case "parallel": name = String(localized: "Parallel")
        case "ffmpeg": name = "FFmpeg"
        case "builtin": name = String(localized: "Built-in")
        case "direct": name = String(localized: "Direct")
        case "reused": name = String(localized: "Reused")
        default: name = top
        }
        guard let connections, top == "parallel" else { return name }
        return "\(name) ×\(connections)"
    }
}
