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
    @ObservedObject var store: AgentPreferenceStore

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var testStatus: String?
    @State private var isTesting = false
    /// Models fetched from the API's `/models` endpoint (nil = not fetched).
    @State private var fetchedModels: [String]? = nil
    @State private var isFetchingModels = false
    @State private var newBinary = ""
    private func addBinary() {
        SystemCommandStore.shared.allow(newBinary)
        newBinary = ""
    }

    var body: some View {
        SettingsContainer {
            MCPServersSection()
            SettingsSection(
                title: "Provider",
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
                title: "Generation",
                subtitle: "Applies to all providers.",
                icon: "slider.horizontal.3"
            ) {
                VStack(spacing: 0) {
                    SettingsRow("Max Tokens", subtitle: "Upper bound on completion length.", systemImage: "text.alignleft") {
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
                    SettingsRow("Temperature", subtitle: "Higher values produce more varied responses.", systemImage: "thermometer.medium") {
                        HStack(spacing: 8) {
                            Slider(value: $store.temperature, in: 0...2, step: 0.1)
                                .frame(width: 140)
                            Text(String(format: "%.1f", store.temperature))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                }
            }

            // MARK: - System Prompt

            SettingsSection(
                title: "System Prompt",
                subtitle: "Sent to the model on every request. Leave empty to use the default.",
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
                title: "System Access (CLI)",
                subtitle: "Binaries the agent may run via runCommand. Argv-only, no shell; every call prompts unless FULL ACCESS is on.",
                icon: "terminal"
            ) {
                VStack(spacing: 0) {
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
                                .foregroundStyle(Color.accentColor)
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
                }
            }

            // MARK: - Agent context

            SettingsSection(
                title: "Agent Context",
                subtitle: "What the agent knows about the page you're on.",
                icon: "scope"
            ) {
                SettingsToggleRow(
                    "Auto Page Context",
                    subtitle: "Attach a compact summary of the current page (title, URL, text excerpt) to every request. Off means the agent must call getPageSnapshot itself.",
                    systemImage: "doc.text.magnifyingglass",
                    isOn: $store.autoPageContext
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Memory Learning",
                    subtitle: "After agent turns, extract durable user preferences and conversation summaries into long-term memory. Inspect and delete anything in the panel's memory view.",
                    systemImage: "brain.head.profile",
                    isOn: $store.memoryLearning
                )
            }

            // MARK: - Allowed Tools

            if !store.allowedTools.isEmpty {
                SettingsSection(
                    title: "Always-Allowed Tools",
                    subtitle: "These tools will run without asking for approval each time.",
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
                            subtitle: "Clear the always-allowed list and prompt again next time.",
                            systemImage: "arrow.counterclockwise",
                            buttonTitle: "Reset"
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
        .onChange(of: store.cloudProviderID) { _, _ in
            // Switching providers reloads the API key (per-provider keychain).
            apiKey = store.loadAPIKey() ?? ""
        }
    }

    // MARK: - Saved endpoints

    private func saveCurrentEndpoint() {
        let name = store.cloudProviderID
        let endpoint = store.endpoint
        let model = store.model
        guard !endpoint.isEmpty else { return }
        store.savedEndpoints.append(SavedAIEndpoint(name: name, url: endpoint, model: model))
        store.activeEndpointID = store.savedEndpoints.last?.id
    }

    // MARK: - Saved endpoints

    @ViewBuilder
    private func savedEndpointRow(_ ep: SavedAIEndpoint) -> some View {
        let isActive = store.activeEndpointID == ep.id
        HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.system(size: 11))
            Text(ep.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            Button {
                store.savedEndpoints.removeAll { $0.id == ep.id }
                if store.activeEndpointID == ep.id { store.activeEndpointID = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { switchToEndpoint(ep) }
    }

    private func switchToEndpoint(_ ep: SavedAIEndpoint) {
        store.activeEndpointID = ep.id
        store.endpoint = ep.url
        store.model = ep.model
        apiKey = store.loadAPIKey() ?? ""
    }

    // MARK: - Model picker + fetch

    private var fetchModelsSubtitle: String {
        if let models = fetchedModels, !models.isEmpty {
            return "\(models.count) models available"
        }
        return "Query the provider's /models endpoint for available models."
    }

    private func fetchModels() {
        isFetchingModels = true
        let ep = store.endpoint
        let key = apiKey
        Task {
            do {
                let models = try await ModelListFetcher.fetch(endpoint: ep, apiKey: key)
                fetchedModels = models
            } catch {
                fetchedModels = nil
            }
            isFetchingModels = false
        }
    }

    /// Returns the preset model list for the ACTIVE cloud provider.
    /// Each provider has its own model lineup (Zhipu → GLM series, OpenAI
    /// → GPT series, etc.) so the picker reflects what's actually available.
    private var providerModelPresets: [String] {
        switch store.cloudProviderID {
        case "openai":
            return ["gpt-4o", "gpt-4o-mini", "o3-mini", "gpt-4-turbo", "o1-preview"]
        case "deepseek":
            return ["deepseek-chat", "deepseek-coder", "deepseek-reasoner"]
        case "zhipu":
            return ["glm-4-plus", "glm-4-flash", "glm-4-long", "glm-4v-plus", "glm-4-air"]
        case "opencode-go":
            return ["glm-4-plus", "deepseek-chat", "claude-3-5-sonnet"]
        default:
            return []
        }
    }

    @ViewBuilder
    private var modelPickerRow: some View {
        SettingsRow("Model", subtitle: modelPickerSubtitle, systemImage: "cpu") {
            Menu {
                // Presets for the active provider
                Section("Models") {
                    ForEach(providerModelPresets, id: \.self) { model in
                        Button(model) { store.model = model }
                    }
                }
                // Fetched models from the API
                if let models = fetchedModels, !models.isEmpty {
                    Section("Fetched from API") {
                        ForEach(models, id: \.self) { model in
                            Button(model) { store.model = model }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(store.model.isEmpty ? "Select a model…" : store.model)
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
            .frame(maxWidth: 260, alignment: .leading)
        }

        SettingsRow("Or Type Model Name", subtitle: nil, systemImage: "pencil") {
            SettingsTextField(placeholder: "e.g. my-fine-tuned-model", text: $store.model, width: 220)
        }
    }

    private var modelPickerSubtitle: String {
        if let models = fetchedModels, !models.isEmpty {
            return "\(models.count) models from the API"
        }
        return "Pick a preset, fetch from the API, or type a custom name."
    }

    private func presetChip(_ name: String, providerID: String, endpoint: String, model: String) -> some View {
        Button(name) {
            store.cloudProviderID = providerID
            store.endpoint = endpoint
            if !model.isEmpty { store.model = model }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    // MARK: - Foundation Models section

    @ViewBuilder
    private var foundationModelsSection: some View {
        SettingsSection(
            title: "Apple Intelligence",
            subtitle: "On-device model. No credentials required.",
            icon: "apple.logo"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Status", subtitle: "Whether the system model is available right now.", systemImage: "dot.radiowaves.left.and.right") {
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

    @ViewBuilder
    private var cloudSection: some View {
        SettingsSection(
            title: "Cloud API",
            subtitle: "OpenAI / Anthropic / DeepSeek compatible endpoints.",
            icon: "cloud"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    "API Key",
                    subtitle: "Stored in the macOS Keychain.",
                    systemImage: "key"
                ) {
                    HStack(spacing: 6) {
                        SettingsTextField(placeholder: "sk-…", text: $apiKey, isSecure: !showKey, width: 200)
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.08))
                                )
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showKey ? "Hide" : "Show")
                    }
                }
                SettingsRowDivider()

                SettingsRow(
                    "Endpoint URL",
                    subtitle: "Full chat-completions URL.",
                    systemImage: "link"
                ) {
                    SettingsTextField(placeholder: "https://api.openai.com/v1/chat/completions", text: $store.endpoint, width: 260)
                }
                SettingsRowDivider()

                // Provider quick presets — switching sets cloudProviderID,
                // endpoint, model, AND loads the per-provider API key.
                SettingsRow("Provider Presets", subtitle: "Quick setup — click to fill endpoint + model.", systemImage: "bolt") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            presetChip("OpenAI", providerID: "openai", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o")
                            presetChip("DeepSeek", providerID: "deepseek", endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-chat")
                            presetChip("Zhipu GLM", providerID: "zhipu", endpoint: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions", model: "glm-4-plus")
                            presetChip("OpenCode Go", providerID: "opencode-go", endpoint: "https://opencode.ai/zen/go/v1/chat/completions", model: "claude-sonnet-4-20250514")
                        }
                    }
                }
                SettingsRowDivider()

                // Saved endpoint profiles — switch between configurations.
                if !store.savedEndpoints.isEmpty {
                    SettingsRow("Saved Configurations", subtitle: "Click to switch.", systemImage: "square.stack") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.savedEndpoints) { ep in
                                savedEndpointRow(ep)
                            }
                        }
                    }
                    SettingsRowDivider()
                }

                // Model picker: dynamic (presets + fetched + custom text).
                modelPickerRow
                SettingsRowDivider()

                // Fetch models from the API
                SettingsRow("Fetch Models", subtitle: fetchModelsSubtitle, systemImage: "arrow.down.circle") {
                    Button {
                        fetchModels()
                    } label: {
                        HStack(spacing: 4) {
                            if isFetchingModels { ProgressView().scaleEffect(0.5) }
                            Text(isFetchingModels ? "Fetching…" : "Fetch")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isFetchingModels || apiKey.isEmpty)
                }

                SettingsRowDivider()

                HStack(spacing: 12) {
                    Button {
                        store.saveAPIKey(apiKey)
                    } label: {
                        Text("Save Key")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.18))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if store.hasAPIKey {
                        Button {
                            store.deleteAPIKey()
                            apiKey = ""
                        } label: {
                            Text("Remove Key")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(Color.red.opacity(0.12))
                                )
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        saveCurrentEndpoint()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Save this endpoint + model configuration")

                    Spacer()

                    Button {
                        testConnection()
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting { ProgressView().scaleEffect(0.5) }
                            Text(isTesting ? "Testing…" : "Test Connection")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.1))
                        )
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting || apiKey.isEmpty)

                    if let status = testStatus {
                        StatusPill(
                            text: status,
                            kind: status == "Connected" ? .success : .error
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Ollama section

    @ViewBuilder
    private var ollamaSection: some View {
        SettingsSection(
            title: "Ollama",
            subtitle: "Local model server. Run ollama serve and pull a model first.",
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Ollama Host", subtitle: "Base URL of the running ollama daemon.", systemImage: "network") {
                    SettingsTextField(placeholder: "http://127.0.0.1:11434", text: $store.ollamaHost, width: 220)
                }
                SettingsRowDivider()
                SettingsRow("Model", subtitle: "A model pulled on the server (llama3.2, qwen2.5, …).", systemImage: "cpu") {
                    SettingsTextField(placeholder: "llama3.2", text: $store.ollamaModel, width: 200)
                }
                SettingsRowDivider()
                HStack(spacing: 12) {
                    Button {
                        testOllama()
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting { ProgressView().scaleEffect(0.5) }
                            Text(isTesting ? "Testing…" : "Test")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)

                    if let status = testStatus {
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
        isTesting = true
        testStatus = nil
        Task {
            defer { isTesting = false }
            let base = store.ollamaHost
            let urlStr = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
            guard let url = URL(string: urlStr) else {
                testStatus = "Invalid host"
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
                    testStatus = "Connected"
                } else if let http = response as? HTTPURLResponse {
                    testStatus = "HTTP \(http.statusCode)"
                }
            } catch {
                testStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testStatus = nil
        Task {
            defer { isTesting = false }
            let key = apiKey
            let endpoint = store.endpoint
            let model = store.model

            let urlStr = endpoint.hasSuffix("/chat/completions") ? endpoint : endpoint + "/chat/completions"
            guard let url = URL(string: urlStr) else {
                testStatus = "Invalid endpoint"
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
                    testStatus = "Connected ✓"
                } else if let http = response as? HTTPURLResponse {
                    // Show the server's error message so the user knows WHY.
                    let serverMsg = body.prefix(200)
                    testStatus = "HTTP \(http.statusCode): \(serverMsg)"
                }
            } catch {
                testStatus = "Failed: \(error.localizedDescription)"
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
    @ObservedObject var store = MCPStore.shared
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        SettingsSection(
            title: "MCP Servers",
            subtitle: "Extend the Agent with external tools over MCP (HTTP transport). Experimental.",
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                if store.servers.isEmpty {
                    Text("No MCP servers configured. Add a Streamable HTTP endpoint (e.g. a local mcp-proxy).")
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
                    SettingsRowDivider()
                }

                HStack {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("http://127.0.0.1:3000/mcp", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        store.addServer(name: newName, url: newURL)
                        newName = ""
                        newURL = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
        }
    }
}
