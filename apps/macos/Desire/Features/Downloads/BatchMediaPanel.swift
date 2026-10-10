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
    /// 展开日志的批次集合（doc.text 图标 toggle）。
    @State private var expandedLogIDs: Set<UUID> = []
    /// 静态缓存：每次渲染新建 DateFormatter（耗时分配器）在滚动期间反复发生。
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.batches.isEmpty && mediaStore.jobs.isEmpty {
                EmptyState(message: String(localized: "No batch tasks"))
            } else {
                ScrollView {
                    // LazyVStack：批次多时只物化可见卡——全量 VStack 在每次
                    // @Published 触发时重建全部卡片 × 40 行，滚动掉帧。
                    LazyVStack(alignment: .leading, spacing: 18) {
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
                Text("\(batch.finishedCount)/\(batch.items.count)")
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
                        // folder 为空 = 目录直存（无子文件夹），打开目标目录本身。
                        let target = batch.folderName.isEmpty
                            ? root
                            : root.appendingPathComponent(batch.folderName, isDirectory: true)
                        NSWorkspace.shared.open(target)
                    }
                Spacer(minLength: 8)
                controls(batch)
            }

            itemRows(batch)

            if expandedLogIDs.contains(batch.id) {
                logView(batch)
            }
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
        }, help: running ? String(localized: "Pause") : String(localized: "Resume"))
        HoverIcon(systemName: "doc.text", action: {
            withAnimation(.easeOut(duration: 0.15)) {
                if expandedLogIDs.contains(batch.id) {
                    expandedLogIDs.remove(batch.id)
                } else {
                    expandedLogIDs.insert(batch.id)
                }
            }
        }, help: String(localized: "Download Log"))
        HoverIcon(systemName: "arrow.clockwise", action: {
            store.retryFailed(batch.id)
        }, help: String(localized: "Retry failed items"))
        HoverIcon(systemName: "xmark", action: {
            if batch.state == .running {
                store.cancel(batchID: batch.id)
            } else {
                // 已结束批次：删除 = 从面板移除（清孤儿残件）。此前对已结束
                // 批次是空操作（用户实测"删除无效"）。
                store.removeSettled(batchID: batch.id)
            }
        }, help: batch.state == .running
            ? String(localized: "Cancel batch")
            : String(localized: "Remove from list"))
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
                        // 合成阶段：不再显示分片计数（此时分片已全部完成），
                        // 显示"合成中"避免 UI 静止像假死。
                        if progress.unit == .merging {
                            Text(String(localized: "Merging…"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(progress.done)/\(progress.total) \(progress.unit == .seconds ? "s" : "seg")")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    // 逐项移除：排队/失败项可删（从队列移除）；成品不在此删
                    //（文件在盘上，删除文件超出面板语义）。
                    if item.state == .pending || item.state == .failed {
                        HoverIcon(systemName: "minus.circle", action: {
                            store.skip(batchID: batch.id, itemID: item.id)
                        }, help: String(localized: "Remove from queue"))
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

    /// 批任务日志（展开区）：打开时刻的快照（BatchMediaLogStore 静态读），
    /// 重开一次即刷新。mono 小字、自动滚到最新。
    private func logView(_ batch: BatchMediaBatch) -> some View {
        let entries = BatchMediaLogStore.entries(batch.id)
        return Group {
            if entries.isEmpty {
                Text(String(localized: "No log entries yet"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                Text(verbatim: "\(Self.logFormatter.string(from: entry.at))  \(entry.line)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                    )
                    .onAppear {
                        if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
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
        // 显示用：folder 为空 = 目录直存（只显示目录本身）；缺省 ~/Downloads/<folder>
        let leaf = batch.folderName.isEmpty ? "" : "/" + batch.folderName
        if let root = batch.saveRoot { return root + leaf }
        return "~" + "/Downloads" + leaf
    }
}
