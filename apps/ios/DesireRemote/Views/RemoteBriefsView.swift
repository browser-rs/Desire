import SwiftUI

/// 每日简报（v0.8.20）：Mac 侧产物只读——最近 7 份，"在 Mac 上打开"走
/// openExcerpt（workspace 文件路径进查看器路由）。
struct RemoteBriefsView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            if client.briefs.isEmpty {
                Text("Mac 上还没有简报产物——每日简报任务跑过一次后自动落盘到这里")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.briefs) { brief in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(brief.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("在 Mac 上打开")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    Text(brief.text)
                        .font(.footnote)
                        .lineLimit(14)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    client.openExcerpt(brief.path)
                }
            }
        }
        .navigationTitle("每日简报")
        .onAppear { client.requestBriefs() }
        .refreshable { client.requestBriefs() }
    }
}
