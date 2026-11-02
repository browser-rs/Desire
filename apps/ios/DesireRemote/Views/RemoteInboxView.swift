import SwiftUI
import UIKit

/// 发送到手机收件箱（v0.8.38）：Mac 主动发来的页面/链接/选区/书摘。
struct RemoteInboxView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            if client.inbox.isEmpty {
                Text("Mac 还没有发来内容。在 Mac 上右键页面/链接/选区，选「发送到手机」即可。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.inbox) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let text = item.text, !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    if let url = item.url, !url.isEmpty {
                        Text(url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let url = item.url, !url.isEmpty {
                            Button("在 Mac 打开") { client.openOnMac(url: url) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Button("复制") {
                            UIPasteboard.general.string = [item.text, item.url]
                                .compactMap { $0 }
                                .joined(separator: "\n")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("问 Agent") {
                            client.sendPrompt("关于这条内容：\(item.title)\n\(item.text ?? item.url ?? "")")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                        if let at = item.at {
                            Text(Date(timeIntervalSince1970: at), style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("收件箱")
        .toolbar {
            if !client.inbox.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { client.clearInbox() }
                }
            }
        }
    }
}
