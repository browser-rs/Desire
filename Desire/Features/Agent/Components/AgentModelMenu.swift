import SwiftUI

/// The model/provider switcher, rendered as a small capsule in the input
/// bar's right group, next to the send button (the familiar chat-input
/// pattern: model dropdown beside send). Lists provider kinds and saved
/// endpoints only — capability toggles are their own inline controls.
struct AgentModelMenu: View {
    @ObservedObject var store: AgentSessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
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
            Section("Saved Endpoints") {
                ForEach(store.preference.savedEndpoints) { ep in
                    Button {
                        store.preference.activeEndpointID = ep.id
                        store.preference.providerKind = .cloud
                        store.preference.cloudProviderID = Self.providerID(for: ep.url)
                        store.preference.endpoint = ep.url
                        store.preference.model = ep.model
                    } label: {
                        Label("\(ep.name) — \(ep.model)",
                              systemImage: store.preference.activeEndpointID == ep.id && store.preference.providerKind == .cloud ? "checkmark" : "globe")
                    }
                }
                if store.preference.savedEndpoints.isEmpty {
                    Text("Add endpoints in Settings → Agent")
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

    /// Tilde-abbreviated working directory for the menu info row.
    /// Rough share of the agent context budget the stored conversation
    /// occupies (same 160k-char estimate as AgentSessionStore.compactForContext).
    /// Maps an endpoint URL to the per-provider Keychain account suffix
    /// ("ai-key-<providerID>") so a switch loads the right key.
    private static func providerID(for url: String) -> String {
        let known: [(String, String)] = [
            ("openrouter", "openrouter"), ("deepseek", "deepseek"),
            ("bigmodel", "zhipu"), ("zhipu", "zhipu"),
            ("opencode", "opencode-go"), ("openai", "openai"),
        ]
        let lower = url.lowercased()
        for (fragment, id) in known where lower.contains(fragment) {
            return id
        }
        return "openai"
    }
}
