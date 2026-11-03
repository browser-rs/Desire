import SwiftUI
import UIKit

/// 后台任务详情（v0.8.40）：状态、退出码、产物、日志尾与订阅条件。
struct RemoteJobDetailView: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let jobID: String

    private var detail: RemoteJobDetail? {
        client.jobDetail?.id == jobID ? client.jobDetail : nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let detail {
                    Section {
                        DesireValueRow(title: "状态", value: stateLabel(detail.state),
                                       valueColor: stateColor(detail.state))
                        DesireValueRow(title: "类型", value: kindLabel(detail.kind))
                        DesireValueRow(title: "更新时间",
                                       value: Date(timeIntervalSince1970: detail.updatedAt)
                                        .formatted(date: .abbreviated, time: .shortened))
                        if let progress = detail.progress {
                            ProgressView(value: min(max(progress, 0), 1))
                        }
                        if !detail.detail.isEmpty {
                            Text(detail.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let error = detail.error, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if let exit = detail.exitCode {
                            DesireValueRow(title: "退出码", value: "\(exit)", mono: true)
                        }
                        if let watch = detail.watchCondition, !watch.isEmpty {
                            DesireValueRow(title: "订阅", value: watch
                                + (detail.watchMode == "resume" ? " · 汇报" : ""))
                        }
                    } header: {
                        DesireSectionHeader(title: detail.title)
                    }

                    if let artifact = detail.artifact, !artifact.isEmpty {
                        Section {
                            Text(artifact)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            HStack {
                                Button("在 Mac 打开") { client.openJobArtifact(artifact) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                Button("复制路径") {
                                    UIPasteboard.general.string = artifact
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } header: {
                            DesireSectionHeader(title: "产物")
                        }
                    }

                    Section {
                        HStack(spacing: 8) {
                            if ["queued", "running", "paused", "needsReview", "needsApproval"]
                                .contains(detail.state) {
                                Button("取消", role: .destructive) {
                                    client.cancelJob(id: detail.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            if detail.kind == "command" && detail.state == "failed" {
                                Button("重试") { client.retryJob(id: detail.id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            Button("刷新") { client.requestJobDetail(id: detail.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    if !detail.logTail.isEmpty {
                        Section {
                            ScrollView {
                                Text(detail.logTail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 280)
                        } header: {
                            DesireSectionHeader(title: "日志（尾部）")
                        }
                    }
                } else {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { client.requestJobDetail(id: jobID) }
            .refreshable { client.requestJobDetail(id: jobID) }
        }
    }

    private func stateLabel(_ raw: String) -> String {
        switch raw {
        case "queued": "排队中"
        case "running": "运行中"
        case "paused": "已暂停"
        case "needsReview": "待检查"
        case "needsApproval": "待审批"
        case "done": "完成"
        case "failed": "失败"
        case "cancelled": "已取消"
        default: raw
        }
    }

    private func stateColor(_ raw: String) -> Color {
        switch raw {
        case "done": .green
        case "failed": .red
        case "cancelled": .secondary
        case "needsReview", "needsApproval": .orange
        default: .accentColor
        }
    }

    private func kindLabel(_ raw: String) -> String {
        switch raw {
        case "download": "下载"
        case "media": "媒体"
        case "command": "命令"
        case "scheduled": "定时"
        case "agent": "Agent"
        default: raw
        }
    }
}
