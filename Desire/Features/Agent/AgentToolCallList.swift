import AppKit
import SwiftUI

/// Inline rendering of a `data:image/…` tool result inside a chip.
private struct InlineResultImage: View {
    let dataURI: String
    @State private var isHovering = false

    var body: some View {
        Group {
            if let image = decodedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            } else {
                Text("(undecodable image result)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onHover { isHovering = $0 }
        .help(isHovering ? "点击复制图片" : "")
        .onTapGesture {
            if let image = decodedImage {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
    }

    private var decodedImage: NSImage? {
        guard let comma = dataURI.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURI[dataURI.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

/// Renders the list of tool invocations inside an assistant message as a
/// compact stack of pill-shaped chips.
struct ToolCallList: View {
    let toolCalls: [AgentToolCall]
    var results: [String: String] = [:]
    /// toolCallId → 耗时（毫秒）。用来在聊天里直接看出"哪个工具慢"。
    var durations: [String: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolCalls) { call in
                ToolCallChip(toolCall: call, result: results[call.id], durationMs: durations[call.id])
            }
        }
        .padding(.top, 2)
    }
}

private struct ToolCallChip: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let toolCall: AgentToolCall
    var result: String?
    var durationMs: Double?
    @State private var isExpanded = false
    @State private var isHovering = false

    private var iconName: String {
        switch toolCall.function.name {
        case "getPageText": "doc.text"
        case "getPageHTML": "chevron.left.forwardslash.chevron.right"
        case "getPageTitle": "textformat"
        case "screenshot": "camera"
        case "screenshotElement": "camera.metering.spot"
        case "getSelectedText": "text.cursor"
        case "spawnSubagent": "person.2"
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
        case "scheduleTask": "clock.badge.plus"
        case "listScheduledTasks": "clock"
        case "cancelScheduledTask": "clock.badge.xmark"
        case "runCommand": "terminal"
        case "downloadMedia": "arrow.down.circle"
        case "renderDiagram": "paintbrush"
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
                    .foregroundStyle(appAccent)
                    .frame(width: 14)
                Text(toolCall.function.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let durationMs {
                    Text(verbatim: durationMs >= 1000
                         ? String(format: "%.1fs", durationMs / 1000)
                         : String(format: "%.0fms", durationMs))
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if result != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green.opacity(0.8))
                }
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
                guard hasDetails else { return }
                withAnimation(.transitionNormal) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // 页面感知回证（0.3.2）：动作类工具附"执行后视口"快照。
                    if AgentEvidenceStore.evidenceTools.contains(toolCall.function.name),
                       let evidence = AgentEvidenceStore.shared.image(for: toolCall.id) {
                        Text("EVIDENCE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                        Image(nsImage: evidence)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    if !toolCall.function.arguments.isEmpty,
                       toolCall.function.arguments != "{}" {
                        Text("ARGS")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(formatJSON(toolCall.function.arguments))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let result = result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                        Text("RESULT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                        if result.hasPrefix("data:image/") {
                            // Screenshots and element captures render inline —
                            // a "(image returned)" placeholder hides exactly
                            // what the user wants to verify.
                            InlineResultImage(dataURI: result)
                        } else {
                            Text(result.count > 1200 ? String(result.prefix(1200)) + "…" : result)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
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

    private var hasDetails: Bool {
        let hasArgs = !toolCall.function.arguments.isEmpty
            && toolCall.function.arguments != "{}"
        let hasResult = !(result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasEvidence = AgentEvidenceStore.evidenceTools.contains(toolCall.function.name)
            && AgentEvidenceStore.shared.image(for: toolCall.id) != nil
        return hasArgs || hasResult || hasEvidence
    }

    private var chipBackground: Color {
        isHovering
            ? appAccent.opacity(0.10)
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
