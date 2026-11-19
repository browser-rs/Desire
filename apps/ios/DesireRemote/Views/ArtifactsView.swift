import SwiftUI

/// 产物列表（v0.8.63 批 2）：桌面 Agent 产出的文件/文件夹（作业产物、转换
/// 产物统一入库的形态）——挂在 Agent tab 的 NavigationStack（与"对话不是
/// Tab"同款信息架构：产物也不是一级 Tab）。
struct ArtifactsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var artifacts: [RemoteArtifact] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                ForEach(artifacts) { artifact in
                    NavigationLink {
                        ArtifactDetailView(artifact: artifact)
                    } label: {
                        row(artifact)
                    }
                }
            } header: {
                Text("共 \(artifacts.count) 项")
            }
            if !artifacts.isEmpty {
                Section {
                    Text("产物存放在 Mac 上——手机端查看元信息并发回指令，文件本体留在桌面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("产物")
        .overlay {
            if isLoading && artifacts.isEmpty {
                ProgressView()
            }
        }
        .refreshable { await load() }
        .task { if artifacts.isEmpty { await load() } }
    }

    private func row(_ artifact: RemoteArtifact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(artifact.isFolder ? Color.blue : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.jobTitle.isEmpty ? artifact.displayName : artifact.jobTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(artifact.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(shortTime(artifact.at))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            artifacts = try await client.fetchArtifacts()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func shortTime(_ iso: String) -> String {
        // ISO → 相对短时间（今天显示时刻，其余显示日期）。
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = date.isSameCalendarDay(as: Date()) ? "HH:mm" : "MM-dd"
        return display.string(from: date)
    }
}

extension Date {
    func isSameCalendarDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }
}

/// 产物详情（v0.8.63 批 2）：元信息 + 复制路径 + **发回再加工**（把产物
/// 发回桌面 Agent 继续加工的指令）。
struct ArtifactDetailView: View {
    @EnvironmentObject var client: RemoteClient
    let artifact: RemoteArtifact
    @State private var sentConfirmation = false
    @State private var pathCopied = false

    var body: some View {
        List {
            Section("产物") {
                row("名称", artifact.displayName)
                row("类型", artifact.isFolder ? "文件夹" : "文件")
                row("路径", artifact.path)
            }
            Section("来源") {
                row("作业", artifact.jobTitle)
                if let conversation = artifact.conversationId, !conversation.isEmpty {
                    row("会话", conversation)
                }
                row("时间", artifact.at)
            }
            Section {
                Button {
                    UIPasteboard.general.string = artifact.path
                    pathCopied = true
                } label: {
                    Label(pathCopied ? "已复制" : "复制路径", systemImage: pathCopied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    client.sendPrompt(
                        "请对产物「\(artifact.displayName)」（路径：\(artifact.path)）继续加工——先查看它的内容/状态，再按合理的方式处理并告诉我结果。")
                    sentConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        sentConfirmation = false
                    }
                } label: {
                    Label(sentConfirmation ? "已发回桌面 Agent" : "发回再加工", systemImage: "arrowshape.turn.up.left.fill")
                }
                .disabled(sentConfirmation)
            } header: {
                Text("操作")
            } footer: {
                Text("「发回再加工」把指令发到桌面 Agent（需 Mac 在线）；文件本体保留在 Mac 上。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(artifact.displayName)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private extension String {
    var isNilOrEmpty: Bool { isEmpty }
}
