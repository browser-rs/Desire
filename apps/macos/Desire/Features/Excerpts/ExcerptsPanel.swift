import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 摘录库面板（v0.8.17 融合旗舰）：阅读高亮/PDF 批注/网页划选的统一沉淀视图。
/// 搜索 + 类型过滤 + 导出 Markdown 笔记本；行级复制/打开来源/删除。
/// 挂在 Agent 窗口"摘录"目的地；数据源 ExcerptStore.shared（同步域第十三域）。
struct ExcerptsPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = ExcerptStore.shared

    @State private var query = ""
    @State private var kindFilter: Excerpt.Kind?
    @State private var exportCopied = false

    private var items: [Excerpt] { store.filtered(query: query, kind: kindFilter) }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(store.excerpts.isEmpty
                         ? String(localized: "No excerpts yet — save highlights from Reader, PDF annotations, or text selections")
                         : String(localized: "No excerpts match"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { excerpt in
                            row(excerpt)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 头部与过滤

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text("Excerpts")
                .font(.system(size: 13, weight: .semibold))
            Text("\(store.excerpts.count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                copyMarkdown()
            } label: {
                Label(exportCopied ? String(localized: "Copied") : String(localized: "Copy Markdown"),
                      systemImage: exportCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(items.isEmpty)
            Button {
                exportToFile()
            } label: {
                Label(String(localized: "Export .md"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(items.isEmpty)
            if !store.excerpts.isEmpty {
                Button {
                    store.clearAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Clear all (tombstones sync to other devices)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Search excerpts"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            Spacer(minLength: 8)
            ForEach(Excerpt.Kind.allCases, id: \.self) { kind in
                Button {
                    kindFilter = kindFilter == kind ? nil : kind
                } label: {
                    Text(kindLabel(kind))
                        .font(.system(size: 10, weight: kindFilter == kind ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(kindFilter == kind ? appAccent.opacity(0.14) : Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(kindFilter == kind ? appAccent : Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func kindLabel(_ kind: Excerpt.Kind) -> String {
        switch kind {
        case .readerHighlight: return String(localized: "Reading")
        case .pdfAnnotation: return String(localized: "PDF")
        case .webSelection: return String(localized: "Web")
        }
    }

    // MARK: - 行

    private func row(_ excerpt: Excerpt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(excerpt.content)
                .font(.system(size: 12))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = excerpt.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appAccent)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(kindLabel(excerpt.kind))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(appAccent)
                Text(excerpt.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(excerpt.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt.content, forType: .string)
            }
            Button(String(localized: "Open Source")) { openSource(excerpt) }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                store.remove(id: excerpt.id)
            }
        }
        .onTapGesture { openSource(excerpt) }
    }

    /// 网页来源开标签（file:// 走查看器路由）；其余复制路径。
    private func openSource(_ excerpt: Excerpt) {
        if excerpt.source.hasPrefix("http"), let url = URL(string: excerpt.source) {
            NSWorkspace.shared.open(url)
        } else if FileManager.default.fileExists(atPath: excerpt.source) {
            TabSessionCoordinator.shared.activeTabManager?.addTab(
                url: URL(fileURLWithPath: excerpt.source).absoluteString,
                javaScriptEnabled: true,
                contentBlocker: AppState.live?.contentBlocker)
        } else if excerpt.source.hasPrefix("/") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: excerpt.source)])
        }
    }

    // MARK: - 导出

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.exportMarkdown(query: query, kind: kindFilter), forType: .string)
        exportCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exportCopied = false }
    }

    private func exportToFile() {
        let markdown = store.exportMarkdown(query: query, kind: kindFilter)
        guard !markdown.isEmpty else { return }
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "excerpts-\(formatter.string(from: Date())).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? markdown.write(to: dest, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}
