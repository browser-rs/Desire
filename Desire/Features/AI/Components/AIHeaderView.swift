import SwiftUI

/// Header strip for the AI panel. Shows a brand mark, the active model as
/// a small pill, an animated status dot when streaming, and trailing
/// actions (history / clear).
struct AIHeaderView: View {
    @ObservedObject var store: AISessionStore
    let hasHistory: Bool
    var onShowHistory: () -> Void
    var onShowCapabilities: (() -> Void)?
    var onNewChat: (() -> Void)?

    @State private var isDotPulsing = false

    var body: some View {
        HStack(spacing: 8) {
            brandMark

            VStack(alignment: .leading, spacing: 0) {
                Text("AI Assistant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                statusLine
            }

            Spacer(minLength: 4)

            modelMenu

            if store.fullAccess {
                fullAccessBadge
            }

            if store.isProcessing {
                stopButton
            }

            if let onShowCapabilities {
                HoverIcon(
                    systemName: "sparkles.rectangle.stack",
                    action: onShowCapabilities,
                    help: "AI capabilities & tools"
                )
            }

            HoverIcon(
                systemName: "clock.arrow.circlepath",
                action: onShowHistory,
                help: "Conversation history"
            )
            .opacity(hasHistory ? 1 : 0.35)
            .disabled(!hasHistory)

            if let onNewChat {
                HoverIcon(
                    systemName: "plus.bubble",
                    action: onNewChat,
                    help: "New chat"
                )
            }

            HoverIcon(
                systemName: "trash",
                action: { store.clear() },
                help: "Clear conversation"
            )
            .opacity(canClear ? 1 : 0.35)
            .disabled(!canClear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(headerBackground)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.6)
        }
        .onAppear { isDotPulsing = true }
        .onChange(of: store.isProcessing) { _, newValue in
            isDotPulsing = newValue
        }
    }

    // MARK: - Sub-views

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor,
                            Color.accentColor.opacity(0.7),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.accentColor.opacity(0.25), radius: 3, y: 1)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .scaleEffect(isDotPulsing ? 1.0 : 0.6)
                .animation(
                    isDotPulsing
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isDotPulsing
                )
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The model pill doubles as the switcher menu: provider kinds, saved
    /// endpoints, full-access toggle, and a context-usage readout.
    private var modelMenu: some View {
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
                    Text("Add endpoints in Settings → AI")
                }
            }
            Section {
                Toggle("Full Access (auto-approve all tools)", isOn: $store.fullAccess)
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

    private var fullAccessBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 8, weight: .bold))
            Text("FULL ACCESS")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 0.8))
        .help("All tools run without approval — including code execution. Toggle in the model menu.")
    }

    private var stopButton: some View {
        Button {
            store.cancel()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                Text("Stop")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help("Stop generation")
        .transition(.scale.combined(with: .opacity))
    }

    private var headerBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Computed

    private var canClear: Bool {
        !store.messages.isEmpty
    }

    private var statusColor: Color {
        if store.isProcessing { return Color.orange }
        if !store.messages.isEmpty { return Color.green }
        return Color.secondary.opacity(0.5)
    }

    private var statusText: String {
        if store.isProcessing {
            if let action = store.currentAction {
                return "Running \(action)…"
            }
            return "Thinking…"
        }
        if !store.messages.isEmpty { return "Ready" }
        return "Idle"
    }

    private var displayModel: String {
        let model = store.preference.model
        return model.isEmpty ? "No model" : model
    }

    /// Rough share of the agent context budget the stored conversation
    /// occupies (same 160k-char estimate as AISessionStore.compactForContext).
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
