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
    @State private var refreshingProfileIDs = Set<UUID>()

    var body: some View {
        Menu {
            // 顶层只列**当前服务**的模型（区名里写明是哪个服务），不再把各服务的
            // 模型拼在一个列表里。其它服务见下面各自的子菜单。
            Section(activeSectionTitle) {
                ForEach(activeModels.prefix(40), id: \.self) { model in
                    Button {
                        if let id = preference.activeProfile?.id {
                            preference.select(profileID: id, model: model)
                        }
                    } label: {
                        Label(
                            model,
                            systemImage: preference.providerKind == .cloud && preference.model == model
                                ? "checkmark" : "cpu"
                        )
                    }
                }
                if activeModels.isEmpty {
                    Text("No models for this service yet — refresh below")
                }
                if let profile = preference.activeProfile {
                    Button {
                        refreshModels(for: profile)
                    } label: {
                        Label(refreshingProfileIDs.contains(profile.id) ? "Refreshing…" : "Refresh Model List",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(refreshingProfileIDs.contains(profile.id))
                }
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
            // **两级联动**：服务 → 该服务自己的模型。选中某服务的某个模型 =
            // 切到该服务 + 设成这个模型（`select(profileID:model:)`）。
            Section("Services") {
                ForEach(preference.profiles) { profile in
                    Menu {
                        let models = models(for: profile)
                        if models.isEmpty {
                            Text("No models yet — refresh below")
                        }
                        ForEach(models.prefix(40), id: \.self) { model in
                            Button {
                                preference.select(profileID: profile.id, model: model)
                            } label: {
                                Label(
                                    model,
                                    systemImage: isPicked(profile: profile, model: model) ? "checkmark" : "cpu"
                                )
                            }
                        }
                        Divider()
                        Button {
                            refreshModels(for: profile)
                        } label: {
                            Label(refreshingProfileIDs.contains(profile.id) ? "Refreshing…" : "Refresh Model List",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshingProfileIDs.contains(profile.id))
                    } label: {
                        Label(
                            profile.name,
                            systemImage: isActive(profile)
                                ? "checkmark"
                                : (profile.model.isEmpty ? "globe" : "globe.badge.chevron.backward")
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
            .padding(.horizontal, 9)
            // 与输入栏其它控件同高、同描边；`.tint(.secondary)` 是为了挡住强调色
            // 渗进菜单标签——实测模型名会被染成强调色（用户强调色是红时像报错）。
            .frame(height: 26)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )
            .frame(maxWidth: 130)
        }
        .tint(.secondary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(preference.activeProfile.map { "\($0.name) · \(displayModel)" } ?? displayModel)
    }

    private var displayModel: String {
        let model = preference.model
        return model.isEmpty ? "No model" : model
    }

    /// 某个服务自己的模型候选：**它的当前模型** + 它的 `modelList`（去重、保持顺序）。
    /// 当前模型永远在头部——否则用户看不到自己在用哪个。
    /// **不再掺任何跨服务的缓存**：模型归属谁，就只出现在谁的子菜单里。
    private func models(for profile: AIProviderProfile) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for model in [profile.model] + profile.modelList where !model.isEmpty && !seen.contains(model) {
            seen.insert(model)
            out.append(model)
        }
        return out
    }

    private var activeModels: [String] {
        preference.activeProfile.map(models(for:)) ?? []
    }

    private var activeSectionTitle: String {
        guard let name = preference.activeProfile?.name, !name.isEmpty else { return "Models" }
        return "\(name) — Models"
    }

    private func isActive(_ profile: AIProviderProfile) -> Bool {
        preference.activeProfileID == profile.id && preference.providerKind == .cloud
    }

    private func isPicked(profile: AIProviderProfile, model: String) -> Bool {
        isActive(profile) && preference.model == model
    }

    /// 从**这个服务自己的**端点 + Key 拉取模型列表，并写进**它自己**的档案。
    /// （以前无论刷新谁都拿当前服务的端点，刷新别的服务就会写错地方。）
    private func refreshModels(for profile: AIProviderProfile) {
        guard !refreshingProfileIDs.contains(profile.id) else { return }
        refreshingProfileIDs.insert(profile.id)
        Task { @MainActor in
            defer { refreshingProfileIDs.remove(profile.id) }
            let key = preference.loadAPIKey(profileID: profile.id) ?? ""
            let models = (try? await ModelListFetcher.fetch(endpoint: profile.endpoint, apiKey: key)) ?? []
            guard !models.isEmpty else { return }
            preference.applyModelList(models, to: profile.id)
        }
    }
}
