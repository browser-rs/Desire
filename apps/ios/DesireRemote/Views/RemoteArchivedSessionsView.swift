import SwiftUI

/// 归档会话（v0.8.20）：已关窗口的会话归档（Mac 保留最近 5 个），
/// 手机上点按恢复到 Mac 当前窗口（替换其标签，与工具同语义）。
struct RemoteArchivedSessionsView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            if client.archivedSessions.isEmpty {
                Text("Mac 上没有归档会话——关掉一个窗口后会自动归档到这里")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.archivedSessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.fileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(session.tabCount) 标签")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !session.topURLs.isEmpty {
                        Text(session.topURLs)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                    Button("恢复到 Mac") {
                        client.restoreArchivedSession(file: session.fileName)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .navigationTitle("归档会话")
        .onAppear { client.requestArchivedSessions() }
        .refreshable { client.requestArchivedSessions() }
    }
}
