import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewTabPage: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: QuickDialStore
    @Binding var urlString: String
    var onNavigate: (String) -> Void
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    /// 地址栏正在编辑时，本页的候补下拉让位——两份列表同时出现是用户报的
    /// "这两块不应该同时触发"。
    var isUrlBarEditing: Bool = false
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var historyStore: HistoryStore
    var settings: Settings
    @State private var searchText = ""
    @State private var editingDial: QuickDial?
    @State private var editTitle = ""
    @State private var editURL = ""
    @FocusState private var searchFocused: Bool
    /// 搜索框在 `space` 里的 frame：候选列表按它对齐（同宽、同起点、紧贴下沿）。
    /// 之前是写死的 `maxWidth: 520` + `.padding(.top, 102)`——框宽 560、列表 520，
    /// 居中后两边各内缩 20pt（用户截图："列表比输入框窄一圈"）；102 也会随书签栏
    /// 开关漂移。
    @State private var searchFieldFrame: CGRect = .zero
    /// 本页根视图的全局原点（差值用，见下）。
    @State private var rootGlobalX: CGFloat = 0
    @State private var rootGlobalY: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 20)]
    private let contentMaxWidth: CGFloat = 980

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)

            searchField
                .padding(.bottom, 36)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    quickDialsSection
                    localFilesSection

                    if !historyStore.entries.isEmpty {
                        recentSection
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: contentMaxWidth, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundGradient)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            if frame.minX != rootGlobalX || frame.minY != rootGlobalY {
                rootGlobalX = frame.minX
                rootGlobalY = frame.minY
            }
        }
        .overlay(alignment: .topLeading) {
            if searchFocused, !isUrlBarEditing, !suggestionModel.isEmpty, searchFieldFrame.width > 1 {
                AddressSuggestionsView(
                    // `maxWidth: nil` 是关键：视图内部默认把卡片卡在 520，不给它去掉，
                    // 卡片就会在下面那个"搜索框宽"的容器里左对齐、右边短一截
                    // （用户截图："很奇怪啊 这个要跟输入栏等宽"）。
                    maxWidth: nil,
                    model: suggestionModel,
                    engineName: settings.effectiveEngineName
                ) { sug in
                    suggestionModel.reset()
                    searchText = ""
                    onNavigate(sug.url)
                }
                // 与搜索框**同宽同起点**、紧贴其下沿（frame 实测，和地址栏一致）
                // 两者都按全局坐标测、这里取差值：不受"命名空间是否解析"影响，
                // 不会多出/少掉一段偏移（地址栏那处同理）。
                .frame(width: searchFieldFrame.width, alignment: .leading)
                .padding(.top, max(0, searchFieldFrame.maxY - rootGlobalY))
                .padding(.leading, max(0, searchFieldFrame.minX - rootGlobalX))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .popover(item: $editingDial) { dial in
            editForm(dial: dial)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索或输入网址", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { submitSearch() }
                // ↑/↓ 在候选列表里选、Esc 收起列表。此前**完全没有键盘处理**
                // （模型和列表都支持高亮，只是没人调用），用户报"不能用键盘上下选择"。
                // 注：`.onKeyPress` 的回调在 SwiftUI 更新事务里执行，直接改 model 会报
                // "Publishing changes from within view updates"（见 AGENTS.md），
                // 所以这里跳一帧再写。
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.escape) {
                    guard !suggestionModel.isEmpty else { return .ignored }
                    Task { @MainActor in suggestionModel.reset() }
                    return .handled
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        suggestionModel.reset()
                    } else {
                        suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                    }
                }
                .onChange(of: searchFocused) { _, focused in
                    if !focused { suggestionModel.reset() }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            if frame != searchFieldFrame { searchFieldFrame = frame }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - Quick Dials

    private var quickDialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "常用网站", icon: "square.grid.2x2")

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(store.dials.enumerated()), id: \.element.id) { index, dial in
                    QuickDialCard(
                        dial: dial,
                        index: index,
                        onNavigate: {
                            urlString = dial.url
                            onNavigate(dial.url)
                        },
                        onEdit: {
                            editingDial = dial
                            editTitle = dial.title
                            editURL = dial.url
                        },
                        onDelete: { store.delete(id: dial.id) },
                        onDragProvider: { NSItemProvider(object: NSString(string: "\(index)")) },
                        onDropAt: { target in
                            DialDropDelegate(targetIndex: target, store: store)
                        }
                    )
                }

                addButton
            }
        }
    }

    private var addButton: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .light))
            Text("添加")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: 130, height: 124)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            editingDial = QuickDial(title: "", url: "")
            editTitle = ""
            editURL = ""
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "最近访问", icon: "clock")

            VStack(spacing: 6) {
                ForEach(recentEntries) { entry in
                    RecentVisitedCard(entry: entry) {
                        onNavigate(entry.url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localFileCard(_ entry: RecentLocalFiles.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.filename)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(entry.kind)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Open")) { onNavigate(entry.url) }
            // 转换为…（v0.8.15 融合）：DocumentConvert 管道（与 Agent
            // convertDocument 工具共用），产物落源目录旁并入账。
            convertMenu(entry)
            // PDF 合并/拆分（v0.8.16）：PDFWorkbenchModel 静态管道。
            if entry.filename.lowercased().hasSuffix(".pdf") {
                Button(String(localized: "Merge with other PDFs…")) { mergePDF(entry) }
                Button(String(localized: "Split / extract pages…")) { splitPDF(entry) }
            }
            // 压缩为 zip（v0.8.14 基础件 5）：UI 侧补齐（Agent 侧 zipFiles 已通）。
            if entry.kind != "archive" {
                Button(String(localized: "Compress to zip…")) { compressToZip(entry) }
            }
            Divider()
            Button(String(localized: "Remove from list"), role: .destructive) {
                RecentLocalFiles.remove(urlString: entry.url)
            }
        }
    }

    /// 「转换为…」子菜单（v0.8.15）：按源类型列目标格式。
    private func convertTargets(for ext: String) -> [String] {
        switch ext {
        case "pdf": return ["md", "txt", "docx", "rtf", "html"]
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm": return ["pdf"]
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp": return ["pdf"]
        case "csv": return ["md", "tsv", "xlsx"]
        case "tsv": return ["md", "csv", "xlsx"]
        case "xlsx": return ["md", "csv", "tsv"]
        default: return []
        }
    }

    @ViewBuilder
    private func convertMenu(_ entry: RecentLocalFiles.Entry) -> some View {
        let targets = convertTargets(for: (entry.filename as NSString).pathExtension.lowercased())
        if !targets.isEmpty {
            Menu(String(localized: "Convert to…")) {
                ForEach(targets, id: \.self) { target in
                    Button("\(target.uppercased())…") { convertEntry(entry, format: target) }
                }
            }
        }
    }

    /// 合并 PDF（v0.8.16）：本文件在前，选中的其他 PDF 按选择顺序接在后面。
    private func mergePDF(_ entry: RecentLocalFiles.Entry) {
        guard let first = URL(string: entry.url) else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.pdf]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.message = String(localized: "Pick PDFs to append after \(entry.filename) (in selection order)")
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "merged.pdf"
        save.allowedContentTypes = [.pdf]
        guard save.runModal() == .OK, let dest = save.url else { return }
        if let pages = PDFWorkbenchModel.merge(files: [first] + open.urls, to: dest) {
            RecentLocalFiles.record(url: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            let alert = NSAlert()
            alert.messageText = String(localized: "Merged \(pages) page(s) → \(dest.lastPathComponent)")
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Merge failed")
            alert.informativeText = String(localized: "One of the files may be unreadable or password-protected.")
            alert.runModal()
        }
    }

    /// 拆分/提取页码范围（v0.8.16）："1-3,5" → 新 PDF（PageRangeParser 1-based）。
    private func splitPDF(_ entry: RecentLocalFiles.Entry) {
        guard let src = URL(string: entry.url) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Extract pages from \(entry.filename)")
        alert.informativeText = String(localized: "1-based page ranges, e.g. 1-3,7 (comma separated)")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "1-3,7"
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Extract"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let spec = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return }
        let base = (entry.filename as NSString).deletingPathExtension
        let save = NSSavePanel()
        save.nameFieldStringValue = "\(base)-pages.pdf"
        save.allowedContentTypes = [.pdf]
        guard save.runModal() == .OK, let dest = save.url else { return }
        if let pages = PDFWorkbenchModel.extractPages(from: src, spec: spec, to: dest) {
            RecentLocalFiles.record(url: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            let done = NSAlert()
            done.messageText = String(localized: "Extracted \(pages) page(s) → \(dest.lastPathComponent)")
            done.runModal()
        } else {
            let fail = NSAlert()
            fail.messageText = String(localized: "Extraction failed")
            fail.informativeText = String(localized: "Check the page range (the file may also be password-protected).")
            fail.runModal()
        }
    }

    /// 转换在后台跑（文档→PDF 离屏渲染需数秒），成功入账并在 Finder 选中。
    private func convertEntry(_ entry: RecentLocalFiles.Entry, format: String) {
        guard let src = URL(string: entry.url) else { return }
        let dest = src.deletingPathExtension().appendingPathExtension(format)
        Task { @MainActor in
            let outcome = await DocumentConvert.convert(sources: [src], format: format, to: dest)
            if outcome.ok {
                RecentLocalFiles.record(url: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Conversion failed")
                alert.informativeText = outcome.message
                alert.runModal()
            }
        }
    }

    /// 压缩为 zip（v0.8.14 基础件 5）：ditto -c -k 同目录落同名 zip。
    private func compressToZip(_ entry: RecentLocalFiles.Entry) {
        let src = URL(string: entry.url)?.path ?? ""
        guard FileManager.default.fileExists(atPath: src) else { return }
        let dest = (src as NSString).deletingPathExtension + ".zip"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", src, dest]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
        if let url = URL(string: "file://" + dest) {
            onNavigate(url.absoluteString)
        }
    }

    private var recentEntries: [RecentEntry] {
        historyStore.entries.prefix(8).map { entry in
            RecentEntry(
                id: entry.id,
                title: entry.title.isEmpty ? (URL(string: entry.url)?.host ?? entry.url) : entry.title,
                url: entry.url,
                host: URL(string: entry.url)?.host ?? entry.url
            )
        }
    }

    // MARK: - 最近本地文件（v0.8.12 基础件 10）

    private var localFilesSection: some View {
        let entries = RecentLocalFiles.load().prefix(6)
        return Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(title: "最近本地文件", icon: "doc.on.doc")
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            localFileCard(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    appAccent.opacity(0.06),
                    .clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

    /// 候选列表内的键盘选择。返回 `.handled` 才不让方向键去动光标；
    /// 列表为空时交还给文本域（跟地址栏那边的约定一致）。
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !suggestionModel.isEmpty else { return .ignored }
        Task { @MainActor in suggestionModel.moveSelection(by: delta) }
        return .handled
    }

    private func submitSearch() {
        // 回车优先打开**键盘高亮的候选**。第 0 行就是"搜索 / 前往 输入的内容"，
        // 所以没动过高亮时（刚输入完直接回车）行为与以前完全一致；
        // 用 ↑/↓ 选到书签、历史、其它建议时，回车就打开那一条。
        if suggestionModel.ownsCurrentInput(from: searchText),
           let selected = suggestionModel.selected() {
            suggestionModel.reset()
            searchText = ""
            onNavigate(selected.url)
            return
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suggestionModel.reset()
        onNavigate(trimmed)
    }

    // MARK: - Edit Form

    private func editForm(dial: QuickDial) -> some View {
        VStack(spacing: 12) {
            TextField("标题", text: $editTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            TextField("网址", text: $editURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            HStack(spacing: 12) {
                Button("取消") {
                    editingDial = nil
                }
                .keyboardShortcut(.escape)

                Button("保存") {
                    let trimmedTitle = editTitle.trimmingCharacters(in: .whitespaces)
                    let trimmedURL = editURL.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }

                    if store.dials.contains(where: { $0.id == dial.id }) {
                        store.update(id: dial.id, title: trimmedTitle, url: trimmedURL)
                    } else {
                        store.add(title: trimmedTitle, url: trimmedURL)
                    }
                    editingDial = nil
                }
                .keyboardShortcut(.return)
                .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty
                          || editURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
