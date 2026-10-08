import SwiftUI

/// 设置 →「悬浮球」独立子页（v6）：球体外观 / 触盘功能 / 触盘样式 / 交互
/// 四组，全部即时生效（AppStorage/UserDefaults 直达，覆盖层观察即跟随）。
struct AgentBallSettingsView: View {
    @ObservedObject private var ball = AgentBallPanel.shared
    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @AppStorage(AgentBallPanel.opacityKey) private var ballOpacity: Double = 1.0
    @AppStorage(AgentBallPanel.idleStyleKey) private var idleStyle: String = "ring"
    @AppStorage(AgentBallPanel.hubScaleKey) private var hubScale: Double = 1.0
    @AppStorage(AgentBallPanel.hubAnimationKey) private var hubAnimation: Bool = true
    @AppStorage(AgentBallPanel.doubleClickVoiceKey) private var doubleClickVoice: Bool = true
    /// 重置操作的轻确认（按钮文字短暂变化，不弹窗）。
    @State private var slotsResetFlash = false
    @State private var positionResetFlash = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                appearanceSection
                hubActionsSection
                hubStyleSection
                interactionSection
            }
            .padding(20)
        }
    }

    // MARK: - 球体外观

    private var appearanceSection: some View {
        SettingsSection(
            title: String(localized: "Ball"),
            subtitle: String(localized: "How the idle ball looks on the window edge."),
            icon: "circle.circle"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    String(localized: "Show Floating Ball"),
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
                SettingsRow(
                    String(localized: "Opacity"),
                    subtitle: String(localized: "Lower the opacity to keep the ball visible but unobtrusive. Hit area stays the same.")
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $ballOpacity, in: 0.4...1.0, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int(ballOpacity * 100))%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Idle Style"),
                    subtitle: String(localized: "Target ring is the AssistiveTouch-style idle mark; Agent icon makes the AI entry obvious at a glance.")
                ) {
                    Picker("", selection: $idleStyle) {
                        Text(String(localized: "Target Ring")).tag("ring")
                        Text(String(localized: "Agent Icon")).tag("icon")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Position"),
                    subtitle: String(localized: "Drag the ball to move it. Reset snaps it back to the middle of the left edge.")
                ) {
                    Button {
                        ball.resetPosition()
                        positionResetFlash = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            positionResetFlash = false
                        }
                    } label: {
                        Text(positionResetFlash
                             ? String(localized: "Reset ✓")
                             : String(localized: "Reset Position"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 触盘功能

    private var hubActionsSection: some View {
        SettingsSection(
            title: String(localized: "Hub Actions"),
            subtitle: String(localized: "Pick the four actions on the ball's radial hub. Choosing a capability that already occupies another slot swaps the two. Long-press the ball (or tap ⌄) reveals all eight."),
            icon: "square.grid.2x2"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    String(localized: "Hub Slots"),
                    subtitle: String(localized: "Slot order = layout order: 1·2 top row, 3·4 bottom row.")
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
                            // 74pt 曾把「Agent 对话」截成 "Age…"——按最长项
                            // （自定义提示词 5 字 + 箭头）给足宽度。
                            .frame(width: 108)
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Custom Prompt"),
                    subtitle: String(localized: "Sent as a new agent turn when the Custom Prompt hub slot is tapped.")
                ) {
                    TextField(String(localized: "e.g. Summarize this page and give me three takeaways"), text: $ball.customPrompt)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Reset Slots"),
                    subtitle: String(localized: "Restore the default four: Agent Chat, Voice, Summarize Page, Whiteboard.")
                ) {
                    Button {
                        ball.resetSlots()
                        slotsResetFlash = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            slotsResetFlash = false
                        }
                    } label: {
                        Text(slotsResetFlash
                             ? String(localized: "Reset ✓")
                             : String(localized: "Reset Slots"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 触盘样式

    private var hubStyleSection: some View {
        SettingsSection(
            title: String(localized: "Hub Style"),
            subtitle: String(localized: "How the expanded hub looks and moves."),
            icon: "paintpalette"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    String(localized: "Hub Size"),
                    subtitle: String(localized: "Scales the expanded hub and its buttons. Standard matches the V3 prototype.")
                ) {
                    Picker("", selection: $hubScale) {
                        Text(String(localized: "Compact")).tag(0.86)
                        Text(String(localized: "Standard")).tag(1.0)
                        Text(String(localized: "Roomy")).tag(1.14)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Expand Animation"),
                    subtitle: String(localized: "Bloom-in, staggered buttons and the opening sheen. Off = the hub appears instantly.")
                ) {
                    Toggle("", isOn: $hubAnimation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 交互

    private var interactionSection: some View {
        SettingsSection(
            title: String(localized: "Interaction"),
            subtitle: String(localized: "Gestures on the ball itself."),
            icon: "hand.tap"
        ) {
            SettingsRow(
                String(localized: "Double-Click Starts Voice"),
                subtitle: String(localized: "Double-clicking the ball jumps straight into voice input. Off = double-click counts as two regular clicks.")
            ) {
                Toggle("", isOn: $doubleClickVoice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
