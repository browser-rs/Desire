import SwiftUI
import UIKit

/// 后台任务（v0.8.39）：Mac 统一 Job 账本的手机视图——下载/批量/导出/
/// 转码/后台命令/定时任务。运行中可取消，失败命令可重试，产物可在 Mac 打开。
struct RemoteJobsView: View {
    @EnvironmentObject var client: RemoteClient

    private var active: [RemoteJobItem] {
        client.backgroundJobs.filter(\.isActive)
    }

    private var finished: [RemoteJobItem] {
        client.backgroundJobs.filter { !$0.isActive }
    }

    var body: some View {
        List {
            if client.backgroundJobs.isEmpty {
                DesireEmptyState(
                    icon: "square.stack.3d.up",
                    title: "没有后台任务",
                    message: "在 Mac 上开始批量下载、媒体导出或后台命令后，这里会显示进度与结果。")
                    .listRowBackground(Color.clear)
            } else {
                if !active.isEmpty {
                    Section {
                        ForEach(active) { job in
                            row(job)
                        }
                    } header: {
                        DesireSectionHeader(
                            title: "运行中 · \(active.count)",
                            subtitle: "退出页面不影响任务；完成时 Mac 会发通知")
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished.prefix(40)) { job in
                            row(job)
                        }
                    } header: {
                        DesireSectionHeader(title: "最近完成")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台任务")
        .onAppear { client.requestBackgroundJobs() }
        .refreshable { client.requestBackgroundJobs() }
    }

    private func row(_ job: RemoteJobItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: job.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(job.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(job.stateLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color(for: job))
            }
            HStack(spacing: 6) {
                Text(job.kindLabel)
                Text(Date(timeIntervalSince1970: job.updatedAt), style: .relative)
                if let exit = job.exitCode {
                    Text("exit \(exit)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if job.isActive, let progress = job.progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !job.detail.isEmpty {
                Text(job.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if job.isActive {
                    Button("取消", role: .destructive) {
                        client.cancelJob(id: job.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if job.kind == "command" && job.state == "failed" {
                    Button("重试") {
                        client.retryJob(id: job.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                if let artifact = job.artifact, !artifact.isEmpty {
                    Button("在 Mac 打开") {
                        client.openJobArtifact(artifact)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button {
                        UIPasteboard.general.string = artifact
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "download": return "arrow.down.circle"
        case "media": return "film"
        case "command": return "terminal"
        case "scheduled": return "clock.arrow.circlepath"
        case "agent": return "sparkles"
        default: return "square.stack.3d.up"
        }
    }

    private func color(for job: RemoteJobItem) -> Color {
        switch job.state {
        case "done": return .green
        case "failed": return .red
        case "cancelled": return .secondary
        case "needsReview", "needsApproval": return .orange
        default: return .accentColor
        }
    }
}
