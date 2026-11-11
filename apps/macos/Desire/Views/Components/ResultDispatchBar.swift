import AppKit
import SwiftUI

/// 工具结果的分发条（v0.8.51 批 4）：白板 / 摘录 / 复制 Markdown。
/// Primitive——**不碰存储**：白板与摘录通过调用方闭包（返回是否成功），
/// 复制在本地完成（剪贴板，无持久化）。
struct ResultDispatchBar: View {
    let text: String
    let toolName: String
    /// 返回 true 才显示"已发送"。
    var onWhiteboard: (() -> Bool)? = nil
    var onExcerpt: (() -> Bool)? = nil

    @State private var whiteboardDone = false
    @State private var excerptDone = false
    @State private var copied = false

    var body: some View {
        if ToolResultDispatch.text(text) != nil {
            HStack(spacing: 6) {
                if let onWhiteboard {
                    chip(icon: whiteboardDone ? "checkmark" : "rectangle.3.group",
                         title: whiteboardDone
                            ? String(localized: "Sent to the whiteboard")
                            : String(localized: "Add to Whiteboard"),
                         active: whiteboardDone,
                         help: String(localized: "Send this output to the whiteboard")) {
                        if onWhiteboard() { flash($whiteboardDone) }
                    }
                }
                if let onExcerpt {
                    chip(icon: excerptDone ? "checkmark" : "bookmark",
                         title: excerptDone
                            ? String(localized: "Saved to Excerpts")
                            : String(localized: "Save to Excerpts"),
                         active: excerptDone,
                         help: String(localized: "Save this output to Excerpts")) {
                        if onExcerpt() { flash($excerptDone) }
                    }
                }
                chip(icon: copied ? "checkmark" : "doc.on.doc",
                     title: copied ? String(localized: "Copied") : String(localized: "Copy Markdown"),
                     active: copied,
                     help: String(localized: "Copy as a Markdown code block")) {
                    let markdown = ToolResultDispatch.markdown(tool: toolName, result: text)
                    guard !markdown.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    flash($copied)
                }
            }
        }
    }

    private func chip(icon: String, title: String, active: Bool, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 1.4s 后复位（与 CopyChip 同节奏）。
    private func flash(_ state: Binding<Bool>) {
        state.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            state.wrappedValue = false
        }
    }
}
