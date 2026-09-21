import SwiftUI

/// The model/provider switcher, rendered as a small capsule in the input
/// bar's right group, next to the send button (the familiar chat-input
/// pattern: model dropdown beside send). Lists provider kinds and saved
/// endpoints only — capability toggles are their own inline controls.
struct AgentModelMenu: View {
    @ObservedObject var store: AgentSessionStore
    /// **必须单独观察偏好 store**：模型/服务/provider 都是它的状态，而
    /// `AgentSessionStore` 不会转发 `preference.objectWillChange`——只观察会话
    /// store 的话，点选模型后数据变了、菜单里的标签与勾选却不会重绘，看起来就是
    /// "切换不起作用"。
    @ObservedObject var preference: AgentPreferenceStore
    @Environment(\.openWindow) private var openWindow
    @State private var isRefreshingModels = false

    var body: some View {
        Menu {
            Section("Models") {
                ForEach(availableModels.prefix(40), id: \.self) { model in
                    Button {
                        preference.model = model
                        preference.providerKind = .cloud
                    } label: {
                        Label(
                            model,
                            systemImage: preference.providerKind == .cloud && preference.model == model
                                ? "checkmark" : "cpu"
                        )
                    }
                }
                if availableModels.isEmpty {
                    Text("No models yet — refresh, or add one in Settings → Agent")
                }
                Button {
                    refreshModels()
                } label: {
                    Label(isRefreshingModels ? "Refreshing…" : "Refresh Model List",
                          systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshingModels)
            }
            Section("Provider") {
                Button {
                    preference.providerKind = .routing
                } label: {
                    Label("Auto (cloud + on-device)",
                          systemImage: preference.providerKind == .routing ? "checkmark" : "arrow.triangle.branch")
                }
                Button {
                    preference.providerKind = .foundationModels
                } label: {
                    Label("On-device (Foundation Models)",
                          systemImage: preference.providerKind == .foundationModels ? "checkmark" : "iphone.gen3")
                }
                Button {
                    preference.providerKind = .ollama
                } label: {
                    Label("Ollama (\(preference.ollamaModel))",
                          systemImage: preference.providerKind == .ollama ? "checkmark" : "server.rack")
                }
            }
            // 服务档案（内置预设 + 自定义服务）：切换 = 换端点 + 换模型 + 换 Key。
            Section("Services") {
                ForEach(preference.profiles) { profile in
                    Button {
                        preference.activateProfile(id: profile.id)
                        preference.providerKind = .cloud
                    } label: {
                        Label(
                            profile.model.isEmpty ? profile.name : "\(profile.name) — \(profile.model)",
                            systemImage: preference.activeProfileID == profile.id && preference.providerKind == .cloud
                                ? "checkmark" : "globe"
                        )
                    }
                }
                Button {
                    openWindow(id: "settings")
                } label: {
                    Label("Manage Services…", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .medium))
                Text(displayModel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )
            .frame(maxWidth: 130)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch model / provider")
    }

    private var displayModel: String {
        let model = preference.model
        return model.isEmpty ? "No model" : model
    }

    /// 当前服务档案的模型候选：**当前模型** + 档案自己的清单 + 从 /models 拉回的
    /// 缓存（去重、保持顺序）。当前模型永远在列表头部——否则用户看不到自己在用
    /// 哪个，"切回默认"也无从下手。
    private var availableModels: [String] {
        var seen = Set<String>()
        var models: [String] = []
        let candidates = [preference.activeProfile?.model ?? ""]
            + (preference.activeProfile?.modelList ?? [])
            + preference.cachedModels
        for model in candidates {
            guard !model.isEmpty, !seen.contains(model) else { continue }
            seen.insert(model)
            models.append(model)
        }
        return models
    }

    /// 从当前服务的 /models 拉取模型列表：写进该档案（换服务时各看各的），
    /// 同时更新 input bar 的缓存。
    private func refreshModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        Task {
            defer { isRefreshingModels = false }
            let endpoint = preference.endpoint
            let key = preference.loadAPIKey() ?? ""
            let models = (try? await ModelListFetcher.fetch(endpoint: endpoint, apiKey: key)) ?? []
            guard !models.isEmpty else { return }
            preference.cachedModels = models
            preference.applyModelList(models)
        }
    }
}
