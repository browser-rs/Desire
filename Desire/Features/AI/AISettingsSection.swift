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

struct AISettingsSection: View {
    @ObservedObject var store: AIPreferenceStore

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var testStatus: String?
    @State private var isTesting = false

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

                SettingsPickerRow(
                    "Model",
                    subtitle: "Pick a preset or choose Custom to type a name.",
                    systemImage: "cpu",
                    selection: Binding(
                        get: { ModelPreset.matching(store.model) },
                        set: { newPreset in
                            if newPreset == .custom {
                                store.model = ""
                            } else {
                                store.model = newPreset.rawValue
                            }
                        }
                    ),
                    options: ModelPreset.allCases,
                    label: { $0.displayName }
                )

                if ModelPreset.matching(store.model) == .custom {
                    SettingsRow("Custom Model Name", subtitle: nil, systemImage: "pencil") {
                        SettingsTextField(placeholder: "e.g. my-fine-tuned-model", text: $store.model, width: 220)
                    }
                    .padding(.top, 4)
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
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
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
            subtitle: "Extend the AI with external tools over MCP (HTTP transport). Experimental.",
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
