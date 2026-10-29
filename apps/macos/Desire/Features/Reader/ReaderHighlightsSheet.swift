import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 阅读高亮列表（v0.7.29）：跳转、改色、备注、删除、复制 Markdown。
struct ReaderHighlightsSheet: View {
    let url: String
    @ObservedObject var store: ReaderHighlightStore
    let onJump: (UUID) -> Void
    let onClose: () -> Void

    private var items: [ReaderHighlight] { store.list(for: url) }
    /// 查找相关（v0.8.22 批二）。
    @State private var relatedRequest: SemanticRelatedRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Highlights")
                    .font(.headline)
                Spacer()
                Button("Export as .md") { exportToFile() }
                Button("Copy Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.markdown(for: url), forType: .string)
                }
                .disabled(items.isEmpty)
                Button("Close", action: onClose)
            }
            .padding()
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "highlighter")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No highlights on this page")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Select text in the reader, then press the highlighter button.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    onJump(item.id)
                                } label: {
                                    Text(item.quote)
                                        .font(.system(size: 12))
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                                Spacer(minLength: 6)
                                Menu {
                                    ForEach(ReaderHighlight.Color.allCases, id: \.self) { color in
                                        Button(color.title) {
                                            store.setColor(item.id, color)
                                        }
                                    }
                                } label: {
                                    Circle()
                                        .fill(swatch(item.color))
                                        .frame(width: 12, height: 12)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                Button {
                                    ExcerptStore.shared.add(
                                        kind: .readerHighlight,
                                        title: url,
                                        source: url,
                                        content: item.quote,
                                        note: item.note)
                                } label: {
                                    Image(systemName: "text.quote")
                                }
                                .buttonStyle(.plain)
                                .help("Save to Excerpts")
                                Button {
                                    relatedRequest = SemanticRelatedRequest(
                                        title: String(item.quote.prefix(60)),
                                        query: [item.quote, item.note ?? ""].joined(separator: " "),
                                        excludingID: "highlight:\(item.id.uuidString)")
                                } label: {
                                    Image(systemName: "sparkles")
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "Find Related"))
                                Button {
                                    store.delete(item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            TextField("Note (optional)",
                                      text: Binding(get: { item.note ?? "" },
                                                    set: { store.setNote(item.id, note: $0) }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 440, height: 460)
        .sheet(item: $relatedRequest) { SemanticRelatedSheet(request: $0) }
    }

    private func exportToFile() {
        let host = URL(string: url)?.host ?? url
        let text = store.markdown(for: url)
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = host + "-highlights.md"
        panel.begin { response in
            guard response == .OK, let saveURL = panel.url else { return }
            try? text.write(to: saveURL, atomically: true, encoding: .utf8)
        }
    }

    private func swatch(_ color: ReaderHighlight.Color) -> Color {
        switch color {
        case .yellow: return Color(red: 1.0, green: 0.90, blue: 0.56)
        case .green: return Color(red: 0.72, green: 0.92, blue: 0.56)
        case .blue: return Color(red: 0.57, green: 0.84, blue: 1.0)
        case .pink: return Color(red: 1.0, green: 0.68, blue: 0.82)
        }
    }
}
