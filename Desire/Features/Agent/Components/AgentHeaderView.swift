import AppKit
import SwiftUI

/// Header strip for the AI panel. Shows a brand mark, an animated status
/// dot when streaming, and trailing
/// actions (history / clear).
struct AgentHeaderView: View {
    @ObservedObject var store: AgentSessionStore
    let hasHistory: Bool
    var onShowHistory: () -> Void
    var onShowCapabilities: (() -> Void)?
    var onShowMemory: (() -> Void)?
    var onNewChat: (() -> Void)?

    @State private var isDotPulsing = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            brandMark

            VStack(alignment: .leading, spacing: 0) {
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                statusLine
            }

            Spacer(minLength: 4)

            if store.fullAccess {
                fullAccessBadge
            }

            if store.isProcessing {
                if store.isPaused {
                    Button {
                        store.resume()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Resume (paused between steps)")
                } else {
                    Button {
                        store.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Pause (stops before the next step)")
                }
                stopButton
            }

            if let onShowCapabilities {
                HoverIcon(
                    systemName: "sparkles.rectangle.stack",
                    action: onShowCapabilities,
                    help: "Agent capabilities & tools"
                )
            }

            if let onShowMemory {
                HoverIcon(
                    systemName: "brain.head.profile",
                    action: onShowMemory,
                    help: "Memory"
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
            if store.usagePromptTokens > 0 || store.usageCompletionTokens > 0 {
                Text(tokenUsageText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Token usage for this conversation (provider-reported)")
            }
        }
    }

    /// Compact cumulative usage, e.g. "↑3.2k ↓8.9k".
    private var tokenUsageText: String {
        String(format: "↑%.1fk ↓%.1fk",
               Double(store.usagePromptTokens) / 1000,
               Double(store.usageCompletionTokens) / 1000)
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
}
