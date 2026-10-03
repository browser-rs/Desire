import SwiftUI

/// AI 设置页的「悬浮球」区块：全局开关（各窗口经通知跟随挂载/卸载）。
struct AgentBallSettingsSection: View {
    @ObservedObject private var ball = AgentBallPanel.shared

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
            }
        }
    }
}
