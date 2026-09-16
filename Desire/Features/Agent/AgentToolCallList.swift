import SwiftUI

/// Renders the list of tool invocations inside an assistant message as a
/// compact stack of pill-shaped chips.
struct ToolCallList: View {
    let toolCalls: [AgentToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolCalls) { call in
                ToolCallChip(toolCall: call)
            }
        }
        .padding(.top, 2)
    }
}

private struct ToolCallChip: View {
    let toolCall: AgentToolCall
    @State private var isExpanded = false
    @State private var isHovering = false

    private var iconName: String {
        switch toolCall.function.name {
        case "getPageText": "doc.text"
        case "getPageHTML": "chevron.left.forwardslash.chevron.right"
        case "getPageTitle": "textformat"
        case "screenshot": "camera"
        case "getSelectedText": "text.cursor"
        case "navigate": "arrow.right.circle"
        case "goBack": "arrow.left"
        case "goForward": "arrow.right"
        case "newTab": "plus.square.on.square"
        case "closeTab": "xmark.square"
        case "listTabs": "rectangle.stack"
        case "switchTab": "arrow.left.arrow.right.square"
        case "addBookmark": "bookmark"
        case "removeBookmark": "bookmark.slash"
        case "listBookmarks": "books.vertical"
        case "searchHistory": "clock"
        case "listHistory": "list.bullet.rectangle"
        case "openHistory": "clock.arrow.circlepath"
        case "clearHistory": "trash"
        case "getSettings": "gearshape"
        case "setSetting": "slider.horizontal.3"
        default: "wrench"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)
                Text(toolCall.function.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if !toolCall.function.arguments.isEmpty
                    && toolCall.function.arguments != "{}" {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chipBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !toolCall.function.arguments.isEmpty,
                      toolCall.function.arguments != "{}" else { return }
                withAnimation(.transitionNormal) { isExpanded.toggle() }
            }

            if isExpanded, !toolCall.function.arguments.isEmpty,
               toolCall.function.arguments != "{}" {
                Text(formatJSON(toolCall.function.arguments))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.5)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
    }

    private var chipBackground: Color {
        isHovering
            ? Color.accentColor.opacity(0.10)
            : Color(nsColor: .controlBackgroundColor).opacity(0.45)
    }

    private func formatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }
}
