import AppKit
import SwiftUI

struct AISettingsSection: View {
    @ObservedObject var store: AIPreferenceStore

    @State private var apiKey: String = ""
    @State private var showKey = false

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
            TextField("Model", text: $store.model)

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
        }
        .padding()
        .onAppear {
            apiKey = store.loadAPIKey() ?? ""
        }
    }
}
