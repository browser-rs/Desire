import SwiftUI
import UIKit

/// 最近本地文件（v0.8.12；v0.8.38 批三补缩略图与元数据）：
/// 看 Mac 最近打开的本地文件，一键在 Mac 上重新打开或复制路径。
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
                row(file)
            }
        }
        .navigationTitle("最近文件")
        .searchable(text: $searchText, prompt: "按文件名或类型过滤")
        .onAppear { client.requestRecentFiles() }
        .refreshable { client.requestRecentFiles() }
    }

    private func row(_ file: RemoteRecentFile) -> some View {
        Button {
            client.openRecentFile(file.url)
        } label: {
            HStack(spacing: 10) {
                thumbnail(file)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.filename)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(file.kind)
                        if let size = file.sizeBytes {
                            Text(DesireUI.formatBytes(size))
                        }
                        if let modified = file.modifiedAt {
                            Text(Date(timeIntervalSince1970: modified),
                                 style: .relative)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button {
                        client.openRecentFile(file.url)
                    } label: {
                        Label("在 Mac 打开", systemImage: "macwindow")
                    }
                    Button {
                        UIPasteboard.general.string = copyValue(file.url)
                    } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ file: RemoteRecentFile) -> some View {
        if let base64 = file.thumbnail, let data = Data(base64Encoded: base64),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: icon(for: file.kind))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground)))
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "pdf": return "doc.richtext"
        case "media": return "play.rectangle"
        case "sheet": return "tablecells"
        case "image": return "photo"
        case "archive": return "archivebox"
        case "document": return "doc.text"
        default: return "doc"
        }
    }

    /// `file:///Users/...` → `/Users/...`；其他保持原样（最近文件都是本地文件）。
    private func copyValue(_ url: String) -> String {
        URL(string: url)?.path ?? url
    }
}
