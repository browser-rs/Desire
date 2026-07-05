import AppKit
import SwiftUI

struct AISettingsSection: View {
    @ObservedObject var store: AIPreferenceStore

    @State private var apiKey: String = ""
    @State private var showKey = false

    var body: some View {
        Form {
            HStack {
                if showKey {
                    TextField("API Key", text: $apiKey)
                } else {
                    SecureField("API Key", text: $apiKey)
                }
                Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            HStack {
                if store.hasAPIKey {
                    Button("Remove") { store.deleteAPIKey(); apiKey = "" }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("Save") { store.saveAPIKey(apiKey) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            TextField("Endpoint URL", text: $store.endpoint)
            TextField("Model", text: $store.model)

            HStack {
                Text("Max Tokens")
                Spacer()
                TextField("", value: $store.maxTokens, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Temperature")
                Spacer()
                Slider(value: $store.temperature, in: 0...2, step: 0.1)
                    .frame(width: 160)
                Text(String(format: "%.1f", store.temperature))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.subheadline)
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
