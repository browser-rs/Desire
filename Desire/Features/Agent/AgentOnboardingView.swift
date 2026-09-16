import SwiftUI

/// First-run onboarding: collects the L0 user profile (how to address you,
/// reply language/style, custom instructions) so the very first session
/// already feels personalized. Skippable — everything is editable later in
/// the memory view.
struct AgentOnboardingView: View {
    @ObservedObject private var memory = AgentMemoryStore.shared

    @State private var name = ""
    @State private var language = "自动"
    @State private var style = "平衡"
    @State private var custom = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    field("怎么称呼你", text: $name, placeholder: "可选，例如：Kong")
                    field("偏好回复语言", text: $language, placeholder: "自动 / 中文 / English")
                    field("回复风格", text: $style, placeholder: "简洁 / 平衡 / 详细")

                    VStack(alignment: .leading, spacing: 5) {
                        Text("自定义指令")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $custom)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 64, maxHeight: 110)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                            )
                    }

                    Text("之后的使用中，Agent 会在后台慢慢学习你的习惯（可在「记忆」中查看和删除）。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                )

                HStack(spacing: 10) {
                    Button("跳过") {
                        memory.completeOnboarding()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        memory.updateProfile { profile in
                            profile.name = name.trimmingCharacters(in: .whitespaces)
                            profile.language = language == "自动" ? "" : language
                            profile.style = style == "平衡" ? "" : style
                            profile.customInstructions = custom.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        memory.completeOnboarding()
                    } label: {
                        Text("开始使用")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
            Text("让我们认识一下")
                .font(.system(size: 17, weight: .bold))
            Text("花 10 秒设置偏好，之后每次对话都会生效。全部可随时修改。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        }
    }
}
