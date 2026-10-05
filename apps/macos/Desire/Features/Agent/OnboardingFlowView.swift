import SwiftUI
import FoundationModels

/// 首启三步引导（0.6.7）：模型 → 隐私 → 同步与个性化。
/// 每步可跳过；完成写 memory.onboardingCompleted（面板不再显示）。
struct OnboardingFlowView: View {
    var onFinish: () -> Void

    @ObservedObject private var memory = AgentMemoryStore.shared
    /// 全局 store 走 AppState.live（同 AutomationServer 模式）；缺席时各步降级。
    private var preference: AgentPreferenceStore? { AppState.live?.aiPreference }
    private var contentBlocker: ContentBlockerStore? { AppState.live?.contentBlocker }
    private var syncStore: SyncStore? { AppState.live?.syncStore }

    @Environment(\.appAccent) private var appAccent
    @State private var step = 0
    @State private var name = ""
    @State private var custom = ""
    @State private var onDeviceAvailable = false
    private var stepTitles = ["选模型", "隐私防护", "同步与个性化"]

    var body: some View {
        VStack(spacing: 0) {
            progressDots
            Divider().opacity(0.5)
            Group {
                if step == 0 { modelStep }
                if step == 1 { privacyStep }
                if step == 2 { syncProfileStep }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(maxWidth: 460, maxHeight: 520)
        .onAppear {
            if case .available = SystemLanguageModel.default.availability {
                onDeviceAvailable = true
            }
        }
    }

    // MARK: - 进度点

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == step ? appAccent : Color.secondary.opacity(0.3))
                    .frame(width: i == step ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
            Spacer()
            Text(stepTitles[step])
                .font(.system(size: 12, weight: .semibold))
            Text("第 \(step + 1)/3 步")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Step 1 模型

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(icon: "cpu", title: "选一个智能体大脑",
                       detail: "随时可在 Agent 设置里切换。")
            if onDeviceAvailable {
                optionCard(icon: "apple.logo", title: "macOS 端上模型",
                           detail: "零配置零网络，Apple 智能（文本能力）。") {
                    preference?.providerKind = .foundationModels
                    step = 1
                }
            }
            optionCard(icon: "key.fill", title: "配置 API Key",
                       detail: "OpenAI / DeepSeek / 智谱 / 任意兼容端点。") {
                preference?.providerKind = .cloud
                NotificationCenter.default.post(name: Notification.Name("openAISettings"), object: nil)
                step = 1
            }
            if preference == nil {
                Text("设置暂不可用——可在设置 → AI 里稍后配置。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("下一步") { step = 1 }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 2 隐私

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(icon: "shield.lefthalf.filled", title: "隐私防护",
                       detail: "内置广告/追踪拦截，默认开启；可随时在设置 → 隐私调整。")
            if let contentBlocker {
                Toggle(isOn: Binding(get: { contentBlocker.isBlockingEnabled },
                                     set: { contentBlocker.isBlockingEnabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拦截广告").font(.system(size: 13, weight: .medium))
                        Text("EasyList 内容规则").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: Binding(get: { contentBlocker.isTrackingEnabled },
                                     set: { contentBlocker.isTrackingEnabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拦截追踪器").font(.system(size: 13, weight: .medium))
                        Text("已知追踪与分析请求").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } else {
                Text("设置暂不可用，稍后可在设置 → 隐私开启。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack {
                Button("上一步") { step = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("下一步") { step = 2 }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 3 同步与个性化

    private var syncProfileStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(icon: "person.2", title: "同步与个性化（均可选）",
                       detail: "端到端加密跨设备同步；个性化偏好只影响 Agent 的语气。")
            HStack {
                if let syncStore, case .signedIn(let username) = syncStore.authState {
                    Label("已登录：\(username)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Button("配置同步（设置页）") {
                        NotificationCenter.default.post(name: Notification.Name("openSyncSettings"), object: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
            Divider().opacity(0.4)
            Text("个性化（可选）").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            field("称呼", text: $name, placeholder: "怎么称呼你")
            field("自定义指令", text: $custom, placeholder: "例：用中文回答；简洁直接")
            Spacer()
            HStack {
                Button("跳过") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成，开始使用") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 通用件

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("上一步") { step -= 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("跳过") {
                if step == 2 { finish() } else { step = 2 }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func stepHeader(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionCard(icon: String, title: String, detail: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(appAccent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
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

    private func finish() {
        memory.updateProfile { profile in
            profile.name = name.trimmingCharacters(in: .whitespaces)
            profile.customInstructions = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        memory.completeOnboarding()
        onFinish()
    }
}
