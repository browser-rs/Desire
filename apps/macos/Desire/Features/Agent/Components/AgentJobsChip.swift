import SwiftUI

/// 后台任务 chip（v0.8.59）：原 v0.8.39 的"输入框上方常驻条"按用户反馈
/// 移除（挤压输入区），收成头部一枚紧凑 chip——图标 + 数量 + 迷你进度，
/// 点击弹 popover（任务行 / 订阅完成通知 / 任务面板入口）。运行中的任务
/// 依旧常驻可见，只是不再占据输入区。
struct AgentJobsChip: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var jobs = JobStore.shared
    @ObservedObject private var jobWatches = JobWatchStore.shared
    @State private var showsList = false
    /// 订阅完成通知归属的会话（popover 里点"完成时通知"时挂上去）。
    let conversationID: UUID?

    var body: some View {
        if !jobs.active.isEmpty {
            chip
        }
    }

    private var chip: some View {
        Button {
            showsList = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10))
                Text("\(jobs.active.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                if let progress = jobs.active.first(where: { $0.state == .running })?.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 30)
                }
            }
            .foregroundStyle(appAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(appAccent.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Background task"))
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "Background task"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Jobs")) {
                    showsList = false
                    NotificationCenter.default.post(name: .openJobsPanel, object: nil)
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5))
            }
            ForEach(Array(jobs.active.prefix(8))) { job in
                HStack(spacing: 6) {
                    Image(systemName: job.kind.icon)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(job.title)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .help(job.title)
                    Spacer(minLength: 4)
                    if let progress = job.progress, job.state == .running {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                    }
                    if jobWatches.active.contains(where: { $0.jobIDs.contains(job.id.uuidString) }) {
                        Text(String(localized: "Watching"))
                            .font(.system(size: 9))
                            .foregroundStyle(appAccent)
                    } else {
                        Button(String(localized: "Notify")) {
                            _ = JobWatchStore.shared.register(
                                jobIDs: [job.id.uuidString],
                                conversationID: conversationID,
                                mode: .notify,
                                reason: String(localized: "From Agent panel"))
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9.5))
                        .foregroundStyle(appAccent)
                    }
                }
            }
            if jobs.active.count > 8 {
                Text(String(localized: "\(jobs.active.count) background task(s)"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
