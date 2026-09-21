import SwiftUI

/// The model/provider switcher, rendered as a small capsule in the input
/// bar's right group, next to the send button (the familiar chat-input
/// pattern: model dropdown beside send). Lists provider kinds and saved
/// endpoints only — capability toggles are their own inline controls.
struct AgentModelMenu: View {
    @ObservedObject var store: AgentSessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var isRefreshingModels = false

    var body: some View {
        Menu {
            Section("Models") {
                ForEach(availableModels.prefix(40), id: \.self) { model in
                    Button {
                        store.preference.model = model
                        store.preference.providerKind = .cloud
                    } label: {
                        Label(
                            model,
                            systemImage: store.preference.providerKind == .cloud && store.preference.model == model
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
                    store.preference.providerKind = .routing
                } label: {
                    Label("Auto (cloud + on-device)",
                          systemImage: store.preference.providerKind == .routing ? "checkmark" : "arrow.triangle.branch")
                }
                Button {
                    store.preference.providerKind = .foundationModels
                } label: {
                    Label("On-device (Foundation Models)",
                          systemImage: store.preference.providerKind == .foundationModels ? "checkmark" : "iphone.gen3")
                }
                Button {
                    store.preference.providerKind = .ollama
                } label: {
                    Label("Ollama (\(store.preference.ollamaModel))",
                          systemImage: store.preference.providerKind == .ollama ? "checkmark" : "server.rack")
                }
            }
            // 服务档案（内置预设 + 自定义服务）：切换 = 换端点 + 换模型 + 换 Key。
            Section("Services") {
                ForEach(store.preference.profiles) { profile in
                    Button {
                        store.preference.activateProfile(id: profile.id)
                        store.preference.providerKind = .cloud
                    } label: {
                        Label(
                            profile.model.isEmpty ? profile.name : "\(profile.name) — \(profile.model)",
                            systemImage: store.preference.activeProfileID == profile.id && store.preference.providerKind == .cloud
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
        let model = store.preference.model
        return model.isEmpty ? "No model" : model
    }

    /// 当前服务档案的模型候选：档案自己的清单 + 从 /models 拉回的缓存
    /// （去重、保持档案内的顺序）。
    private var availableModels: [String] {
        var seen = Set<String>()
        var models: [String] = []
        for model in (store.preference.activeProfile?.modelList ?? []) + store.preference.cachedModels {
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
            let endpoint = store.preference.endpoint
            let key = store.preference.loadAPIKey() ?? ""
            let models = (try? await ModelListFetcher.fetch(endpoint: endpoint, apiKey: key)) ?? []
            guard !models.isEmpty else { return }
            store.preference.cachedModels = models
            store.preference.applyModelList(models)
        }
    }
}
