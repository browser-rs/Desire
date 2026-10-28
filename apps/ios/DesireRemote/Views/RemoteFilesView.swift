import SwiftUI

/// 最近本地文件（v0.8.12）：看 Mac 最近打开的本地文件，一键在 Mac 上重新打开。
struct RemoteFilesView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var searchText = ""

    private var filtered: [RemoteRecentFile] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return client.recentFiles }
        return client.recentFiles.filter {
            $0.filename.localizedCaseInsensitiveContains(q)
                || $0.kind.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if client.recentFiles.isEmpty {
                Text("Mac 上还没有本地文件记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if filtered.isEmpty {
                Text("没有匹配 \(searchText) 的文件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(filtered) { file in
                Button {
                    client.openRecentFile(file.url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(file.filename)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(file.kind)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("最近文件")
        .searchable(text: $searchText, prompt: "按文件名或类型过滤")
        .onAppear { client.requestRecentFiles() }
        .refreshable { client.requestRecentFiles() }
    }
}
