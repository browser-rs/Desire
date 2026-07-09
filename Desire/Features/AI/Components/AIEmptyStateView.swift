import SwiftUI

/// Welcome / empty state shown when there is no active conversation.
/// Renders a hero card and a 2x2 grid of quick-action cards.
struct AIEmptyStateView: View {
    let onAction: (AIQuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            heroCard
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 18)

            quickActionGrid
                .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.18),
                                Color.accentColor.opacity(0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("How can I help?")
                .font(.system(size: 15, weight: .semibold))

            Text("Ask questions, summarize pages,\ntranslate content, and more.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: .radiusCard, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusCard, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Quick actions grid

    private var quickActionGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick actions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(AIQuickAction.allCases, id: \.title) { action in
                    QuickActionCard(action: action) {
                        onAction(action)
                    }
                }
            }
        }
    }
}

private struct QuickActionCard: View {
    let action: AIQuickAction
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackground)
                    Image(systemName: action.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconForeground)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(action.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: .radiusButton, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusButton, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }

    private var cardFill: Color {
        isHovering
            ? Color.accentColor.opacity(0.08)
            : Color(nsColor: .controlBackgroundColor).opacity(0.45)
    }

    private var borderColor: Color {
        isHovering
            ? Color.accentColor.opacity(0.35)
            : Color(nsColor: .separatorColor).opacity(0.3)
    }

    private var iconBackground: Color {
        Color.accentColor.opacity(isHovering ? 0.18 : 0.12)
    }

    private var iconForeground: Color {
        Color.accentColor
    }
}

private extension AIQuickAction {
    var subtitle: String {
        switch self {
        case .summarize: return "TL;DR of the page"
        case .askAboutPage: return "Ask anything about it"
        case .translate: return "Translate to Chinese"
        }
    }
}
