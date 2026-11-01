import SwiftUI

/// 书内笔记侧栏（v0.8.35）：按章节分组列出高亮/笔记，支持跳转、改色、
/// 编辑备注、删除与导出。点正文高亮也会打开这里并定位到对应条目。
struct EbookNotesPanel: View {
    @Environment(\.appAccent) private var appAccent
    let book: Ebook
    let highlights: [EbookHighlight]
    let focusedID: UUID?
    let onJump: (EbookHighlight) -> Void
    let onColor: (UUID, EbookHighlightColor) -> Void
    let onNote: (UUID, String?) -> Void
    let onDelete: (UUID) -> Void
    let onExportBook: () -> Void
    let onExportAll: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var editingID: UUID?
    @State private var noteDraft = ""

    private var ordered: [EbookHighlight] {
        highlights.sorted {
            if $0.chapterIndex != $1.chapterIndex { return $0.chapterIndex < $1.chapterIndex }
            if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
            return $0.createdAt < $1.createdAt
        }
    }

    private struct ChapterGroup: Identifiable {
        let index: Int
        let title: String
        let items: [EbookHighlight]
        var id: Int { index }
    }

    private var groups: [ChapterGroup] {
        let grouped = Dictionary(grouping: ordered, by: \.chapterIndex)
        return grouped.keys.sorted().map { index in
            let items = grouped[index] ?? []
            return ChapterGroup(index: index,
                                title: items.first?.chapterTitle ?? "",
                                items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if ordered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 540, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(String(localized: "Edit note"), isPresented: noteAlertBinding) {
            TextField(String(localized: "Note"), text: $noteDraft)
            Button(String(localized: "Save")) {
                if let id = editingID { onNote(id, noteDraft) }
                editingID = nil
                noteDraft = ""
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                editingID = nil
                noteDraft = ""
            }
        } message: {
            Text(String(localized: "The note is saved together with the highlight."))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Notes & Highlights"))
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: "\(ordered.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Menu {
                Button(String(localized: "Export This Book…")) { onExportBook() }
                Button(String(localized: "Export All Books…")) { onExportAll() }
                Divider()
                Button(String(localized: "Copy Markdown")) { onCopy() }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(String(localized: "Export notes"))
            Button(String(localized: "Done")) { onClose() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "highlighter")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No highlights or notes yet"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "Select text in the book, then tap Highlight or Note."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(groups) { group in
                        Text(group.title.isEmpty
                             ? String(localized: "Chapter \(group.index + 1)")
                             : group.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(appAccent)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                        ForEach(group.items) { highlight in
                            row(highlight)
                                .id(highlight.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear { scroll(proxy, to: focusedID) }
            .onChange(of: focusedID) { _, id in scroll(proxy, to: id) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?) {
        guard let id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func row(_ highlight: EbookHighlight) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Menu {
                ForEach(EbookHighlightColor.allCases) { color in
                    Button {
                        onColor(highlight.id, color)
                    } label: {
                        Label(color.label,
                              systemImage: highlight.color == color ? "checkmark" : "circle.fill")
                    }
                }
            } label: {
                Circle()
                    .fill(color(highlight.color))
                    .frame(width: 11, height: 11)
                    .padding(.top, 3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Highlight color"))

            Button {
                onJump(highlight)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlight.quote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let note = highlight.trimmedNote {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(highlight.createdAt, format: .dateTime.year().month().day())
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Jump to highlight"))

            Button {
                editingID = highlight.id
                noteDraft = highlight.trimmedNote ?? ""
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Edit note"))

            Button {
                onDelete(highlight.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete highlight"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(focusedID == highlight.id
                    ? AnyShapeStyle(appAccent.opacity(0.10))
                    : AnyShapeStyle(Color.clear))
        .contentShape(Rectangle())
    }

    private var noteAlertBinding: Binding<Bool> {
        Binding(
            get: { editingID != nil },
            set: { if !$0 { editingID = nil } })
    }

    private func color(_ color: EbookHighlightColor) -> Color {
        let rgb = color.rgb
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 0.95)
    }
}
