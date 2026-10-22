import AppKit
import SwiftUI

extension Notification.Name {
    /// 收件箱/其他面板请求打开 Jobs（Toolbar 拥有 sheet 状态）。
    static let openJobsPanel = Notification.Name("desire.jobs.open")
}

/// 统一作业面板（v0.8.2）：发布准备、提及扫描等作业的状态、产物与回执。
/// 不声称能取消底层任务——活动作业的按钮是 Dismiss（从视图移除）。
struct JobsPanel: View {
    @ObservedObject private var store = JobStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    private var running: [JobRecord] {
        store.allJobs.filter { $0.state == .queued || $0.state == .running || $0.state == .paused }
    }

    private var review: [JobRecord] { store.needsReview }
    private var failed: [JobRecord] { store.failed }
    private var finished: [JobRecord] { Array(store.finished.prefix(20)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jobs")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(store.active.count) active · \(review.count) need review · \(failed.count) failed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Clear Finished")) {
                    store.clearFinished()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(finished.isEmpty)
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if store.allJobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No jobs yet")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Publish preparation, mention scans and campaign work show up here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        section(String(localized: "Needs review"), jobs: review)
                        section(String(localized: "Running"), jobs: running)
                        section(String(localized: "Failed"), jobs: failed)
                        section(String(localized: "Finished"), jobs: finished)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    @ViewBuilder
    private func section(_ title: String, jobs: [JobRecord]) -> some View {
        if !jobs.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    row(job)
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func row(_ job: JobRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.state.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color(for: job.state))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(job.kind.label)
                        .font(.system(size: 10))
                        .foregroundStyle(appAccent)
                    if !job.detail.isEmpty {
                        Text(job.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(relative(job.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let receipt = job.receipt, !receipt.isEmpty {
                    Text(receipt)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let error = job.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let artifact = job.artifactURL, !artifact.isEmpty {
                Button(String(localized: "Open")) { open(artifact) }
                    .controlSize(.small)
            }
            if job.state == .needsApproval {
                Button(String(localized: "Approve")) {
                    BackgroundAgentRunner.shared.resolveApproval(jobID: job.id, decision: .allowOnce)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Deny"), role: .destructive) {
                    BackgroundAgentRunner.shared.resolveApproval(jobID: job.id, decision: .deny)
                }
                .controlSize(.small)
            } else if job.source == "activity" {
                Button(String(localized: "Activity")) {
                    CommandBus.shared.send(.showActivity)
                    dismiss()
                }
                .controlSize(.small)
            } else if job.canDismiss {
                Button(String(localized: "Dismiss")) { store.dismiss(job.id) }
                    .controlSize(.small)
            } else {
                Button {
                    store.delete(job.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }

    private func color(for state: JobRecord.State) -> Color {
        switch state {
        case .done: .green
        case .failed: .red
        case .needsReview, .needsApproval: .orange
        case .cancelled: Color.secondary
        case .queued, .running, .paused: appAccent
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func open(_ artifact: String) {
        if let url = URL(string: artifact),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            TabSessionCoordinator.shared.activeTabManager?.addTab(url: artifact)
            dismiss()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: artifact))
        }
    }
}
