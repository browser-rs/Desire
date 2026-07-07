import AppKit
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
        Form {
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    if showKey {
                        TextField("", text: $apiKey)
                    } else {
                        SecureField("", text: $apiKey)
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 8) {
                if store.hasAPIKey {
                    Button("Remove", role: .destructive) { store.deleteAPIKey(); apiKey = "" }
                }
                Button("Save") { store.saveAPIKey(apiKey) }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .buttonStyle(.plain)

            Divider()

            TextField("Endpoint URL", text: $store.endpoint)

            Picker("Model", selection: Binding(
                get: { ModelPreset.matching(store.model) },
                set: { newPreset in
                    if newPreset == .custom {
                        // Clear the model so the user can type a fresh name.
                        // Without this, the text field below would show
                        // the previously selected preset value.
                        store.model = ""
                    } else {
                        store.model = newPreset.rawValue
                    }
                }
            )) {
                ForEach(ModelPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if ModelPreset.matching(store.model) == .custom {
                TextField("Custom Model Name", text: $store.model)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Max Tokens") {
                TextField("", value: $store.maxTokens, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Temperature") {
                HStack(spacing: 8) {
                    Slider(value: $store.temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", store.temperature))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }
            }

            Divider()

            Section("System Prompt") {
                TextEditor(text: $store.systemPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
                    .border(Color(nsColor: .separatorColor), width: 0.5)
            }

            Divider()

            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(isTesting || apiKey.isEmpty)
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.5)
                }
                if let status = testStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "Connected" ? .green : .red)
                }
                Spacer()
            }
        }
        .padding()
        .onAppear {
            apiKey = store.loadAPIKey() ?? ""
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
