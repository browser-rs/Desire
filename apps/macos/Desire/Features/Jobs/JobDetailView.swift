import AppKit
import SwiftUI

/// 任务详情（v0.8.40）：状态/进度/退出码/产物/日志尾部与操作。
struct JobDetailView: View {
    @ObservedObject private var jobs = JobStore.shared
    @ObservedObject private var watches = JobWatchStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color
    let jobID: UUID
    @State private var logTail = ""
    @State private var message: String?

    private var job: JobRecord? {
        jobs.allJobs.first { $0.id == jobID }
    }

    private var watch: JobWatch? {
        watches.active.first { $0.jobIDs.contains(jobID.uuidString) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: job?.kind.icon ?? "square.stack.3d.up")
                    .foregroundStyle(appAccent)
                Text(job?.title ?? String(localized: "Job"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }

            if let job {
                HStack(spacing: 10) {
                    Text(job.kind.label)
                    Text(job.state.label)
                        .foregroundStyle(color(for: job.state))
                    if let progress = job.progress, job.state == .running {
                        ProgressView(value: progress)
                            .frame(width: 100)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    if let exit = job.exitCode {
                        Text("exit \(exit)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    Spacer()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

                if !job.detail.isEmpty {
                    Text(job.detail)
                        .font(.system(size: 11))
                }
                if let error = job.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                if let artifact = job.artifactURL, !artifact.isEmpty {
                    HStack(spacing: 6) {
                        Text(String(localized: "Output:"))
                            .foregroundStyle(.secondary)
                        Text(artifact)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(String(localized: "Open")) { open(artifact) }
                            .controlSize(.small)
                    }
                    .font(.system(size: 10.5))
                }
                if let watch {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge")
                        Text(String(localized: "Watching: \(JobWatchCore.conditionDescription(watch.effectiveCondition))"))
                        if watch.mode == .resume { Text(String(localized: "· resume")) }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(appAccent)
                }
                if let logFile = job.logFile, !logFile.isEmpty {
                    HStack(spacing: 6) {
                        Text(String(localized: "Log"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: logFile)])
                        }
                        .controlSize(.small)
                        Button(String(localized: "Refresh")) { reloadLog() }
                            .controlSize(.small)
                    }
                    ScrollView {
                        Text(logTail.isEmpty ? String(localized: "No log output yet.") : logTail)
                            .font(.system(size: 10.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    .frame(maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                }

                HStack(spacing: 8) {
                    if job.state.isActive {
                        Button(String(localized: "Cancel")) {
                            switch JobControl.cancel(job.id) {
                            case .success(let text): message = text
                            case .failure(let error): message = error.message
                            }
                        }
                        .controlSize(.small)
                    }
                    if job.kind == .command && (job.state == .failed || job.state == .cancelled) {
                        Button(String(localized: "Retry")) {
                            Task { @MainActor in
                                switch await JobControl.retry(job.id) {
                                case .success(let id): message = String(localized: "Retry started as job \(id.uuidString).")
                                case .failure(let error): message = error.message
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    if watch == nil && job.state.isActive {
                        Button(String(localized: "Notify")) {
                            _ = JobWatchStore.shared.register(
                                jobIDs: [job.id.uuidString],
                                conversationID: job.conversationID,
                                mode: .notify,
                                reason: String(localized: "From job detail"))
                        }
                        .controlSize(.small)
                    }
                    if let message {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            } else {
                Text(String(localized: "This job is no longer in the ledger."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 640, height: 560)
        .onAppear(perform: reloadLog)
    }

    private func reloadLog() {
        guard let path = job?.logFile else { logTail = ""; return }
        logTail = BackgroundCommandStore.readTail(path: path, maxLines: 200)
    }

    private func open(_ path: String) {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            TabSessionCoordinator.shared.activeTabManager?.addTab(url: path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func color(for state: JobRecord.State) -> Color {
        switch state {
        case .done: .green
        case .failed: .red
        case .needsReview, .needsApproval: .orange
        case .cancelled: .secondary
        default: appAccent
        }
    }
}
