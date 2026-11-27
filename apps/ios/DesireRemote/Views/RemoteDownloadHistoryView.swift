import SwiftUI

/// 下载记录（v0.8.80 批 4）：Mac 按站点汇总的批次成败与吞吐（从批次派生）。
struct RemoteDownloadHistoryView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            if let history = client.downloadHistory {
                Section {
                    HStack(spacing: 14) {
                        metric("成功", "\(history.totals.finished)", .green)
                        metric("失败", "\(history.totals.failed)", .red)
                        metric("跳过", "\(history.totals.skipped)", .secondary)
                        metric("体积", DesireUI.formatBytes(history.totals.bytes), .secondary)
                    }
                }
                if !history.sites.isEmpty {
                    Section {
                        ForEach(history.sites) { site in
                            siteRow(site)
                        }
                    } header: {
                        DesireSectionHeader(title: "按站点")
                    }
                }
                if !history.batches.isEmpty {
                    Section {
                        ForEach(history.batches) { batch in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(batch.folder).font(.caption.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(dateText(batch.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text("完成 \(batch.finished) · 失败 \(batch.failed) · 跳过 \(batch.skipped) · \(DesireUI.formatBytes(batch.bytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        DesireSectionHeader(title: "批次")
                    }
                }
            } else {
                DesireEmptyState(icon: "clock.arrow.circlepath",
                                 title: "还没有下载记录",
                                 message: "批量下载结束后，Mac 会按站点汇总成功率与吞吐。")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载记录")
        .onAppear { client.requestDownloadHistory() }
        .refreshable { client.requestDownloadHistory() }
    }

    private func siteRow(_ site: RemoteDownloadHistoryFrame.Site) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(site.host).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(site.finished)/\(site.items)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(site.failed > 0 ? .orange : .secondary)
            }
            HStack(spacing: 8) {
                Text("\(site.batches) 批")
                if let speed = site.averageBytesPerSecond, speed > 0 {
                    Text("\(DesireUI.formatBytes(Int64(speed)))/s")
                }
                if let connections = site.connections {
                    Text("\(connections) 连接")
                }
                if let last = site.lastAt {
                    Text(dateText(last))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if let hint = site.hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 1)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateText(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
