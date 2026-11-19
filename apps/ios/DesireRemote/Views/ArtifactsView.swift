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
                HStack(spacing: 4) {
                    Text(artifact.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let sizeText = artifact.sizeText {
                        Text(sizeText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
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

/// 产物详情（v0.8.63 批 2 + v0.8.64 批 4）：元信息 + 复制路径 + **发回再
/// 加工**（预设指令 chips）+ **内容预览**（文本 ≤256KB / 图片 ≤5MB 直读，
/// 其余"在 Mac 上打开"——桌面端做白名单与大小闸）。
struct ArtifactDetailView: View {
    @EnvironmentObject var client: RemoteClient
    let artifact: RemoteArtifact
    @State private var sentConfirmation = false
    @State private var pathCopied = false
    // 预览（v0.8.64 批 4）
    @State private var preview: RemoteArtifactContent?
    @State private var previewLoading = false
    // 再加工确认态（chips 与自由指令共用，任一发送后短暂禁用全部按钮）
    @State private var lastSentLabel: String?

    var body: some View {
        List {
            if !artifact.isFolder {
                previewSection
            }
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
            if !artifact.isFolder {
                Section("再加工") {
                    ForEach(remixActions, id: \.label) { action in
                        Button {
                            client.sendPrompt(action.prompt)
                            flashSent(action.label)
                        } label: {
                            Label(action.label, systemImage: action.icon)
                        }
                        .disabled(lastSentLabel != nil)
                    }
                }
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
                    flashSent("发回再加工")
                } label: {
                    Label(lastSentLabel == "发回再加工" ? "已发回桌面 Agent" : "发回再加工", systemImage: "arrowshape.turn.up.left.fill")
                }
                .disabled(lastSentLabel != nil)
            } header: {
                Text("操作")
            } footer: {
                Text("「发回再加工」把指令发到桌面 Agent（需 Mac 在线）；文件本体保留在 Mac 上。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(artifact.displayName)
        .task {
            guard !artifact.isFolder, preview == nil else { return }
            await loadPreview()
        }
    }

    // MARK: - 预览

    @ViewBuilder
    private var previewSection: some View {
        Section("预览") {
            if previewLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let preview {
                if let error = preview.error {
                    Text(error.contains("folder")
                         ? "文件夹没有预览。"
                         : (error.contains("too large") || error.contains("binary")
                            ? "内容较大或是二进制格式——请在 Mac 上查看。"
                            : "暂不可预览：\(error)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let text = preview.content {
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                } else if let uri = preview.dataURI,
                          let image = image(fromDataURI: uri) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                } else {
                    Text("暂不支持预览——请在 Mac 上打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("在 Mac 上打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadPreview() async {
        previewLoading = true
        preview = try? await client.readArtifact(path: artifact.path)
        previewLoading = false
    }

    private func image(fromDataURI uri: String) -> UIImage? {
        guard let range = uri.range(of: "base64,") else { return nil }
        guard let data = Data(base64Encoded: String(uri[range.upperBound...])) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 再加工 chips

    private struct RemixAction {
        let label: String
        let icon: String
        let prompt: String
    }

    private var remixActions: [RemixAction] {
        [
            RemixAction(label: "总结此文件", icon: "text.alignleft",
                        prompt: "请读取产物「\(artifact.displayName)」（路径：\(artifact.path)）的内容，给我一份简明总结——要点、结构与值得注意的地方。"),
            RemixAction(label: "转成 Markdown", icon: "doc.plaintext",
                        prompt: "请把产物「\(artifact.displayName)」（路径：\(artifact.path)）转换成排版良好的 Markdown 文件，保存在同目录并告诉我新路径。"),
            RemixAction(label: "规整重命名", icon: "gearshape.2",
                        prompt: "请查看产物「\(artifact.displayName)」（路径：\(artifact.path)）的内容，给出一个更规整的文件名并完成重命名（保留扩展名），告诉我前后名字。"),
        ]
    }

    private func flashSent(_ label: String) {
        lastSentLabel = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            lastSentLabel = nil
        }
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
