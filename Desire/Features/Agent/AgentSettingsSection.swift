import AppKit
import FoundationModels
import SwiftUI

private enum ModelPreset: String, CaseIterable {
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case o3Mini = "o3-mini"
    case claude35Sonnet = "claude-3-5-sonnet-20241022"
    case claude35Haiku = "claude-3-5-haiku-20241022"
    case deepseekV3 = "deepseek-chat"
    case deepseekV4Flash = "deepseek-v4-flash"
    case deepseekV4Pro = "deepseek-v4-pro"
    case custom = ""

    var displayName: String {
        switch self {
        case .gpt4o: "OpenAI GPT-4o"
        case .gpt4oMini: "OpenAI GPT-4o Mini"
        case .o3Mini: "OpenAI o3 Mini"
        case .claude35Sonnet: "Anthropic Claude 3.5 Sonnet"
        case .claude35Haiku: "Anthropic Claude 3.5 Haiku"
        case .deepseekV3: "DeepSeek V3"
        case .deepseekV4Flash: "DeepSeek V4 Flash"
        case .deepseekV4Pro: "DeepSeek V4 Pro"
        case .custom: "Custom…"
        }
    }

    static func matching(_ model: String) -> ModelPreset {
        Self.allCases.first(where: { $0.rawValue == model && $0 != .custom }) ?? .custom
    }
}

struct AgentSettingsSection: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: AgentPreferenceStore

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var cloudTestStatus: String?
    @State private var isTestingCloud = false
    @State private var ollamaTestStatus: String?
    @State private var isTestingOllama = false
    /// Models fetched from the API's `/models` endpoint (nil = not fetched).
    @State private var fetchedModels: [String]? = nil
    @State private var isFetchingModels = false

    // MARK: 服务档案编辑器（模型服务的一等公民，见 AIProviderProfile）
    /// 正在编辑的档案（nil = 没在编辑；`newProfileID` 表示这是一个新档案）。
    @State private var editingProfileID: UUID?
    @State private var draftName = ""
    @State private var draftEndpoint = ""
    @State private var draftModel = ""
    @State private var draftKey = ""
    @State private var draftModels: [String] = []
    @State private var draftHeaders: [HeaderDraft] = []
    @State private var newModelName = ""

    struct HeaderDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }
    @State private var newBinary = ""
    @State private var workspaceRefresh = 0
    private func addBinary() {
        SystemCommandStore.shared.allow(newBinary)
        newBinary = ""
    }

    var body: some View {
        SettingsContainer {
            ScheduledTasksSection()
            MCPServersSection()
            SettingsSection(
                title: String(localized: "Provider"),
                subtitle: store.providerKind.detail,
                icon: "brain.head.profile"
            ) {
                VStack(spacing: 8) {
                    ForEach(ModelProviderKind.allCases, id: \.self) { kind in
                        ProviderCard(
                            title: kind.displayName,
                            subtitle: kind.tagline,
                            systemImage: kind.icon,
                            isSelected: store.providerKind == kind
                        ) {
                            store.providerKind = kind
                        }
                    }
                }
                .padding(12)
            }

            // MARK: - Provider-specific config

            if store.providerKind == .foundationModels {
                foundationModelsSection
            }

            if store.providerKind == .cloud {
                cloudSection
            }

            if store.providerKind == .ollama {
                ollamaSection
            }

            // MARK: - Generation params (shared)

            SettingsSection(
                title: String(localized: "Generation"),
                subtitle: String(localized: "Applies to all providers."),
                icon: "slider.horizontal.3"
            ) {
                VStack(spacing: 0) {
                    SettingsRow(String(localized: "Max Tokens"), subtitle: String(localized: "Upper bound on completion length."), systemImage: "text.alignleft") {
                        SettingsTextField(
                            placeholder: "1024",
                            text: Binding(
                                get: { String(store.maxTokens) },
                                set: { newValue in store.maxTokens = Int(newValue) ?? store.maxTokens }
                            ),
                            width: 80
                        )
                    }
                    SettingsRowDivider()
                    SettingsRow(String(localized: "Temperature"), subtitle: String(localized: "Higher values produce more varied responses."), systemImage: "thermometer.medium") {
                        HStack(spacing: 8) {
                            Slider(value: $store.temperature, in: 0...2, step: 0.1)
                                .frame(width: 140)
                            Text(String(format: "%.1f", store.temperature))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                    SettingsRowDivider()
                    SettingsRow(String(localized: "Max Steps"), subtitle: String(localized: "Upper bound on agent tool-loop iterations per turn (5–200)."), systemImage: "repeat") {
                        SettingsTextField(
                            placeholder: "50",
                            text: Binding(
                                get: { String(store.maxLoopIterations) },
                                set: { newValue in store.maxLoopIterations = Int(newValue) ?? store.maxLoopIterations }
                            ),
                            width: 80
                        )
                    }
                }
            }

            // MARK: - System Prompt

            SettingsSection(
                title: String(localized: "System Prompt"),
                subtitle: String(localized: "Sent to the model on every request. Leave empty to use the default."),
                icon: "text.book.closed"
            ) {
                TextEditor(text: $store.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                    .padding(12)
            }

            // MARK: - System access (CLI allowlist)

            SettingsSection(
                title: String(localized: "System Access (CLI)"),
                subtitle: String(localized: "Binaries the agent may run via runCommand. Argv-only, no shell; every call prompts unless FULL ACCESS is on."),
                icon: "terminal"
            ) {
                VStack(spacing: 0) {
                    // Working directory
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.secondary.opacity(0.08)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "Working Directory"))
                                .font(.system(size: 12, weight: .medium))
                            Text(SystemCommandStore.shared.workingDirectoryText)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(String(localized: "Choose…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.directoryURL = SystemCommandStore.shared.workingDirectory
                            if panel.runModal() == .OK, let url = panel.url {
                                SystemCommandStore.shared.setWorkingDirectory(url)
                            }
                        }
                        .buttonStyle(.plain)
                        Button(String(localized: "Reset")) {
                            SystemCommandStore.shared.resetWorkingDirectory()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    SettingsRowDivider()

                    HStack(spacing: 6) {
                        TextField("Add binary name…", text: $newBinary)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(addBinary)
                        Button {
                            addBinary()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(appAccent)
                        }
                        .buttonStyle(.plain)
                        .disabled(newBinary.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    ForEach(Array(SystemCommandStore.shared.allowedBinaries.sorted().enumerated()), id: \.element) { index, binary in
                        HStack(spacing: 10) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.secondary.opacity(0.08)))
                            Text(binary)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button {
                                SystemCommandStore.shared.disallow(binary)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from allowlist")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if index < SystemCommandStore.shared.allowedBinaries.count - 1 {
                            SettingsRowDivider()
                        }
                    }

                    HStack {
                        Button(String(localized: "Open Skills Folder")) {
                            NSWorkspace.shared.open(SkillStore.directory)
                        }
                        Spacer()
                        Text(String(localized: "Skills are SKILL.md files; drop your own in to extend the agent."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }

            // MARK: - Agent context

            SettingsSection(
                title: String(localized: "Agent Context"),
                subtitle: String(localized: "What the agent knows about the page you're on."),
                icon: "scope"
            ) {
                SettingsToggleRow(
                    "Auto Page Context",
                    subtitle: String(localized: "Attach a compact summary of the current page (title, URL, text excerpt) to every request. Off means the agent must call getPageSnapshot itself."),
                    systemImage: "doc.text.magnifyingglass",
                    isOn: $store.autoPageContext
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Completion Sound",
                    subtitle: String(localized: "Play a soft chime when the agent finishes a turn."),
                    systemImage: "speaker.wave.1",
                    isOn: $store.completionSound
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Memory Learning",
                    subtitle: String(localized: "After agent turns, extract durable user preferences and conversation summaries into long-term memory. Inspect and delete anything in the panel's memory view."),
                    systemImage: "brain.head.profile",
                    isOn: $store.memoryLearning
                )
            }

            // MARK: - Allowed Tools

            if !store.allowedTools.isEmpty {
                SettingsSection(
                    title: String(localized: "Always-Allowed Tools"),
                    subtitle: String(localized: "These tools will run without asking for approval each time."),
                    icon: "checkmark.shield"
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.allowedTools.sorted().enumerated()), id: \.element) { index, tool in
                            HStack(spacing: 10) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.secondary.opacity(0.08)))
                                Text(tool)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    var current = store.allowedTools
                                    current.remove(tool)
                                    store.allowedTools = current
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from always-allowed")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if index < store.allowedTools.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                        SettingsRowDivider()
                        SettingsActionRow(
                            "Reset All",
                            subtitle: String(localized: "Clear the always-allowed list and prompt again next time."),
                            systemImage: "arrow.counterclockwise",
                            buttonTitle: String(localized: "Reset")
                        ) {
                            store.allowedTools = []
                        }
                    }
                }
            }
        }
        .onAppear {
            apiKey = store.loadAPIKey() ?? ""
        }
        .onChange(of: store.activeProfileID) { _, _ in
            // 换服务 = 换端点 + 换模型 + 换 Key（每个服务各存各的）。
            apiKey = store.loadAPIKey() ?? ""
        }
    }

    /// 编辑器里的模型 chip（横向滚动，点叉移除）。
    private struct FlowChips: View {
        let models: [String]
        let onRemove: (String) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(models, id: \.self) { model in
                        HStack(spacing: 3) {
                            Text(model)
                                .font(.system(size: 10.5, design: .monospaced))
                            Button { onRemove(model) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
        }
    }

    // MARK: - Foundation Models section

    @ViewBuilder
    private var foundationModelsSection: some View {
        SettingsSection(
            title: "Apple Intelligence",
            subtitle: String(localized: "On-device model. No credentials required."),
            icon: "apple.logo"
        ) {
            VStack(spacing: 0) {
                SettingsRow(String(localized: "Status"), subtitle: String(localized: "Whether the system model is available right now."), systemImage: "dot.radiowaves.left.and.right") {
                    statusView
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            StatusPill(text: "Available", kind: .success)
        case .unavailable(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                StatusPill(text: "Unavailable", kind: .warning)
                Text(availabilityDetail(reason))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }

    private func availabilityDetail(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Enable Apple Intelligence in System Settings."
        case .modelNotReady: "The on-device model is still preparing."
        @unknown default: "Apple Intelligence is unavailable on this Mac."
        }
    }

    // MARK: - Cloud section

    /// 模型服务：内置预设 + 自定义服务，**每个服务自带端点 / 模型 / 请求头 /
    /// API Key**（此前只有 4 个写死的预设，自定义端点只能串用某个预设的 Key）。
    @ViewBuilder
    private var cloudSection: some View {
        SettingsSection(
            title: String(localized: "Model Services"),
            subtitle: String(localized: "Each service carries its own endpoint, model, headers and API key."),
            icon: "cloud"
        ) {
            VStack(spacing: 0) {
                ForEach(store.profiles) { profile in
                    serviceRow(profile)
                    SettingsRowDivider()
                }

                if editingProfileID == nil {
                    Button {
                        beginEditing(profile: nil)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(appAccent)
                            Text(String(localized: "Add Custom Service"))
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    serviceEditor
                }
            }
        }
    }

    /// 一个服务档案：名字 + 主机·模型 + Key 状态；点一下切成当前服务。
    @ViewBuilder
    private func serviceRow(_ profile: AIProviderProfile) -> some View {
        let isActive = store.activeProfileID == profile.id && store.providerKind == .cloud
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? appAccent : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if profile.isBuiltin {
                        Text(String(localized: "Built-in"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }
                Text("\(profile.host) · \(profile.model.isEmpty ? String(localized: "no model") : profile.model)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            StatusPill(
                text: store.loadAPIKey(profileID: profile.id) == nil
                    ? String(localized: "No key")
                    : String(localized: "Key saved"),
                kind: store.loadAPIKey(profileID: profile.id) == nil ? .warning : .success
            )

            HStack(spacing: 2) {
                Button { beginEditing(profile: profile) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit")

                Button { store.duplicateProfile(id: profile.id) } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Duplicate")

                if !profile.isBuiltin {
                    Button {
                        if store.activeProfileID == profile.id { store.providerKind = .cloud }
                        store.deleteProfile(id: profile.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            store.activateProfile(id: profile.id)
            store.providerKind = .cloud
        }
    }

    /// 行内编辑器：新增时 `editingProfileID` 是一个新 UUID（保存时才入库）。
    @ViewBuilder
    private var serviceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorField(String(localized: "Name"), text: $draftName, placeholder: "My gateway")
            editorField(String(localized: "Endpoint URL"), text: $draftEndpoint, placeholder: "https://host/v1/chat/completions")
            editorField(String(localized: "Model"), text: $draftModel, placeholder: "gpt-4o")

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "API Key"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SettingsTextField(placeholder: "sk-…", text: $draftKey, isSecure: !showKey, width: 240)
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 模型清单（这个服务自己的候选模型）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(localized: "Models"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button { fetchDraftModels() } label: {
                        HStack(spacing: 3) {
                            if isFetchingModels { ProgressView().scaleEffect(0.45) }
                            Text(isFetchingModels ? "Fetching…" : "Fetch from API")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isFetchingModels || draftEndpoint.isEmpty)
                }
                if !draftModels.isEmpty {
                    FlowChips(models: draftModels) { model in
                        draftModels.removeAll { $0 == model }
                    }
                }
                HStack(spacing: 6) {
                    SettingsTextField(placeholder: "add a model name…", text: $newModelName, width: 180)
                    Button {
                        let name = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !draftModels.contains(name) else { return }
                        draftModels.append(name)
                        newModelName = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(newModelName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            // 额外请求头（自定义网关常见）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(localized: "Extra Headers"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        draftHeaders.append(HeaderDraft(name: "", value: ""))
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                }
                ForEach($draftHeaders) { $header in
                    HStack(spacing: 6) {
                        SettingsTextField(placeholder: "X-Tenant", text: $header.name, width: 120)
                        SettingsTextField(placeholder: "value", text: $header.value, width: 150)
                        Button {
                            draftHeaders.removeAll { $0.id == header.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                Button { commitEditor() } label: {
                    Text(String(localized: "Save Service"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(appAccent.opacity(0.18)))
                        .foregroundStyle(appAccent)
                }
                .buttonStyle(.plain)
                .disabled(draftEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)

                Button { cancelEditing() } label: {
                    Text(String(localized: "Cancel"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                .buttonStyle(.plain)

                Button { testConnection() } label: {
                    HStack(spacing: 4) {
                        if isTestingCloud { ProgressView().scaleEffect(0.5) }
                        Text(isTestingCloud ? "Testing…" : "Test Connection")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(isTestingCloud || draftEndpoint.isEmpty)

                if let status = cloudTestStatus {
                    StatusPill(text: status, kind: status == "Connected ✓" ? .success : .error)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func editorField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            SettingsTextField(placeholder: placeholder, text: text, width: 280)
        }
    }

    private func beginEditing(profile: AIProviderProfile?) {
        editingProfileID = profile?.id ?? UUID()
        draftName = profile?.name ?? ""
        draftEndpoint = profile?.endpoint ?? ""
        draftModel = profile?.model ?? ""
        draftKey = profile.flatMap { store.loadAPIKey(profileID: $0.id) } ?? ""
        draftModels = profile?.modelList ?? []
        draftHeaders = (profile?.headers ?? [:]).sorted { $0.key < $1.key }.map { HeaderDraft(name: $0.key, value: $0.value) }
        cloudTestStatus = nil
    }

    private func cancelEditing() {
        editingProfileID = nil
        cloudTestStatus = nil
    }

    /// 保存编辑器内容：新档案入库并切成当前服务；已有档案就地更新。
    private func commitEditor() {
        let endpoint = draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return }

        var headers: [String: String] = [:]
        for draft in draftHeaders {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            headers[name] = draft.value
        }

        if let id = editingProfileID, let index = store.profiles.firstIndex(where: { $0.id == id }) {
            store.profiles[index].name = draftName.isEmpty ? store.profiles[index].name : draftName
            store.profiles[index].endpoint = endpoint
            store.profiles[index].model = draftModel
            store.profiles[index].modelList = draftModels
            store.profiles[index].headers = headers
            store.activeProfileID = id
        } else {
            let profile = store.addProfile(name: draftName, endpoint: endpoint, model: draftModel)
            if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
                store.profiles[index].modelList = draftModels
                store.profiles[index].headers = headers
            }
            store.activeProfileID = profile.id
        }

        if !draftKey.trimmingCharacters(in: .whitespaces).isEmpty {
            store.saveAPIKey(draftKey, profileID: store.activeProfileID)
        }
        store.providerKind = .cloud
        editingProfileID = nil
        cloudTestStatus = nil
    }

    /// 编辑器里的"从 API 拉模型"：写进草稿清单（保存时才落库）。
    private func fetchDraftModels() {
        isFetchingModels = true
        let endpoint = draftEndpoint
        let key = draftKey.isEmpty ? (store.loadAPIKey() ?? "") : draftKey
        Task {
            let models = (try? await ModelListFetcher.fetch(endpoint: endpoint, apiKey: key)) ?? []
            isFetchingModels = false
            for model in models where !draftModels.contains(model) {
                draftModels.append(model)
            }
            fetchedModels = models
            if models.isEmpty { cloudTestStatus = "No models" }
        }
    }

    // MARK: - Ollama section

    @ViewBuilder
    private var ollamaSection: some View {
        SettingsSection(
            title: "Ollama",
            subtitle: String(localized: "Local model server. Run ollama serve and pull a model first."),
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                SettingsRow(String(localized: "Ollama Host"), subtitle: String(localized: "Base URL of the running ollama daemon."), systemImage: "network") {
                    SettingsTextField(placeholder: "http://127.0.0.1:11434", text: $store.ollamaHost, width: 220)
                }
                SettingsRowDivider()
                SettingsRow(String(localized: "Model"), subtitle: String(localized: "A model pulled on the server (llama3.2, qwen2.5, …)."), systemImage: "cpu") {
                    SettingsTextField(placeholder: "llama3.2", text: $store.ollamaModel, width: 200)
                }
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Button {
                        testOllama()
                    } label: {
                        HStack(spacing: 4) {
                            if isTestingOllama { ProgressView().scaleEffect(0.5) }
                            Text(isTestingOllama ? "Testing…" : "Test")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingOllama)

                    if let status = ollamaTestStatus {
                        StatusPill(text: status, kind: status == "Connected" ? .success : .error)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Test connection

    private func testOllama() {
        isTestingOllama = true
        ollamaTestStatus = nil
        Task {
            defer { isTestingOllama = false }
            let base = store.ollamaHost
            let urlStr = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
            guard let url = URL(string: urlStr) else {
                ollamaTestStatus = "Invalid host"
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": store.ollamaModel,
                "messages": [["role": "user", "content": "Respond with 'ok'"]],
                "max_tokens": 10,
            ])
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    ollamaTestStatus = "Connected"
                } else if let http = response as? HTTPURLResponse {
                    ollamaTestStatus = "HTTP \(http.statusCode)"
                }
            } catch {
                ollamaTestStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() {
        isTestingCloud = true
        cloudTestStatus = nil
        Task {
            defer { isTestingCloud = false }
            // 编辑器开着就测草稿（还没保存的服务），否则测当前服务。
            let editing = editingProfileID != nil
            let key = editing ? draftKey : (store.loadAPIKey() ?? "")
            let endpoint = editing ? draftEndpoint : store.endpoint
            let model = editing ? draftModel : store.model

            let urlStr = endpoint.hasSuffix("/chat/completions") ? endpoint : endpoint + "/chat/completions"
            guard let url = URL(string: urlStr) else {
                cloudTestStatus = "Invalid endpoint"
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if urlStr.contains("opencode") {
                let sid = UserDefaults.standard.string(forKey: "aiOpencodeSessionID")
                    ?? UUID().uuidString
                UserDefaults.standard.set(sid, forKey: "aiOpencodeSessionID")
                req.setValue(sid, forHTTPHeaderField: "x-opencode-session")
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": "Respond with 'ok'"]],
                "max_tokens": 10,
                "stream": false,
            ])

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let body = String(data: data, encoding: .utf8) ?? ""
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    cloudTestStatus = "Connected ✓"
                } else if let http = response as? HTTPURLResponse {
                    // Show the server's error message so the user knows WHY.
                    let serverMsg = body.prefix(200)
                    cloudTestStatus = "HTTP \(http.statusCode): \(serverMsg)"
                }
            } catch {
                cloudTestStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - ProviderKind extras

extension ModelProviderKind {
    var tagline: String {
        switch self {
        case .foundationModels: "On-device, free, private."
        case .cloud: "OpenAI, Anthropic, DeepSeek, and more."
        case .ollama: "Self-hosted local server."
        case .routing: "Auto-pick the best model per task."
        }
    }

    var icon: String {
        switch self {
        case .foundationModels: "apple.logo"
        case .cloud: "cloud"
        case .ollama: "server.rack"
        case .routing: "arrow.triangle.branch"
        }
    }
}


// MARK: - MCP Servers

/// Manages remote MCP servers whose tools are bridged into the agent's
/// tool table (`MCPStore`). Experimental: HTTP transport only.
struct MCPServersSection: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store = MCPStore.shared
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newToken = ""
    /// Per-server auth-token editing state (server id → draft token).
    @State private var tokenDrafts: [UUID: String] = [:]
    /// Per-server expanded tool list disclosure.
    @State private var expandedTools: Set<UUID> = []

    var body: some View {
        SettingsSection(
            title: String(localized: "MCP Servers"),
            subtitle: String(localized: "Extend the Agent with external tools over MCP (HTTP transport). Experimental."),
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                if store.servers.isEmpty {
                    Text(String(localized: "No MCP servers configured. Add a Streamable HTTP endpoint (e.g. a local mcp-proxy)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                ForEach(store.servers) { server in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { server.isEnabled },
                            set: { store.setEnabled($0, for: server.id) }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(server.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(store.statuses[server.id] ?? (server.isEnabled ? "—" : "disabled"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            store.reconnect(server.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Reconnect")
                        Button {
                            store.removeServer(server.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.vertical, 4)

                    // Tools exposed by this server — the model sees only the
                    // bridged names, so users need the raw list to debug.
                    if !store.toolNames(for: server.id).isEmpty {
                        let names = store.toolNames(for: server.id)
                        Button {
                            if expandedTools.contains(server.id) {
                                expandedTools.remove(server.id)
                            } else {
                                expandedTools.insert(server.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .rotationEffect(.degrees(expandedTools.contains(server.id) ? 180 : 0))
                                Text("\(names.count) tools")
                                    .font(.caption2)
                                Text(names.prefix(4).joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        if expandedTools.contains(server.id) {
                            Text(names.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                        SettingsRowDivider()
                    }

                    // Bearer token (many MCP servers sit behind an auth proxy).
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        SecureField("Bearer token (optional)", text: Binding(
                            get: { tokenDrafts[server.id] ?? server.authToken ?? "" },
                            set: { tokenDrafts[server.id] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        if tokenDrafts[server.id] != nil {
                            Button(String(localized: "Save")) {
                                store.updateAuthToken(tokenDrafts[server.id] ?? "", for: server.id)
                                tokenDrafts[server.id] = nil
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(appAccent)
                        }
                    }
                    .padding(.bottom, 6)

                    SettingsRowDivider()
                }

                HStack {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("http://127.0.0.1:3000/mcp", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "Add")) {
                        store.addServer(name: newName, url: newURL)
                        if !newToken.trimmingCharacters(in: .whitespaces).isEmpty,
                           let added = store.servers.last {
                            store.updateAuthToken(newToken, for: added.id)
                        }
                        newName = ""
                        newURL = ""
                        newToken = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// Scheduled agent prompts (定时任务) — created by the agent itself via the
/// scheduleTask tools; managed (enable/disable/delete) here.
struct ScheduledTasksSection: View {
    @ObservedObject private var store = AgentScheduler.shared

    var body: some View {
        SettingsSection(
            title: String(localized: "Scheduled Tasks"),
            subtitle: String(localized: "Prompts that re-run automatically while the app is open. Ask the agent to create one, e.g. 「每天 9 点总结我的待办」."),
            icon: "clock.badge.checkmark"
        ) {
            VStack(spacing: 0) {
                if store.tasks.isEmpty {
                    Text(String(localized: "No scheduled tasks yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                ForEach(store.tasks) { task in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { task.isEnabled },
                            set: { store.setEnabled($0, for: task.id) }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(task.recurrenceText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let result = task.lastResult {
                                Text(result)
                                    .font(.caption2)
                                    .foregroundStyle(result == "delivered" ? .green : .orange)
                            }
                        }
                        Spacer()
                        Button {
                            store.remove(task.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete task")
                    }
                    .padding(.vertical, 4)
                    SettingsRowDivider()
                }
            }
        }
    }
}
