import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 批量视频任务观察面板（第十一批·用户"批量任务没有观察入口"）。
///
/// 由 DownloadPanel 顶部的分段切换进入；观察 `BatchMediaExportStore` 的批次
/// （进度条 / 条目明细 / 保存路径）与 `MediaExportStore` 的单任务导出。
/// 操作走 BatchMediaExportStore 已有的 pause/resume/retry/skip/cancel。
struct BatchMediaPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: BatchMediaExportStore
    @ObservedObject var mediaStore: MediaExportStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.batches.isEmpty && mediaStore.jobs.isEmpty {
                EmptyState(message: String(localized: "No batch tasks"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !mediaStore.jobs.isEmpty {
                            singleExportsSection
                        }
                        ForEach(store.batches) { batch in
                            batchCard(batch)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    // MARK: - 单任务导出（downloadMedia）

    private var singleExportsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(String(localized: "Media Exports"))
            ForEach(mediaStore.jobs.suffix(12).reversed()) { job in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    stateDot(color: color(for: job.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let summary = job.summary {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(job.state.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - 批次卡片

    private func batchCard(_ batch: BatchMediaBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: batch.mode == .list ? "list.bullet.rectangle" : "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(batch.folderName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                stateBadge(batch)
                Spacer(minLength: 8)
                Text("\\(batch.finishedCount)/\\(batch.items.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            progressBar(finished: batch.finishedCount, total: batch.items.count)

            HStack(spacing: 10) {
                Label(savePathDisplay(batch), systemImage: "folder")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 打开本批保存目录（saveRoot 优先，缺省 ~/Downloads）
                        let root = batch.saveRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
                        NSWorkspace.shared.open(root.appendingPathComponent(batch.folderName, isDirectory: true))
                    }
                Spacer(minLength: 8)
                controls(batch)
            }

            itemRows(batch)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func stateBadge(_ batch: BatchMediaBatch) -> some View {
        let text: String
        let color: Color
        if store.suspensionReason(batch.id) != nil {
            text = String(localized: "Suspended"); color = .orange
        } else if store.isPaused(batch.id) {
            text = String(localized: "Paused"); color = .secondary
        } else {
            switch batch.state {
            case .running: text = String(localized: "Running"); color = appAccent
            case .finished: text = String(localized: "Done"); color = .green
            case .cancelled: text = String(localized: "Cancelled"); color = .secondary
            }
        }
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func controls(_ batch: BatchMediaBatch) -> some View {
        let running = batch.state == .running && !store.isPaused(batch.id) && store.suspensionReason(batch.id) == nil
        HoverIcon(systemName: running ? "pause" : "play.fill", action: {
            if running { store.pause(batchID: batch.id) } else { store.resume(batchID: batch.id) }
        }, help: running ? "Pause" : "Resume")
        HoverIcon(systemName: "arrow.clockwise", action: {
            store.retryFailed(batch.id)
        }, help: "Retry failed items")
        HoverIcon(systemName: "xmark", action: {
            store.cancel(batchID: batch.id)
        }, help: "Cancel batch")
    }

    // MARK: - 条目明细

    @ViewBuilder
    private func itemRows(_ batch: BatchMediaBatch) -> some View {
        let visible = batch.items.prefix(40)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    stateDot(color: color(for: item.state))
                    Text(item.title.isEmpty ? item.sourceURL.absoluteString : item.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let progress = store.progress(for: item.id) {
                        Text("\(progress.done)/\(progress.total) \(progress.unit == .seconds ? "s" : "seg")")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            if batch.items.count > 40 {
                Text("…").foregroundStyle(.tertiary)
                    .font(.system(size: 10.5))
            }
        }
        .padding(.leading, 14)
    }

    // MARK: - 共用小组件

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func stateDot(color: Color) -> some View {
        Circle().frame(width: 6, height: 6).foregroundStyle(color)
    }

    /// 4pt 胶囊进度条（与 DownloadPanel 同语言）。
    private func progressBar(finished: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(finished) / Double(total) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(appAccent.opacity(0.8))
                    .frame(width: max(4, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.25), value: finished)
            }
        }
        .frame(height: 4)
    }

    private func color(for state: BatchMediaItem.State) -> Color {
        switch state {
        case .pending: return .secondary
        case .resolving: return appAccent
        case .needsHuman: return .orange
        case .downloading: return appAccent
        case .finished: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    private func color(for state: MediaExportStore.Job.State) -> Color {
        switch state {
        case .running: return appAccent
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private func savePathDisplay(_ batch: BatchMediaBatch) -> String {
        // 显示用：自定义目录显示完整路径；缺省显示 ~/Downloads/<folder>
        if let root = batch.saveRoot { return root + "/" + batch.folderName }
        return "~" + "/Downloads/" + batch.folderName
    }
}
