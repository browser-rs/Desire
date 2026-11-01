import AppKit
import SwiftUI

/// 电子书阅读器（v0.8.34 批次一）：EPUB/TXT 章节阅读、目录、进度、主题。
struct EbookReaderView: View {
    private enum SheetTab: String, CaseIterable, Identifiable {
        case contents, bookmarks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .contents: return String(localized: "Contents")
            case .bookmarks: return String(localized: "Bookmarks")
            }
        }
    }

    @Environment(\.appAccent) private var appAccent: Color
    let book: Ebook
    let onBack: () -> Void

    @StateObject private var model: EbookReaderModel
    @State private var sheetTab: SheetTab = .contents
    @State private var searchText = ""
    @State private var didSearch = false
    @State private var noteText = ""
    @State private var showNotePrompt = false
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    init(book: Ebook, onBack: @escaping () -> Void) {
        self.book = book
        self.onBack = onBack
        _model = StateObject(wrappedValue: EbookReaderModel(book: book))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await model.load() }
        .sheet(isPresented: $model.showTOC) { tocSheet }
        .sheet(isPresented: $model.showSearch) { searchSheet }
        .alert(String(localized: "Add note"), isPresented: $showNotePrompt) {
            TextField(String(localized: "Note"), text: $noteText)
            Button(String(localized: "Save")) {
                if let selection = model.selection {
                    addExcerpt(selection, note: noteText)
                }
                noteText = ""
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                noteText = ""
            }
        } message: {
            Text(String(localized: "The note is saved together with the highlight in Excerpts."))
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .padding(.top, 8)
            }
        }
        .onDisappear { model.saveProgress(force: true) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                Label(String(localized: "Library"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(book.authorOrUnknown)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                searchText = model.searchQuery
                didSearch = false
                model.showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Search in book"))
            Button {
                model.toggleBookmark()
            } label: {
                Image(systemName: model.isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isCurrentBookmarked
                             ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            .help(String(localized: "Bookmark this page"))
            Button {
                model.showTOC = true
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Contents"))
            Menu(model.layoutMode == .paged
                 ? String(localized: "Paged")
                 : String(localized: "Scroll")) {
                ForEach(EbookReaderModel.LayoutMode.allCases) { mode in
                    Button {
                        model.applyLayoutMode(mode)
                    } label: {
                        if model.layoutMode == mode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
            }
            .font(.system(size: 10.5))
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(String(localized: "Reading layout"))
            Menu {
                ForEach(EbookReaderModel.Theme.allCases) { theme in
                    Button {
                        model.applyTheme(theme)
                    } label: {
                        if model.theme == theme {
                            Label(theme.displayName, systemImage: "checkmark")
                        } else {
                            Text(theme.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(String(localized: "Reading theme"))
            Button {
                model.applyFontSize(model.fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Smaller text"))
            Button {
                model.applyFontSize(model.fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Larger text"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Back to Library")) { onBack() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading || model.htmlFileURL == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = model.htmlFileURL {
            ZStack {
                EbookWebView(fileURL: url,
                             bookRoot: model.bookRoot,
                             pageTurn: model.pageTurnRequest,
                             onReady: { model.webViewReady($0) },
                             onProgress: { model.updateChapterProgress($0) },
                             onPages: { count, index in
                                 model.updatePages(count: count, index: index)
                             },
                             onSelection: { model.setSelection($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.layoutMode == .paged {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { model.previousPage() }
                                .frame(width: geometry.size.width * 0.18)
                            Spacer(minLength: 0)
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { model.nextPage() }
                                .frame(width: geometry.size.width * 0.18)
                        }
                    }
                }
                if let selection = model.selection {
                    GeometryReader { geometry in
                        selectionToolbar(selection)
                            .position(
                                x: min(max(selection.rect.midX, 230),
                                       max(230, geometry.size.width - 230)),
                                y: max(24, selection.rect.minY - 26))
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                model.previousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGoBack
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(!canGoBack)
            .help(String(localized: "Previous page"))
            Slider(value: Binding(
                get: { displayProgress },
                set: { model.seek(to: $0) }
            ), in: 0...1)
            .controlSize(.small)
            .frame(maxWidth: 460)
            Text(verbatim: progressLabel)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 112, alignment: .trailing)
            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGoForward
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(!canGoForward)
            .help(String(localized: "Next page"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var displayProgress: Double {
        model.layoutMode == .paged
            ? (model.pageCount > 1
               ? Double(model.pageIndex) / Double(model.pageCount - 1) : 0)
            : model.chapterProgress
    }

    private var progressLabel: String {
        if model.layoutMode == .paged {
            return "\(model.pageIndex + 1)/\(model.pageCount) · \(model.currentChapter + 1)/\(model.chapterCount)"
        }
        return "\(Int(model.chapterProgress * 100))% · \(model.currentChapter + 1)/\(model.chapterCount)"
    }

    private var canGoBack: Bool {
        if model.layoutMode == .paged {
            return model.pageIndex > 0 || model.currentChapter > 0
        }
        return model.currentChapter > 0
    }

    private var canGoForward: Bool {
        if model.layoutMode == .paged {
            return model.pageIndex + 1 < model.pageCount
                || model.currentChapter + 1 < model.chapterCount
        }
        return model.currentChapter + 1 < model.chapterCount
    }

    private var tocSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(sheetTab.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { model.showTOC = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            Picker("", selection: $sheetTab) {
                ForEach(SheetTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider()
            if sheetTab == .contents {
                contentsList
            } else {
                bookmarksList
            }
        }
        .frame(width: 460, height: 540)
    }

    @ViewBuilder
    private var contentsList: some View {
        if model.toc.isEmpty {
            Text(String(localized: "No table of contents."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.toc.enumerated()), id: \.offset) { _, item in
                        Button {
                            if let index = item.chapterIndex {
                                model.jump(toChapter: index)
                            }
                            model.showTOC = false
                        } label: {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 11.5,
                                                  weight: (item.chapterIndex ?? -1) == model.currentChapter
                                                  ? .semibold : .regular))
                                    .foregroundStyle((item.chapterIndex ?? -1) == model.currentChapter
                                                     ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(item.level) * 14 + 12)
                            .padding(.trailing, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var bookmarksList: some View {
        if model.bookmarks.isEmpty {
            Text(String(localized: "No bookmarks yet"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(20)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.bookmarks.sorted { $0.createdAt > $1.createdAt }) { bookmark in
                        HStack(spacing: 8) {
                            Button {
                                model.jumpToBookmark(bookmark)
                                model.showTOC = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(bookmark.snippet)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                model.removeBookmark(bookmark.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Remove bookmark"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var searchSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Search in book"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { model.showSearch = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Search in book"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit { runSearch() }
                Button(String(localized: "Search")) { runSearch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if model.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didSearch && model.searchResults.isEmpty {
                Text(String(localized: "No results"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.searchResults) { hit in
                            Button {
                                model.jump(to: hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.chapterTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(appAccent)
                                    Text(hit.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 500, height: 540)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searchFocused = true }
        }
    }

    private func runSearch() {
        didSearch = false
        let query = searchText
        Task {
            await model.search(query)
            didSearch = true
        }
    }

    private func selectionToolbar(_ selection: EbookSelection) -> some View {
        HStack(spacing: 12) {
            Button {
                addExcerpt(selection, note: nil)
            } label: {
                Label(String(localized: "Highlight"), systemImage: "highlighter")
            }
            Button {
                noteText = ""
                showNotePrompt = true
            } label: {
                Label(String(localized: "Note"), systemImage: "note.text")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection.text, forType: .string)
                showToast(String(localized: "Copied"))
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            Button {
                if ReaderSpeechService.shared.isSpeaking {
                    ReaderSpeechService.shared.stop()
                } else {
                    ReaderSpeechService.shared.speak(selection.text)
                }
            } label: {
                Label(String(localized: "Speak"), systemImage: "speaker.wave.2")
            }
            Button {
                AgentDraftInbox.shared.send(
                    String(localized: "About this passage:") + "\n\n" + selection.text)
            } label: {
                Label(String(localized: "Ask Agent"), systemImage: "sparkles")
            }
            Button {
                model.clearSelection()
            } label: {
                Image(systemName: "xmark")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .frame(maxWidth: 560)
    }

    private func addExcerpt(_ selection: EbookSelection, note: String?) {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = ExcerptStore.shared.add(
            kind: .readerHighlight, title: book.title, source: bookRootPath,
            content: selection.text,
            note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote)
        showToast(added ? String(localized: "Saved to Excerpts")
                        : String(localized: "Already in Excerpts"))
        model.clearSelection()
    }

    private var bookRootPath: String {
        EbookImporter.rootDirectory
            .appendingPathComponent(book.containerDirectory, isDirectory: true).path
    }

    private func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if toast == message { toast = nil }
        }
    }
}

/// 从本地文件打开电子书：先导入书库，再进入阅读器。
struct EbookFileReaderView: View {
    let fileURL: URL
    let onBack: () -> Void

    @State private var book: Ebook?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if let book {
                if book.format == .cbz {
                    EbookComicReaderView(book: book, onBack: onBack)
                } else {
                    EbookReaderView(book: book, onBack: onBack)
                }
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Back")) { onBack() }
                        .buttonStyle(.bordered)
                }
                .padding(24)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard loading else { return }
            loading = false
            do {
                book = try await EbookLibraryStore.shared.importBook(at: fileURL)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
