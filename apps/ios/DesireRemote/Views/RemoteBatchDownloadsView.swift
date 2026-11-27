import SwiftUI

/// 批量下载控制（v0.8.80 批 4）：批次与逐项状态、暂停/恢复、跳过/重试、
/// 日志尾；数据来自 Mac 的 BatchMediaExportStore（与桌面面板同源）。
struct RemoteBatchDownloadsView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            if client.batchDownloads.isEmpty {
                DesireEmptyState(icon: "square.stack.3d.down.right",
                                 title: "没有批量下载",
                                 message: "在 Mac 上开始批量下载后，这里能看到逐项进度与日志。")
                    .listRowBackground(Color.clear)
            }
            ForEach(client.batchDownloads) { batch in
                batchSection(batch)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("批量下载")
        .onAppear { client.requestBatchDownloads() }
        .refreshable { client.requestBatchDownloads() }
    }

    private func batchSection(_ batch: RemoteBatchDownloadsFrame.Batch) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: batch.paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(batch.paused ? .orange : DesireUI.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.folder).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(batch.finished)/\(batch.total) 完成 · \(batch.mode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(batch.state == "finished" ? "已结束" : (batch.paused ? "已暂停" : "运行中"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(batch.paused ? .orange : .secondary)
            }
            if let window = batch.window {
                HStack(spacing: 5) {
                    Image(systemName: window.open ? "clock.badge.checkmark" : "clock.badge.xmark")
                        .font(.caption2)
                    Text("窗口 \(window.summary)")
                        .font(.caption2)
                    if !window.open {
                        Text("下次开窗自动继续")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(window.open ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
            if let reason = batch.suspendedReason, !reason.isEmpty {
                Text(reason).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(batch.items) { item in
                itemRow(batch: batch, item: item)
            }
            HStack(spacing: 8) {
                if batch.state != "finished" {
                    Button(batch.paused ? "恢复" : "暂停") {
                        client.batchAction(batch.paused ? "resume" : "pause", batchID: batch.id)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                if batch.items.contains(where: { $0.state == "failed" }) {
                    Button("重试失败") {
                        client.batchAction("retryFailed", batchID: batch.id)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                if batch.state != "finished" && batch.state != "cancelled" {
                    Button("取消批次", role: .destructive) {
                        client.batchAction("cancel", batchID: batch.id)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            if !batch.logTail.isEmpty {
                DisclosureGroup("日志尾 · \(batch.logTail.count) 行") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(batch.logTail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            DesireSectionHeader(title: dateText(batch.createdAt),
                                subtitle: batch.items.contains(where: { $0.state == "downloading" })
                                    ? "有项目正在下载" : nil)
        }
    }

    private func itemRow(batch: RemoteBatchDownloadsFrame.Batch,
                         item: RemoteBatchDownloadsFrame.Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon(item.state))
                    .font(.caption)
                    .foregroundStyle(color(item.state))
                Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(stateLabel(item.state)).font(.caption2).foregroundStyle(color(item.state))
            }
            if let progress = item.progress, item.state == "downloading" {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                HStack(spacing: 6) {
                    Text("\(Int((progress * 100).rounded()))%")
                    if let rate = item.rate, rate > 0 {
                        Text(rateText(rate, unit: item.unit))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let failure = item.failureReason, !failure.isEmpty {
                Text(failure).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            HStack(spacing: 8) {
                if ["pending", "needsHuman", "downloading"].contains(item.state) {
                    Button("跳过", role: .destructive) {
                        client.batchAction("skip", batchID: batch.id, itemID: item.id)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                if item.state == "failed" {
                    Button("重试") {
                        client.batchAction("retry", batchID: batch.id, itemID: item.id)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
                if let bytes = item.bytes, bytes > 0 {
                    Text(DesireUI.formatBytes(bytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func icon(_ state: String) -> String {
        switch state {
        case "finished": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "skipped": "minus.circle"
        case "downloading": "arrow.down.circle.fill"
        case "resolving": "magnifyingglass"
        case "needsHuman": "person.crop.circle.badge.questionmark"
        default: "clock"
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "finished": .green
        case "failed": .red
        case "downloading": DesireUI.brand
        case "needsHuman": .orange
        default: .secondary
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "pending": "排队"
        case "resolving": "解析中"
        case "needsHuman": "等人处理"
        case "downloading": "下载中"
        case "finished": "完成"
        case "failed": "失败"
        case "skipped": "跳过"
        default: state
        }
    }

    private func rateText(_ rate: Double, unit: String?) -> String {
        switch unit {
        case "segments": String(format: "%.1f 段/s", rate)
        case "seconds": String(format: "%.2fx", rate)
        default: String(format: "%.1f/s", rate)
        }
    }

    private func dateText(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}
