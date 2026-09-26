import SwiftUI

/// Agent 看板（Menu「Agent 卡」push）：模型 / 上下文占用 / 排队 / 用时 / 连接。
struct AgentBoardView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            Section("状态") {
                LabeledContent("模型", value: client.agentModel.isEmpty ? "未配置" : client.agentModel)
                LabeledContent("上下文占用") {
                    Text("\(client.contextPercent)%")
                        .foregroundStyle(client.contextPercent >= 85 ? Color.red : (client.contextPercent >= 60 ? Color.orange : Color.secondary))
                }
                LabeledContent("排队消息", value: "\(client.queueCount) 条")
                if client.busy, let s = client.elapsedSeconds {
                    LabeledContent("回合已用时", value: Self.formatElapsed(s))
                }
                LabeledContent("连接") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(client.connectionState.contains("已连接") ? Color.green : (client.connectionState.contains("断开") || client.connectionState.contains("重连") ? Color.red : Color.orange))
                            .frame(width: 7, height: 7)
                        Text(client.connectionState).font(.subheadline)
                    }
                }
            }
            Section {
                LabeledContent("Mac", value: client.desktopName ?? "—")
                LabeledContent("账号", value: client.savedUsername)
            } footer: {
                Text("记忆管理在「记忆」页；工具调用的参数与结果直接显示在消息流里。")
            }
        }
    }

    static func formatElapsed(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
    }
}
