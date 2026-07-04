import SwiftUI

struct AddressSuggestionsView: View {
    @ObservedObject var model: AddressSuggestionsModel
    var engineName: String
    var onSelect: (AddressSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(for: suggestion, at: index)
                if index < model.suggestions.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func row(for suggestion: AddressSuggestion, at index: Int) -> some View {
        HStack(spacing: 10) {
            leadingIcon(for: suggestion)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle(for: suggestion))
                    .lineLimit(1)
                    .foregroundStyle(suggestion.kind == .navigate ? .primary : .primary)
                if showsSubtitle(suggestion) {
                    Text(suggestion.url)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            kindBadge(for: suggestion)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == model.selectedIndex ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(suggestion)
        }
        .onHover { hovering in
            if hovering { model.selectedIndex = index }
        }
    }

    @ViewBuilder
    private func leadingIcon(for suggestion: AddressSuggestion) -> some View {
        switch suggestion.kind {
        case .navigate:
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .searchDefault, .searchSuggestion:
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .bookmark:
            Image(systemName: "bookmark")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .history:
            FaviconView(urlString: suggestion.url, size: 16)
        }
    }

    private func displayTitle(for suggestion: AddressSuggestion) -> String {
        switch suggestion.kind {
        case .searchDefault:
            return "在\(engineName)中搜索「\(suggestion.title)」"
        default:
            return suggestion.title
        }
    }

    private func showsSubtitle(_ suggestion: AddressSuggestion) -> Bool {
        switch suggestion.kind {
        case .navigate, .bookmark, .history:
            return true
        case .searchDefault, .searchSuggestion:
            return false
        }
    }

    @ViewBuilder
    private func kindBadge(for suggestion: AddressSuggestion) -> some View {
        switch suggestion.kind {
        case .bookmark:
            Text("书签")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        case .history:
            Text("历史")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
