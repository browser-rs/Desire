import AppKit
import SwiftUI

/// The model/provider switcher, rendered as a small capsule inside the
/// input bar (next to attach/voice/send). Covers provider kinds, saved
/// endpoints, the FULL ACCESS toggle, the working directory, and a
/// context-usage readout — the agent's capability controls, one click from
/// where the user types.
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
            Section {
                Toggle("Full Access (auto-approve all tools)", isOn: $store.fullAccess)
                Divider()
                Text(workingDirectoryInfo)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    panel.message = String(localized: "Choose the agent's working directory for file tools and system commands")
                    panel.directoryURL = SystemCommandStore.shared.workingDirectory
                    if panel.runModal() == .OK, let url = panel.url {
                        SystemCommandStore.shared.setWorkingDirectory(url)
                    }
                } label: {
                    Label("Change Working Directory…", systemImage: "folder.badge.gearshape")
                }
                Button {
                    openWindow(id: "settings")
                } label: {
                    Label("Agent Settings…", systemImage: "gearshape")
                }
                Text(contextUsageText)
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
    private var workingDirectoryInfo: String {
        let raw = SystemCommandStore.shared.workingDirectory.path
        return raw.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Rough share of the agent context budget the stored conversation
    /// occupies (same 160k-char estimate as AgentSessionStore.compactForContext).
    private var contextUsageText: String {
        let chars = store.messages.reduce(0) {
            ($0 + ($1.content?.count ?? 0)
                + ($1.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0))
        }
        return "Context used ~\(min(100, chars * 100 / 160_000))%"
    }

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
