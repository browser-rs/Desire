import SwiftUI

/// AI 设置页的「悬浮球」区块：全局开关（各窗口经通知跟随挂载/卸载）。
struct AgentBallSettingsSection: View {
    @ObservedObject private var ball = AgentBallPanel.shared
    @AppStorage("agentBall.size") private var ballSize: Double = 52

    var body: some View {
        SettingsSection(
            title: String(localized: "Agent Floating Ball"),
            subtitle: String(localized: "A small ball hugging the window edge: drag it anywhere, click to expand agent actions (chat, voice, page summary, whiteboard)."),
            icon: "circle.circle"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    String(localized: "Floating Ball"),
                    subtitle: String(localized: "Off hides the ball in all browser windows. On shows it on the active window's edge.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { ball.isEnabled },
                        set: { ball.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Ball Size"),
                    subtitle: String(localized: "Applies immediately; position snaps stay the same.")
                ) {
                    Picker("", selection: $ballSize) {
                        Text(String(localized: "Small")).tag(44.0)
                        Text(String(localized: "Medium")).tag(52.0)
                        Text(String(localized: "Large")).tag(60.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }
        }
    }
}
