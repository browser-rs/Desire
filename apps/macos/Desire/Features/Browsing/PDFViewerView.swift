import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 内建 PDF 查看器：主框架导航落 application/pdf 时由
/// BrowserState.presentPDFViewer 拦下，下载到临时文件后在这里用 PDFKit 渲染。
/// v0.8.15 PDF 工作台：大纲/缩略图/批注三 tab 侧栏、⌘F 查找、页码跳转、
/// 批注（高亮/下划线/便签/箭头/矩形）、页面管理（旋转/删除/重排/提取）与 ⌘S 另存。
/// 模型在 PDFWorkbenchModel（Store 层）；本文件只渲染 + PDFView 子类的事件拦截。
struct PDFViewerView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var model: PDFWorkbenchModel?
    @State private var zoom: CGFloat = 1
    @State private var loadFailed = false
    /// 侧栏：nil = 收起；大纲/缩略图/批注/表单四态。
    @State private var sidebar: SidebarTab?
    @State private var pageJumpText = ""
    @State private var searchVisible = false
    @State private var searchQuery = ""
    @State private var noteText = ""
    /// 缩略图就绪回调自增触发重算（懒生成完成即上屏）。
    @State private var thumbnailTick = 0
    // 加密解锁（v0.8.16）
    @State private var passwordText = ""
    @State private var unlockFailed = false
    /// 双页对开（v0.8.17 基础件 4）。
    @State private var isTwoUp = false

    enum SidebarTab {
        case outline, thumbnails, annotations, forms
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            HStack(spacing: 0) {
                if let sidebar, let model, !model.isLocked {
                    sidebarPane(model, tab: sidebar)
                        .frame(width: 190)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                }
                if let model {
                    if model.isLocked {
                        lockedPane(model)
                    } else {
                        PDFKitRepresentedView(model: model, zoom: $zoom, twoUp: isTwoUp)
                            .ignoresSafeArea(edges: .bottom)
                    }
                } else if loadFailed {
                    errorPane
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            if searchVisible, let model, !model.isLocked {
                searchBar(model)
            }
        }
        .overlay {
            if let model, let pending = model.pendingNote {
                noteInputSheet(model, pending: pending)
            }
        }
        .overlay(alignment: .bottom) {
            if let note = model?.statusNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .background {
            // ⇧⌘C 原样复制（v0.8.18）：⌘C 走段落化（PDFView.copy override），
            // 需要原始断行时用这个。
            Button {
                if let text = model?.attachedView?.currentSelection?.string, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    model?.statusNote = String(localized: "Copied raw text")
                }
            } label: { EmptyView() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .onAppear(perform: load)
        .onDisappear {
            model?.zoomValue = Double(zoom)
            model?.savePosition(filePath: fileURL.path)
        }
        .onChange(of: fileURL) { _, _ in
            model?.zoomValue = Double(zoom)
            model?.savePosition(filePath: fileURL.path)
            model = nil
            loadFailed = false
            load()
        }
        // 进度记忆：翻页/缩放即存（UserDefaults 写入廉价；恢复在 load）。
        .onChange(of: model?.pageIndex) { _, _ in
            guard let model, !model.isLocked else { return }
            model.zoomValue = Double(zoom)
            model.savePosition(filePath: fileURL.path)
        }
        .onChange(of: zoom) { _, newZoom in
            guard let model, !model.isLocked else { return }
            model.zoomValue = Double(newZoom)
            model.savePosition(filePath: fileURL.path)
        }
    }

    private func load() {
        guard model == nil else { return }
        // fileURL 可能带 #page=N fragment（摘录库深链，v0.8.18）：
        // PDFDocument 打开用净路径，fragment 解析成初始页码。
        let cleanURL = URL(fileURLWithPath: fileURL.path)
        var initialPage: Int?
        if let fragment = fileURL.fragment(),
           fragment.hasPrefix("page="), let n = Int(fragment.dropFirst("page=".count)), n >= 1 {
            initialPage = n - 1
        }
        if let m = PDFWorkbenchModel.load(fileURL: cleanURL, fileName: fileName) {
            model = m
            if m.isLocked { return }
            if let initialPage, initialPage < m.pageCount {
                m.requestGoToPage(initialPage)
                m.statusNote = String(localized: "Opened at page \(initialPage + 1)")
                if m.annotationCount > 0 {
                    m.statusNote = String(localized: "This PDF contains \(m.annotationCount) annotation(s)")
                }
                return
            }
            // 阅读进度记忆（v0.8.16）：恢复上次页码与缩放。
            if let pos = PDFWorkbenchModel.loadPosition(filePath: fileURL.path),
               pos.page < m.pageCount {
                m.zoomValue = pos.zoom
                zoom = CGFloat(pos.zoom)
                m.requestGoToPage(pos.page)
                m.statusNote = String(localized: "Back to your last position · p\(pos.page + 1)")
            }
            if m.annotationCount > 0 {
                m.statusNote = String(localized: "This PDF contains \(m.annotationCount) annotation(s)")
            }
        } else {
            loadFailed = true
        }
    }

    /// 加密 PDF 密码浮层（v0.8.16）：解锁前不渲染内容；错码原地重试。
    private func lockedPane(_ model: PDFWorkbenchModel) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(String(localized: "This PDF is password-protected"))
                .font(.system(size: 12, weight: .medium))
            SecureField(String(localized: "Password"), text: $passwordText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { tryUnlock(model) }
            if unlockFailed {
                Text(String(localized: "Wrong password — try again"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            Button(String(localized: "Unlock")) { tryUnlock(model) }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Back to Page")) { onBack() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tryUnlock(_ model: PDFWorkbenchModel) {
        guard model.unlock(withPassword: passwordText) else {
            unlockFailed = true
            passwordText = ""
            return
        }
        unlockFailed = false
        passwordText = ""
        // 与 load() 同一条恢复路径。
        if let pos = PDFWorkbenchModel.loadPosition(filePath: fileURL.path),
           pos.page < model.pageCount {
            model.zoomValue = pos.zoom
            zoom = CGFloat(pos.zoom)
            model.requestGoToPage(pos.page)
        }
        model.statusNote = String(localized: "Unlocked")
    }

    private var errorPane: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "Could not open this PDF."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)

            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if model?.hasUnsavedChanges == true {
                Text("Edited")
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            if let model {
                HStack(spacing: 3) {
                    TextField("1", text: $pageJumpText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 34)
                        .onSubmit { jumpToPage(model) }
                    Text("/ \(model.pageCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

                Button {
                    searchVisible.toggle()
                    if !searchVisible { model.runSearch("") }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("f", modifiers: .command)
                .help(String(localized: "Find (⌘F)"))

                Button {
                    savePDF(model)
                } label: {
                    Label(String(localized: "Save (⌘S)"), systemImage: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.hasUnsavedChanges)
                .help(String(localized: "Export annotated PDF (⌘S)"))

                Button {
                    askAgentAboutPDF(model)
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help(String(localized: "Ask Agent about this PDF (⌘⇧A)"))
            }

            Button {
                zoom = max(0.5, zoom - 0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            Text("\(Int(zoom * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 34)
            Button {
                zoom = min(4, zoom + 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            Button {
                zoom = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Reset Zoom"))

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: fileURL.path))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open in Preview"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func jumpToPage(_ model: PDFWorkbenchModel) {
        guard let n = Int(pageJumpText.trimmingCharacters(in: .whitespaces)),
              n >= 1, n <= model.pageCount else {
            pageJumpText = ""
            return
        }
        model.requestGoToPage(n - 1)
        pageJumpText = ""
    }

    private func savePDF(_ model: PDFWorkbenchModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.suggestedName
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        _ = model.save(to: dest)
    }

    /// PDF 问 Agent（⌘⇧A，v0.8.15）：取文预填提问进活会话，
    /// 管道对齐文档查看器的 askAboutDocument。
    private func askAgentAboutPDF(_ model: PDFWorkbenchModel) {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            model.statusNote = String(localized: "No live agent session")
            return
        }
        let text = PDFTextExtractor.extractText(from: fileURL, maxChars: 8_000) ?? ""
        let prompt = String(localized: "请阅读这份 PDF（\(fileName)）并回答我的问题。内容：\n\(text)\n\n我的问题：")
        session.sendMessage(prompt, recordHistory: true)
        NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
        model.statusNote = String(localized: "Sent to the Agent")
    }

    // MARK: - 工具条（侧栏切换 + 批注工具）

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                sidebarTabButton("sidebar.leading", tab: .outline,
                                 help: String(localized: "Outline"))
                sidebarTabButton("photo.on.rectangle", tab: .thumbnails,
                                 help: String(localized: "Page thumbnails"))
                sidebarTabButton("note.text", tab: .annotations,
                                 help: String(localized: "Annotations"))
                sidebarTabButton("checklist", tab: .forms,
                                 help: String(localized: "Form fields"))
            }
            Divider().frame(height: 14)
            Button {
                isTwoUp.toggle()
            } label: {
                Image(systemName: isTwoUp ? "rectangle.split.2x1" : "rectangle")
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isTwoUp ? appAccent.opacity(0.14) : Color.clear))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isTwoUp ? appAccent : Color.secondary)
            .help(isTwoUp ? String(localized: "Two-up view") : String(localized: "Single page"))
            if let model, !model.isLocked {
                HStack(spacing: 3) {
                    ForEach(PDFWorkbenchModel.AnnotationTool.allCases, id: \.rawValue) { t in
                        Button {
                            model.tool = t
                        } label: {
                            Image(systemName: t.icon)
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(model.tool == t ? appAccent.opacity(0.14) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.tool == t ? appAccent : Color.secondary)
                        .help(toolHelp(t))
                    }
                }
                if model.tool == .highlight || model.tool == .underline {
                    Text(String(localized: "Select text to apply"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                // 全文朗读（v0.8.20 基础件 3）：三态（播/暂停/停）。
                if model.isSpeaking {
                    Button {
                        model.toggleSpeech()
                    } label: {
                        Image(systemName: model.speakingPaused ? "play.circle" : "pause.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appAccent)
                    Button {
                        model.stopSpeech()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.toggleSpeech()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Read aloud from this page"))
                }
                Spacer(minLength: 8)
                Button {
                    model.undoPageOperation()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!model.canUndoPage)
                .keyboardShortcut("z", modifiers: .command)
                .help(String(localized: "Undo page change (⌘Z)"))
                Button {
                    sendSelectionToWhiteboard(model)
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Send the selected text to the whiteboard"))
            } else {
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func sidebarTabButton(_ icon: String, tab: SidebarTab, help: String) -> some View {
        Button {
            sidebar = sidebar == tab ? nil : tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(sidebar == tab ? appAccent.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(sidebar == tab ? appAccent : Color.secondary)
        .help(help)
    }

    private func toolHelp(_ t: PDFWorkbenchModel.AnnotationTool) -> String {
        switch t {
        case .none: return String(localized: "Select & scroll")
        case .highlight: return String(localized: "Highlight selection")
        case .underline: return String(localized: "Underline selection")
        case .note: return String(localized: "Click to place a text note")
        case .arrow: return String(localized: "Drag to draw an arrow")
        case .rectangle: return String(localized: "Drag to draw a rectangle")
        }
    }

    // MARK: - 侧栏三态

    @ViewBuilder
    private func sidebarPane(_ model: PDFWorkbenchModel, tab: SidebarTab) -> some View {
        switch tab {
        case .outline:
            outlinePane(model)
        case .thumbnails:
            thumbnailsPane(model)
        case .annotations:
            annotationsPane(model)
        case .forms:
            formsPane(model)
        }
    }

    /// AcroForm 字段面板（v0.8.16）：文本字段行内编辑（提交即写、⌘S 落盘）；
    /// 按钮/勾选/签名只读展示。
    private func formsPane(_ model: PDFWorkbenchModel) -> some View {
        let fields = model.formFields()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if fields.isEmpty {
                    Text(String(localized: "No form fields in this PDF"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                }
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        if field.isText {
                            TextField(field.name, text: Binding(
                                get: { field.annotation.widgetStringValue ?? "" },
                                set: { model.setFormValue(field.annotation, value: $0) }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        } else {
                            Text(field.value)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Text("p\(field.pageIndex + 1) · \(field.name)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.requestGoToPage(field.pageIndex)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func outlinePane(_ model: PDFWorkbenchModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.outlineItems.isEmpty {
                    Text(String(localized: "No outline in this PDF"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                }
                ForEach(model.outlineItems) { item in
                    Button {
                        if let dest = item.destination {
                            model.requestGoToDestination(dest)
                        }
                    } label: {
                        Text(item.label)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10 + CGFloat(item.indent) * 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func thumbnailsPane(_ model: PDFWorkbenchModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        thumbnailCell(model, index: index)
                            .id(index)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.pageIndex) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    private func thumbnailCell(_ model: PDFWorkbenchModel, index: Int) -> some View {
        let image = model.thumbnail(for: index, width: 150) { thumbnailTick += 1 }
        return VStack(spacing: 3) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.1))
                        .aspectRatio(3 / 4, contentMode: .fit)
                }
            }
            .frame(width: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(model.pageIndex == index ? appAccent : Color.clear, lineWidth: 2))
            .contextMenu { pageMenu(model, index: index) }
            Text("\(index + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(model.pageIndex == index ? AnyShapeStyle(appAccent) : AnyShapeStyle(.tertiary))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.requestGoToPage(index)
        }
    }

    /// 缩略图右键：旋转 / 提取本页 / 上下移动 / 删除。
    private func pageMenu(_ model: PDFWorkbenchModel, index: Int) -> some View {
        Group {
            Button(String(localized: "Rotate 90°")) { model.rotatePage(index) }
            Button(String(localized: "Extract page as PDF…")) { extractPage(model, index: index) }
            Button(String(localized: "Move up")) {
                if index > 0 { model.movePage(from: index, to: index - 1) }
            }
            .disabled(index == 0)
            Button(String(localized: "Move down")) {
                if index < model.pageCount - 1 { model.movePage(from: index, to: index + 1) }
            }
            .disabled(index == model.pageCount - 1)
            Divider()
            Button(String(localized: "Delete page"), role: .destructive) { model.deletePage(index) }
                .disabled(model.pageCount <= 1)
        }
    }

    private func extractPage(_ model: PDFWorkbenchModel, index: Int) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.suggestedName)-p\(index + 1).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if model.extractPage(index, to: dest) {
            model.statusNote = String(localized: "Page exported → \(dest.lastPathComponent)")
        }
    }

    private func annotationsPane(_ model: PDFWorkbenchModel) -> some View {
        let items = model.allAnnotations()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text(String(localized: "No annotations yet — pick a tool above"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(annotionPreview(item.annotation))
                            .font(.system(size: 10.5))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("p\(item.pageIndex + 1) · \(kindName(item.annotation))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(String(localized: "Save to Excerpts")) {
                            saveAnnotationToExcerpts(model, item: item)
                        }
                        Divider()
                        Button(String(localized: "Delete annotation"), role: .destructive) {
                            model.removeAnnotation(item.annotation, pageIndex: item.pageIndex)
                        }
                    }
                    .onTapGesture {
                        model.requestGoToPage(item.pageIndex)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// 批注收进摘录库（v0.8.17）：文本内容 + 页码引用；空内容批注跳过。
    private func saveAnnotationToExcerpts(_ model: PDFWorkbenchModel,
                                          item: (annotation: PDFAnnotation, pageIndex: Int)) {
        let text = (item.annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            model.statusNote = String(localized: "Nothing to save (shape annotations carry no text)")
            return
        }
        ExcerptStore.shared.add(
            kind: .pdfAnnotation,
            title: "\(fileName) · p\(item.pageIndex + 1)",
            source: fileURL.path,
            content: text)
        model.statusNote = String(localized: "Saved to Excerpts")
    }

    private func annotionPreview(_ a: PDFAnnotation) -> String {
        let text = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "…" : text
    }

    private func kindName(_ a: PDFAnnotation) -> String {
        switch a.type ?? "" {
        case "Highlight": return String(localized: "Highlight")
        case "Underline": return String(localized: "Underline")
        case "FreeText": return String(localized: "Note")
        case "Line": return String(localized: "Arrow")
        case "Square": return String(localized: "Rectangle")
        default: return a.type ?? "Unknown"
        }
    }

    // MARK: - 查找条

    private func searchBar(_ model: PDFWorkbenchModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Find in PDF"), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 180)
                .onSubmit {
                    model.runSearch(searchQuery)
                    submitSearch(model, offset: model.search.matches.isEmpty ? 0 : 1)
                }
                .onChange(of: searchQuery) { _, q in
                    model.runSearch(q)
                }
            if !model.search.matches.isEmpty {
                Text("\(model.search.current + 1)/\(model.search.matches.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    submitSearch(model, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                Button {
                    submitSearch(model, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
            } else if !model.search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(String(localized: "No matches"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button {
                searchVisible = false
                searchQuery = ""
                model.runSearch("")
                model.clearSearchSelection()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 3))
        .padding(.top, 8)
    }

    private func submitSearch(_ model: PDFWorkbenchModel, offset: Int) {
        if let sel = model.selectMatch(at: model.search.current + offset) {
            model.requestSelect(sel)
        }
    }

    // MARK: - 便签输入层

    private func noteInputSheet(_ model: PDFWorkbenchModel, pending: PDFWorkbenchModel.PendingNote) -> some View {
        VStack(spacing: 8) {
            Text(String(localized: "Text note — page \(pending.pageIndex + 1)"))
                .font(.system(size: 11, weight: .medium))
            TextField(String(localized: "Note text"), text: $noteText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 240)
                .onSubmit { commitNote(model, pending: pending) }
            HStack(spacing: 8) {
                Button(String(localized: "Cancel")) {
                    noteText = ""
                    model.pendingNote = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) { commitNote(model, pending: pending) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial).shadow(radius: 6))
    }

    /// 选区上白板（v0.8.15 融合）：文本块带页码引用（from:"pdf-selection"
    /// 语义），与网页选区/截图上板同管线。
    private func sendSelectionToWhiteboard(_ model: PDFWorkbenchModel) {
        guard let selection = model.currentSelectionWithPage() else {
            model.statusNote = String(localized: "Select text first")
            return
        }
        let block = WhiteboardBlock(
            type: WhiteboardBlock.Kind.note,
            title: String(localized: "\(fileName) · p\(selection.pageIndex + 1)"),
            content: selection.text)
        WhiteboardStore.shared.append(
            [block],
            title: String(localized: "PDF selection"),
            conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
        model.statusNote = String(localized: "Sent to the whiteboard")
    }

    private func commitNote(_ model: PDFWorkbenchModel, pending: PDFWorkbenchModel.PendingNote) {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let page = model.document.page(at: pending.pageIndex) {
            model.addNote(text, page: page, point: pending.point)
        }
        noteText = ""
        model.pendingNote = nil
    }
}

// MARK: - PDFKit 包装（含批注绘制的鼠标拦截）

/// PDFView 子类：按当前工具拦截鼠标——arrow/rectangle 拖拽绘制、note 点击落点、
/// highlight/underline 在 mouseUp 后把选区交给模型。其余情况走默认选择/滚动。
final class PDFWorkbenchMouseView: PDFView {
    var annotationTool: PDFWorkbenchModel.AnnotationTool = .none
    var onNoteTapped: ((PDFPage, CGPoint, Int) -> Void)?
    var onSelectionSettled: (() -> Void)?
    var onScaleChanged: (() -> Void)?
    var onPageChanged: (() -> Void)?
    var onShapeDrawn: ((PDFPage, CGPoint, CGPoint) -> Void)?

    private var dragStart: (page: PDFPage, point: CGPoint)?
    private var didDrag = false

    /// ⌘C 段落化复制（v0.8.18）：PDF 文本层按视觉行断行，原样复制满行
    /// 硬换行——重排后进剪贴板；原样复制走 ⇧⌘C（视图层的隐藏按钮）。
    override func copy(_ sender: Any?) {
        guard let text = currentSelection?.string, !text.isEmpty else {
            super.copy(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TextParagraphize.paragraphized(text), forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch annotationTool {
        case .note:
            if let page = page(for: location, nearest: true) {
                let pagePoint = convert(location, to: page)
                onNoteTapped?(page, pagePoint, document?.index(for: page) ?? 0)
            }
            return
        case .arrow, .rectangle:
            if let page = page(for: location, nearest: true) {
                dragStart = (page, convert(location, to: page))
                didDrag = false
            }
            return
        case .none, .highlight, .underline:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if dragStart != nil {
            didDrag = true
            return   // 绘制中不给 PDFView 做滚动
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let start = dragStart {
            dragStart = nil
            let location = convert(event.locationInWindow, from: nil)
            // 几乎没拖动视为误触，忽略（防小点）；真拖了才落形状。
            if didDrag, let page = page(for: location, nearest: true) {
                let end = convert(location, to: page)
                onShapeDrawn?(page, start.point, end)
            }
            return
        }
        super.mouseUp(with: event)
        if annotationTool == .highlight || annotationTool == .underline {
            onSelectionSettled?()
        }
    }
}

private struct PDFKitRepresentedView: NSViewRepresentable {
    let model: PDFWorkbenchModel
    @Binding var zoom: CGFloat
    var twoUp = false

    func makeNSView(context: Context) -> PDFWorkbenchMouseView {
        let view = PDFWorkbenchMouseView()
        view.autoScales = true
        view.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        view.document = model.document
        context.coordinator.view = view
        model.attachedView = view

        // 闭包在 make 时捕获 model（@State 常驻实例）与 zoom binding（引用语义）；
        // 回调全部发自主线程（鼠标事件 / 主线程通知），直接读写即可。
        view.onScaleChanged = { [weak view] in
            guard let view else { return }
            zoom = view.scaleFactor
        }
        view.onPageChanged = { [weak view] in
            guard let view, let page = view.currentPage,
                  let idx = view.document?.index(for: page) else { return }
            model.updatePageIndex(idx)
        }
        view.onSelectionSettled = { [weak view] in
            view?.window?.makeFirstResponder(view)
            model.annotateSelection(view?.currentSelection)
        }
        view.onNoteTapped = { [weak view] _, point, index in
            guard view != nil else { return }
            model.pendingNote = .init(pageIndex: index, point: point)
        }
        view.onShapeDrawn = { page, from, to in
            model.addShape(model.tool, page: page, from: from, to: to)
        }

        // 缩放**双向**：按钮/代码写 scaleFactor；捏合/⌘滚轮经通知回写 @State。
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PDFWorkbenchMouseView, context: Context) {
        if view.document !== model.document { view.document = model.document }
        view.annotationTool = model.tool
        let mode: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode { view.displayMode = mode }
        if abs(view.scaleFactor - zoom) > 0.01 {
            view.scaleFactor = zoom
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: PDFWorkbenchMouseView?
        @objc func scaleChanged() { view?.onScaleChanged?() }
        @objc func pageChanged() { view?.onPageChanged?() }
    }
}

extension PDFView {
    /// go(to:) 只接 PDFDestination——按页号跳转补一个便捷方法（跳到页面顶部）。
    func goToPageInDocument(_ index: Int) {
        guard let page = document?.page(at: index) else { return }
        let dest = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).height))
        go(to: dest)
    }
}
