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
                SettingsRowDivider()
                // v4：触盘 2×2 槽位（八选四，同能力换槽 = 两槽互换）。
                SettingsRow(
                    String(localized: "Hub Slots"),
                    subtitle: String(localized: "Pick the four actions on the ball's radial hub. Choosing a capability that already occupies another slot swaps the two.")
                ) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { index in
                            Picker("", selection: slotBinding(index)) {
                                ForEach(BallCapability.allCases) { capability in
                                    Text(capability.displayName).tag(capability)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 74)
                        }
                    }
                }
                SettingsRowDivider()
                // 「自定义提示词」槽位发送的文本。
                SettingsRow(
                    String(localized: "Custom Prompt"),
                    subtitle: String(localized: "Sent as a new agent turn when the Custom Prompt hub slot is tapped.")
                ) {
                    TextField(String(localized: "e.g. Summarize this page and give me three takeaways"), text: $ball.customPrompt)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<BallCapability> {
        Binding(
            get: { ball.slots.indices.contains(index) ? ball.slots[index] : .conversation },
            set: { ball.setSlot(index, to: $0) }
        )
    }
}
