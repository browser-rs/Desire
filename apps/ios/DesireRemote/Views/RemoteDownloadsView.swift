import SwiftUI

/// 下载监控（v0.8.11）：手机看 Mac 的下载列表（状态/进度），单条暂停/恢复。
struct RemoteDownloadsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showAddDownload = false
    @State private var newDownloadURL = ""

    var body: some View {
        List {
            if client.downloads.isEmpty {
                Text("Mac 上没有下载任务")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.downloads) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(item.state)
                            .font(.caption)
                            .foregroundStyle(statusColor(item.state))
                        if item.state == "inProgress" {
                            ProgressView(value: item.progress)
                                .frame(maxWidth: 140)
                            Text("\(Int((item.progress * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.state == "inProgress" || item.isPaused {
                            Button(item.isPaused ? "继续" : "暂停") {
                                client.downloadAction(id: item.id,
                                                      action: item.isPaused ? "resume" : "pause")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }
        }
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddDownload = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 批量操作（v0.8.20）：全部暂停/继续/清完成。
            HStack(spacing: 10) {
                Button("全部暂停") { client.downloadsBulk("pauseAll") }
                Button("全部继续") { client.downloadsBulk("resumeAll") }
                Button("清空已完成") { client.downloadsBulk("clearFinished") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .alert("新建下载（在 Mac 上执行）", isPresented: $showAddDownload) {
            TextField("https://…", text: $newDownloadURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            Button("开始") {
                let trimmed = newDownloadURL.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                client.startDownload(url: trimmed)
                newDownloadURL = ""
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { client.requestDownloads() }
        .refreshable { client.requestDownloads() }
    }

    private func statusColor(_ state: String) -> Color {
        switch state {
        case "completed": .green
        case "failed": .red
        case "inProgress": .accentColor
        default: .secondary
        }
    }
}
