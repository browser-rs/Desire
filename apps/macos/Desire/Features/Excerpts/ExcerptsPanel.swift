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
    /// 摘录起草（v0.8.18 融合 9）：多选 → 拼 prompt 交活会话。
    @State private var isSelectingExcerpts = false
    @State private var selectedExcerptIDs: Set<UUID> = []

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
            if isSelectingExcerpts {
                Button {
                    draftWithAgent()
                } label: {
                    Label(String(localized: "Draft with Agent (\(selectedExcerptIDs.count))"),
                          systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .disabled(selectedExcerptIDs.isEmpty)
            }
            Button {
                if isSelectingExcerpts { selectedExcerptIDs.removeAll() }
                isSelectingExcerpts.toggle()
            } label: {
                Image(systemName: isSelectingExcerpts ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelectingExcerpts ? appAccent : Color.secondary)
            .help(String(localized: "Select excerpts for drafting"))
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
            // 分享卡（v0.8.19 融合 13）：渲染成图 → 剪贴板 + 另存。
            Button(String(localized: "Export Share Card…")) { exportShareCard(excerpt) }
            Button(String(localized: "Open Source")) { openSource(excerpt) }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                store.remove(id: excerpt.id)
            }
        }
        .onTapGesture {
            if isSelectingExcerpts {
                if selectedExcerptIDs.contains(excerpt.id) {
                    selectedExcerptIDs.remove(excerpt.id)
                } else {
                    selectedExcerptIDs.insert(excerpt.id)
                }
            } else {
                openSource(excerpt)
            }
        }
    }

    /// 选中摘录 → prompt（带来源）交活会话起草周报/笔记/摘要。
    private func draftWithAgent() {
        let chosen = store.excerpts.filter { selectedExcerptIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        guard let session = AgentScheduler.shared.deliveryTarget else {
            statusFlash(String(localized: "No live agent session"))
            return
        }
        var body = String(localized: "请基于下面这些摘录起草一份成稿（周报/笔记/摘要，按内容形态自选结构）。逐条保留来源标注。\n\n")
        for excerpt in chosen {
            body += "【\(excerpt.title) · \(excerpt.kindLabel)】\n\(excerpt.content)\n"
            if let note = excerpt.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                body += "（我的批注：\(note)）\n"
            }
            body += "\n"
        }
        session.sendMessage(body, recordHistory: true)
        NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
        statusFlash(String(localized: "Sent \(chosen.count) excerpt(s) to the Agent"))
        isSelectingExcerpts = false
        selectedExcerptIDs.removeAll()
    }

    @State private var statusNote: String?
    private func statusFlash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if statusNote == text { statusNote = nil }
        }
    }

    /// 分享卡（v0.8.19 融合 13）：渲染成图，剪贴板就绪 + 另存面板。
    private func exportShareCard(_ excerpt: Excerpt) {
        let accent = NSColor(appAccent)
        let image = ExcerptShareCard.render(excerpt: excerpt, accent: accent)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "excerpt-\(formatter.string(from: Date())).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dest)
    }

    /// 网页来源开标签（file:// 走查看器路由）；其余复制路径。
    /// PDF 来源带 #page=N fragment（保存端写入）——fragment 顺 URL 流到
    /// PDFViewerView 解析成初始页码。
    private func openSource(_ excerpt: Excerpt) {
        if excerpt.source.hasPrefix("http"), let url = URL(string: excerpt.source) {
            NSWorkspace.shared.open(url)
            return
        }
        let (path, page) = Self.splitPageFragment(excerpt.source)
        guard FileManager.default.fileExists(atPath: path) else {
            if excerpt.source.hasPrefix("/") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: excerpt.source)])
            }
            return
        }
        var url = URL(fileURLWithPath: path)
        if let page {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.fragment = "page=\(page)"
            url = components.url!
        }
        TabSessionCoordinator.shared.activeTabManager?.addTab(
            url: url.absoluteString,
            javaScriptEnabled: true,
            contentBlocker: AppState.live?.contentBlocker)
    }

    /// "path#page=N" → (path, N)；无 fragment → (原串, nil)。
    nonisolated static func splitPageFragment(_ source: String) -> (path: String, page: Int?) {
        guard let range = source.range(of: "#page=") else { return (source, nil) }
        let page = Int(source[range.upperBound...])
        return (String(source[..<range.lowerBound]), page)
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
