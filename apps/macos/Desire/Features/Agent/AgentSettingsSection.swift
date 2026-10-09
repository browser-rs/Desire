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
    /// 心跳巡检（模型自决的周期巡检，独立 store 持有自己的偏好）。
    @ObservedObject var heartbeat = HeartbeatStore.shared
    /// 生命周期钩子（beforeToolCall / turnFinish 用户脚本）。
    @ObservedObject var hooks = AgentHooksStore.shared

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
    @State private var draftFormat: AIProviderProfile.APIFormat = .openai
    @State private var newModelName = ""
    /// 成本段"添加模型"输入框的内容。
    @State private var newPriceModel = ""

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

    /// 钩子文件行（独立函数：行内三元 + Binding 内联会让类型检查器超时）。
    private func hookFileRow(_ file: AgentHooksStore.HookFile) -> some View {
        let subtitle: String
        if let error = file.hasError {
            subtitle = error
        } else {
            subtitle = String(localized: "beforeToolCall / turnFinish")
        }
        let icon = file.hasError == nil ? "doc.text" : "exclamationmark.triangle"
        let binding = Binding<Bool>(
            get: { file.isEnabled },
            set: { hooks.setEnabled($0, for: file.id) }
        )
        return SettingsRow(file.id, subtitle: subtitle, systemImage: icon) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(appAccent)
        }
    }

    /// 心跳"上次巡检"行的状态文案：相对时间 + 结论前缀。
    private func heartbeatBeatStatus() -> String {
        guard let last = heartbeat.lastBeatAt else {
            return String(localized: "Not run yet")
        }
        let relative = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        let result = heartbeat.lastResult ?? ""
        return result.isEmpty ? relative : "\(relative) · \(result)"
    }

    var body: some View {
        SettingsContainer {
            DoctorSection()
            ScheduledTasksSection()
            MCPServersSection()
            DPPSettingsSection()
            // 悬浮球已升级为独立设置子页（Settings → Floating Ball）。
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

            // MARK: - Cost

            costSection

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

            // MARK: - AI 自动广告清理

            SettingsSection(
                title: String(localized: "AI Auto Ad Clean"),
                subtitle: String(localized: "After every page load, high-confidence ad candidates are scanned and blocked automatically for that host. Unblocking a host exempts it."),
                icon: "shield.lefthalf.filled"
            ) {
                SettingsRow("Enable", subtitle: String(localized: "Off by default — the agent can also toggle this with toggleAutoAdClean."), systemImage: "sparkles.rectangle.stack") {
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "aiAutoAdClean") },
                        set: { AutoAdClean.shared.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .tint(appAccent)
                }
            }

            // MARK: - Persona（人设：名字 + 语气）

            SettingsSection(
                title: String(localized: "Agent Persona"),
                subtitle: String(localized: "Name and tone for the assistant. Leave empty for defaults."),
                icon: "person.crop.circle"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                        TextField(String(localized: "Name (e.g. Nova)"), text: $store.agentName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                        TextField(String(localized: "Tone (e.g. concise, friendly, no emoji)"), text: $store.agentPersona, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(2...4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            // MARK: - Agent Doctor（自诊断）

            DoctorSection()

            // MARK: - Agent Roster（多 Agent 人设名册）

            RosterSection()

            // MARK: - Output rules（个性化规则，逐条增删）

            SettingsSection(
                title: String(localized: "Output Rules"),
                subtitle: String(localized: "Standing personal preferences applied to every reply. Add or remove freely — no need to edit the whole system prompt."),
                icon: "person.badge.checkmark"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.outputRules.indices, id: \.self) { idx in
                        HStack(spacing: 8) {
                            Image(systemName: "text.line.first.and.arrow.point.forward")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField(
                                String(localized: "e.g. Always answer in Chinese"),
                                text: Binding(
                                    get: { store.outputRules[idx] },
                                    set: { store.outputRules[idx] = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            Button {
                                store.outputRules.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Remove rule"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                    }
                    Button {
                        store.outputRules.append("")
                    } label: {
                        Label(String(localized: "Add Rule"), systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    if store.outputRules.isEmpty {
                        Text(String(localized: "Rules apply to every conversation and take precedence over learned memory."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }

            // MARK: - Quick templates（自定义快捷模板）

            SettingsSection(
                title: String(localized: "Quick Templates"),
                subtitle: String(localized: "Custom buttons in the chat quick-action row. Tapping one sends the whole prompt."),
                icon: "bolt.badge.clock"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.customTemplates) { template in
                        let idx = store.customTemplates.firstIndex(where: { $0.id == template.id }) ?? 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                TextField(String(localized: "Button title"), text: Binding(
                                    get: { store.customTemplates[idx].title },
                                    set: { store.customTemplates[idx].title = $0 }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                Button {
                                    store.customTemplates.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "Remove template"))
                            }
                            TextField(String(localized: "Prompt sent when tapped"), text: Binding(
                                get: { store.customTemplates[idx].prompt },
                                set: { store.customTemplates[idx].prompt = $0 }
                            ), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .lineLimit(2...4)
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                    }
                    Button {
                        store.customTemplates.append(AgentQuickTemplate(title: "", prompt: ""))
                    } label: {
                        Label(String(localized: "Add Template"), systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
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
                SettingsPickerRow(
                    "Reviewer",
                    subtitle: String(localized: "Which service reviews the agent's work (reflect / self-review). A different model catches what the one being reviewed cannot — pick another service, or leave it on the chat's own."),
                    systemImage: "person.badge.shield.checkmark",
                    selection: $store.criticProfileID,
                    options: [nil] + store.profiles.map { Optional($0.id) },
                    label: { id in
                        guard let id, let profile = store.profiles.first(where: { $0.id == id }) else {
                            return String(localized: "Same as the chat")
                        }
                        return profile.name
                    }
                )
                SettingsRowDivider()
                SettingsPickerRow(
                    "Bypass Calls",
                    subtitle: String(localized: "Which service runs the quiet background calls (conversation title, memory extraction and summaries) after agent turns — pick a cheaper model, or leave it on the chat's own. Usage is still recorded per call and priced by the model that actually ran."),
                    systemImage: "arrow.uturn.backward",
                    selection: $store.bypassProfileID,
                    options: [nil] + store.profiles.map { Optional($0.id) },
                    label: { id in
                        guard let id, let profile = store.profiles.first(where: { $0.id == id }) else {
                            return String(localized: "Same as the chat")
                        }
                        return profile.name
                    }
                )
                SettingsRowDivider()
                SettingsPickerRow(
                    "Fallback Service",
                    subtitle: String(localized: "When the current service keeps failing on transient errors (rate limits, 5xx, dropped connections), the turn retries once on this service before giving up. Leave it off to fail as before."),
                    systemImage: "arrow.triangle.branch",
                    selection: $store.fallbackProfileID,
                    options: [nil] + store.profiles.map { Optional($0.id) },
                    label: { id in
                        guard let id, let profile = store.profiles.first(where: { $0.id == id }) else {
                            return String(localized: "Off")
                        }
                        return profile.name
                    }
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Self-review After Tool Runs",
                    subtitle: String(localized: "After a turn that ran three or more tools (or a high-risk one), ask the model to review its own work — did it verify what it claims, did anything fail silently. The critique appears collapsed under the reply."),
                    systemImage: "checkmark.seal",
                    isOn: $store.selfReviewEnabled
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Memory Learning",
                    subtitle: String(localized: "After agent turns, extract durable user preferences and conversation summaries into long-term memory. Inspect and delete anything in the panel's memory view."),
                    systemImage: "brain.head.profile",
                    isOn: $store.memoryLearning
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Cost-Aware Routing",
                    subtitle: String(localized: "When routing is on, simple short text-only turns run on the free on-device or Ollama model instead of the cloud — complex and tool-using turns still go to the cloud."),
                    systemImage: "scalemass",
                    isOn: $store.costAwareRouting
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "AI Action Review",
                    subtitle: String(localized: "At the Auto-edit access level, side-effect actions are first checked by a fast background model against your standing rules; flagged actions ask for confirmation with the reason. Timeouts never block the turn."),
                    systemImage: "shield.lefthalf.filled.badge.checkmark",
                    isOn: $store.guardReview
                )
            }

            // MARK: - Heartbeat（模型自决的周期巡检）

            SettingsSection(
                title: String(localized: "Heartbeat"),
                subtitle: String(localized: "A periodic check-in where the model itself decides whether anything needs your attention — it stays silent unless something is worth a ping. Skipped while a turn runs or during quiet hours."),
                icon: "heart.text.square"
            ) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        "Enable Heartbeat",
                        subtitle: String(localized: "Runs a lightweight background model call over the checklist below plus fresh machine signals (page-watch changes, failed scheduled tasks). A ping arrives as a routine notification; silence costs nothing but the call."),
                        systemImage: "waveform.path.ecg",
                        isOn: $heartbeat.isEnabled
                    )
                    if heartbeat.isEnabled {
                        SettingsRowDivider()
                        SettingsPickerRow(
                            "Interval",
                            systemImage: "clock",
                            selection: $heartbeat.intervalMinutes,
                            options: HeartbeatStore.intervalChoices,
                            label: { $0 >= 60 ? "\($0 / 60) h" : "\($0) min" }
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            "Act On Findings",
                            subtitle: String(localized: "When the heartbeat flags something, it also dispatches a real agent turn to verify and handle it (queued while busy). Off means it only tells you."),
                            systemImage: "arrow.triangle.commit",
                            isOn: $heartbeat.autoHandle
                        )
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        "Last Beat",
                        subtitle: heartbeatBeatStatus(),
                        systemImage: "clock.arrow.circlepath"
                    ) {
                        if heartbeat.isBeating {
                            StatusPill(text: "…", kind: .info)
                        }
                    }
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Checklist"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $heartbeat.checklist)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 88)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                            )
                        Text(String(localized: "One standing instruction per line — things worth checking periodically. Leave empty to rely on automatic signals only (page watches, failed tasks)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            // MARK: - Hooks（生命周期钩子）

            SettingsSection(
                title: String(localized: "Hooks"),
                subtitle: String(localized: "Small JavaScript files that run on agent events — a programmable layer on top of the access rules. Keep them short; they run synchronously on the agent loop."),
                icon: "curlybraces.square"
            ) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        "Enable Hooks",
                        subtitle: String(localized: "A hook file can define beforeToolCall(event) — return {decision:\"deny\", reason:\"…\"} to veto a tool at any access level — and turnFinish(event) for post-turn notifications."),
                        systemImage: "checkmark.seal.text.page",
                        isOn: $hooks.isEnabled
                    )
                    SettingsRowDivider()
                    SettingsActionRow(
                        "Hooks Folder",
                        subtitle: String(localized: "Drop .js files here, then reload. Each file runs in its own sandboxed JavaScriptCore context with no host access — only your event payload and console.log."),
                        systemImage: "folder",
                        buttonTitle: "Open Folder"
                    ) {
                        NSWorkspace.shared.open(AgentHooksStore.directory)
                    }
                    SettingsRowDivider()
                    SettingsActionRow(
                        "Reload Hooks",
                        subtitle: hooks.files.isEmpty
                            ? String(localized: "No hook files found.")
                            : (hooks.files.map { ($0.isEnabled ? "• " : "○ ") + $0.id }).joined(separator: "　"),
                        systemImage: "arrow.triangle.2.circlepath",
                        buttonTitle: "Reload",
                        isDisabled: false
                    ) {
                        hooks.load()
                    }
                    ForEach(hooks.files) { file in
                        SettingsRowDivider()
                        hookFileRow(file)
                    }
                }
            }
            .onAppear { hooks.load() }

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

    // MARK: - Cost section

    /// 模型单价表：把 token 用量折算成金额。**不内置价格表**（服务商改价是常事，
    /// 内置一份只会很快变成错的信息），**也不做前缀匹配**（`gpt-4o` 会顺手套到
    /// `gpt-4o-mini` 头上，差 10 倍）——填了才算，没填就只显示 token。
    private var costSection: some View {
        SettingsSection(
            title: String(localized: "Cost"),
            subtitle: String(localized: "Price per million tokens in USD, used to show what a conversation costs. Left blank = unknown: that model shows tokens only, never \"$0\"."),
            icon: "dollarsign.circle"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(store.priceableModels.enumerated()), id: \.element) { index, model in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(model, systemImage: nil) {
                        HStack(spacing: 6) {
                            priceField(model: model, keyPath: \.inputPerMTok, placeholder: "in")
                            Text(verbatim: "$/M")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            priceField(model: model, keyPath: \.outputPerMTok, placeholder: "out")
                            Text(verbatim: "$/M")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow(String(localized: "Add a model"), subtitle: String(localized: "For models that are not in the current service's list."), systemImage: "plus") {
                    HStack(spacing: 6) {
                        SettingsTextField(placeholder: "model id", text: $newPriceModel, width: 150)
                        SettingsCapsuleButton(String(localized: "Add"), style: .secondary) {
                            let model = newPriceModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !model.isEmpty else { return }
                            if store.modelPrices[model] == nil { store.modelPrices[model] = ModelPrice() }
                            newPriceModel = ""
                        }
                    }
                }
            }
        }
    }

    /// 单价输入框：空 = 0（未知）。用 `%g` 回显，免得 `2.5000000001` 这种浮点尾巴。
    private func priceField(model: String, keyPath: WritableKeyPath<ModelPrice, Double>, placeholder: String) -> some View {
        SettingsTextField(
            placeholder: placeholder,
            text: Binding(
                get: {
                    let value = (store.modelPrices[model] ?? ModelPrice())[keyPath: keyPath]
                    return value > 0 ? String(format: "%g", value) : ""
                },
                set: { text in
                    var price = store.modelPrices[model] ?? ModelPrice()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    price[keyPath: keyPath] = max(0, Double(trimmed) ?? 0)
                    store.modelPrices[model] = price
                }
            ),
            width: 64
        )
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
        // Keychain 读是**阻塞的系统调用**（走 securityd IPC），而这一行每次重绘都会
        // 求值：只读一次给状态徽章用。此前这里写了两遍
        // `store.loadAPIKey(profileID:)`，等于每行每帧两次主线程 Keychain 调用
        // （Xcode 的 Performance Diagnostics 会报 "This method should not be called
        // on the main thread as it may lead to UI unresponsiveness"）。
        // PERF-4：读 store 预读发布的字典，不在 body 里现读 Keychain（阻塞
        // 系统调用，Xcode Performance Diagnostics 点名过）。
        let hasKey = store.hasKeyByProfile[profile.id] ?? false
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
                text: hasKey
                    ? String(localized: "Key saved")
                    : String(localized: "No key"),
                kind: hasKey ? .success : .warning
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
            draftModelPicker

            // 线协议：OpenAI 兼容（chat/completions）或 Anthropic（Messages）。
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "API Format"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $draftFormat) {
                    Text("OpenAI").tag(AIProviderProfile.APIFormat.openai)
                    Text("Anthropic").tag(AIProviderProfile.APIFormat.anthropic)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .labelsHidden()
            }

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

    /// 模型**下拉选择**（服务自己的模型清单 + 从 /models 拉到的），下面留一行
    /// 手动输入兜底（随手敲的名字回车即记进清单，下次就能在下拉里选）。
    @ViewBuilder
    private var draftModelPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "Model"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Menu {
                let options = draftModelOptions
                if options.isEmpty {
                    Text("No models yet — fetch them or add names below")
                } else {
                    ForEach(options, id: \.self) { model in
                        Button { draftModel = model } label: {
                            Label(model, systemImage: draftModel == model ? "checkmark" : "cpu")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(draftModel.isEmpty ? String(localized: "Select a model…") : draftModel)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 280, alignment: .leading)

            HStack(spacing: 6) {
                SettingsTextField(placeholder: "or type a model name…", text: $draftModel, width: 200)
                    .onSubmit {
                        let name = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !draftModels.contains(name) else { return }
                        draftModels.append(name)
                    }
                if !draftModel.trimmingCharacters(in: .whitespaces).isEmpty,
                   !draftModels.contains(draftModel) {
                    Button {
                        draftModels.append(draftModel)
                    } label: {
                        Text(String(localized: "Add to list"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 下拉里的候选：清单里的 + 拉取到的 + 当前值（三者去重）。
    private var draftModelOptions: [String] {
        var seen = Set<String>()
        var models: [String] = []
        for model in [draftModel] + draftModels + (fetchedModels ?? []) {
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            models.append(name)
        }
        return models
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
        draftFormat = profile?.format ?? .openai
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
            store.profiles[index].apiFormat = draftFormat
            store.activeProfileID = id
        } else {
            let profile = store.addProfile(name: draftName, endpoint: endpoint, model: draftModel)
            if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
                store.profiles[index].modelList = draftModels
                store.profiles[index].headers = headers
                store.profiles[index].apiFormat = draftFormat
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
        let format = draftFormat
        Task {
            let models = (try? await ModelListFetcher.fetch(endpoint: endpoint, apiKey: key, format: format)) ?? []
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

    /// 探针统一在 AIConnectivity（服务层）——这两份手写 URLRequest 曾各自
    /// 漂移（ARCH-3）。ollama 的成功文案保留 "Connected"（StatusPill 判据）。
    private func testOllama() {
        isTestingOllama = true
        ollamaTestStatus = nil
        Task {
            defer { isTestingOllama = false }
            let result = await AIConnectivity.probe(
                endpoint: store.ollamaHost, model: store.ollamaModel,
                apiKey: nil, timeout: 10)
            ollamaTestStatus = result == "Connected ✓" ? "Connected" : result
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
            let format = editing ? draftFormat : (store.activeProfile?.apiFormat ?? .openai)
            let headers: [String: String]
            if editing {
                var collected: [String: String] = [:]
                for draft in draftHeaders {
                    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    collected[name] = draft.value
                }
                headers = collected
            } else {
                headers = store.activeHeaders
            }
            cloudTestStatus = await AIConnectivity.probeChat(
                endpoint: endpoint, model: model, apiKey: key,
                timeout: 15,
                opencodeSessionHeader: endpoint.contains("opencode"),
                extraHeaders: headers,
                anthropic: format == .anthropic)
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
    /// 新增表单的传输分段（http / stdio）与 stdio 命令草稿。
    @State private var newTransport = "http"
    @State private var newCommand = ""
    /// Per-server auth-token editing state (server id → draft token).
    @State private var tokenDrafts: [UUID: String] = [:]
    /// Per-server expanded tool list disclosure.
    @State private var expandedTools: Set<UUID> = []

    var body: some View {
        SettingsSection(
            title: String(localized: "MCP Servers"),
            subtitle: String(localized: "Extend the Agent with external tools over MCP. HTTP (Streamable) or stdio (local command) transport."),
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                if store.servers.isEmpty {
                    Text(String(localized: "No MCP servers configured. Add an HTTP endpoint or a local stdio command."))
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
                            HStack(spacing: 4) {
                                Text(server.name)
                                    .font(.system(size: 12, weight: .medium))
                                if server.isStdio {
                                    Text(String(localized: "stdio"))
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(appAccent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(appAccent.opacity(0.12)))
                                }
                            }
                            Text(server.isStdio
                                 ? (server.command?.joined(separator: " ") ?? "")
                                 : server.url)
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

                // 传输分段：HTTP 端点 / stdio 本地命令（完整 MCP）。
                Picker("", selection: $newTransport) {
                    Text(String(localized: "HTTP")).tag("http")
                    Text(String(localized: "Stdio (local command)")).tag("stdio")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                if newTransport == "http" {
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
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $newName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            TextField(String(localized: "Command + args (e.g. python3 /path/server.py)"), text: $newCommand)
                                .textFieldStyle(.roundedBorder)
                            Button(String(localized: "Add")) {
                                store.addStdioServer(name: newName, command: newCommand)
                                newName = ""
                                newCommand = ""
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text(String(localized: "The command runs as a local subprocess (argv; quote paths with spaces). Tools it exposes join the Agent automatically."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

/// Scheduled agent prompts (定时任务) — created by the agent itself via the
/// scheduleTask tools; managed (enable/disable/delete) here.
// MARK: - Agent Roster（多 Agent 人设名册）

/// 命名人设列表：每个窗口的 Agent 面板可从标题菜单绑定其一（只覆盖
/// <persona> 层的名字与语气；系统提示词身份层保持全局）。
// MARK: - Agent Doctor（自诊断）

/// 一键自检：模型端点可达/Key、旁路与备用档案、MCP、ffmpeg、钩子语法、
/// 技能风险、通知授权、心跳。逻辑在 AgentDoctor（桥 GET /agent/doctor 同源）。
private struct DoctorSection: View {
    @State private var running = false
    @State private var report: AgentDoctor.Report?

    var body: some View {
        SettingsSection(
            title: String(localized: "Agent Doctor"),
            subtitle: String(localized: "One-click self-check: model endpoint reachability, keys, MCP connections, ffmpeg, hook syntax, skill risks, notification authorization and heartbeat."),
            icon: "stethoscope"
        ) {
            SettingsActionRow(
                "Run Check",
                subtitle: summary,
                systemImage: "waveform.path.ecg.rectangle",
                buttonTitle: String(localized: "Run"),
                isDisabled: running
            ) {
                Task { await run() }
            }
            if let report {
                ForEach(report.checks) { check in
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(check.ok ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var summary: String {
        if running { return String(localized: "Running…") }
        guard let report else { return String(localized: "Not run yet") }
        return report.ok
            ? String(localized: "All \(report.checks.count) checks passed")
            : String(localized: "\(report.passed) of \(report.checks.count) checks passed")
    }

    private func run() async {
        running = true
        report = await AgentDoctor.run()
        running = false
    }
}

private struct RosterSection: View {
    @ObservedObject private var roster = AgentRosterStore.shared
    @State private var newName = ""
    @State private var newTone = ""

    var body: some View {
        SettingsSection(
            title: String(localized: "Agent Personas"),
            subtitle: String(localized: "Named personas the window agents can take — pick one from the panel's title menu. It only changes how that window's agent introduces itself; the system prompt stays global."),
            icon: "person.2.fill"
        ) {
            VStack(spacing: 0) {
                if roster.personas.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "No personas yet. Add one below, then bind it from the agent panel's title menu."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                ForEach(roster.personas) { persona in
                    personaRow(persona)
                    SettingsRowDivider()
                }
                HStack(spacing: 8) {
                    TextField(String(localized: "Persona name"), text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    TextField(String(localized: "Tone (optional)"), text: $newTone, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(1...2)
                    Button {
                        if roster.add(name: newName, tone: newTone) != nil {
                            newName = ""
                            newTone = ""
                        }
                    } label: {
                        Text(String(localized: "Add"))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.tint.opacity(0.18)))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func personaRow(_ persona: AgentRosterStore.AgentPersona) -> some View {
        let nameBinding = Binding(
            get: { persona.name },
            set: { roster.update(id: persona.id, name: $0, tone: persona.tone) }
        )
        let toneBinding = Binding(
            get: { persona.tone },
            set: { roster.update(id: persona.id, name: persona.name, tone: $0) }
        )
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(String(localized: "Persona name"), text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                TextField(String(localized: "Tone (optional)"), text: toneBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .lineLimit(1...3)
            }
            Button {
                roster.remove(id: persona.id)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
        .padding(.vertical, 6)
    }
}

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
                    ScheduledTaskRow(task: task)
                    SettingsRowDivider()
                }
            }
        }
    }
}

/// 单条定时任务行：开关 + 名称/周期/目标 + 目标窗口选择器 + 删除。
/// 目标选择器是多窗口联动 v1 的设置页入口（桥 tasks/create 的 window 参数
/// 与它写同一个字段）。
private struct ScheduledTaskRow: View {
    @ObservedObject private var store = AgentScheduler.shared
    let task: AgentScheduler.ScheduledTask

    var body: some View {
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
                targetLine
                if let result = task.lastResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(result == "delivered" ? .green : .orange)
                }
            }
            Spacer()
            targetMenu
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
    }

    /// 目标选择器：胶囊 chip 显示当前目标（无目标 = "最新窗口"），点开列
    /// 全部活会话 + "跟随最新窗口"。
    private var targetMenu: some View {
        Menu {
            Button(String(localized: "Newest Window")) {
                store.setTarget(nil, for: task.id)
            }
            .disabled(task.targetSessionID == nil)
            Divider()
            ForEach(AgentScheduler.shared.liveSessions()) { entry in
                Button(entry.displayLabel) {
                    store.setTarget(entry.id, for: task.id)
                }
                .disabled(task.targetSessionID == entry.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.landscape.rotate")
                    .font(.system(size: 9, weight: .medium))
                Text(targetChipLabel)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .foregroundStyle(.primary)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(String(localized: "Which window's agent receives this task"))
    }

    private var targetChipLabel: String {
        if task.targetSessionID != nil {
            return store.targetLabel(for: task.id) ?? String(localized: "Closed Window")
        }
        return String(localized: "Newest Window")
    }

    @ViewBuilder
    private var targetLine: some View {
        if task.targetSessionID != nil {
            let label = store.targetLabel(for: task.id) ?? String(localized: "Window closed (falls back to the newest session)")
            Text(String(localized: "Target: \(label)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
