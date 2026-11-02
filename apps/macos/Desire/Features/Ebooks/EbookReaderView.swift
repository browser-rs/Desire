import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import UniformTypeIdentifiers
import _Translation_SwiftUI

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
    @ObservedObject private var speech = ReaderSpeechService.shared
    @State private var sheetTab: SheetTab = .contents
    @State private var searchText = ""
    @State private var didSearch = false
    @State private var noteText = ""
    @State private var showNotePrompt = false
    @State private var toast: String?
    @State private var translationText = ""
    @State private var translatedText: String?
    @State private var translationError: String?
    @State private var isTranslating = false
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationJob: TranslationJob?
    @State private var isTranslatingChapter = false
    @State private var chapterTranslationProgress: Double = 0
    @AppStorage("ebook.translation.target") private var translationTargetCode = "system"
    @FocusState private var searchFocused: Bool

    private enum TranslationJob {
        case selection(String)
        case chapter(blocks: [EbookTranslationBlock], targetKey: String)
    }

    private struct TranslationTargetOption: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private var translationTargets: [TranslationTargetOption] {
        [
            .init(code: "system", name: String(localized: "System Language")),
            .init(code: "en", name: "English"),
            .init(code: "zh-Hans", name: "简体中文"),
            .init(code: "zh-Hant", name: "繁體中文"),
            .init(code: "ja", name: "日本語"),
            .init(code: "ko", name: "한국어"),
            .init(code: "fr", name: "Français"),
            .init(code: "de", name: "Deutsch"),
            .init(code: "es", name: "Español"),
        ]
    }

    init(book: Ebook, initialChapter: Int? = nil, initialQuery: String? = nil,
         onBack: @escaping () -> Void) {
        self.book = book
        self.onBack = onBack
        let reader = EbookReaderModel(book: book)
        reader.initialChapter = initialChapter
        reader.initialSearchQuery = initialQuery
        _model = StateObject(wrappedValue: reader)
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
        .background {
            VStack {
                Button("") { model.previousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.nextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { model.nextPage() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { openSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { model.applyFontSize(model.fontSize + 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { model.applyFontSize(model.fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") { closeOverlays() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .task { await model.load() }
        .translationTask(translationConfig) { session in
            guard let job = translationJob else { return }
            switch job {
            case .selection(let text):
                guard !text.isEmpty else { return }
                do {
                    let response = try await session.translate(text)
                    await MainActor.run {
                        translatedText = response.targetText
                        isTranslating = false
                        translationJob = nil
                    }
                } catch {
                    await MainActor.run {
                        translationError = error.localizedDescription
                        isTranslating = false
                        translationJob = nil
                    }
                }
            case .chapter(let blocks, let targetKey):
                do {
                    var result: [Int: String] = [:]
                    let chunkSize = 8
                    var cursor = 0
                    while cursor < blocks.count {
                        let chunk = Array(blocks[cursor..<min(cursor + chunkSize, blocks.count)])
                        let requests = chunk.map {
                            TranslationSession.Request(
                                sourceText: $0.text,
                                clientIdentifier: String($0.id))
                        }
                        let responses = try await session.translations(from: requests)
                        for response in responses {
                            if let id = response.clientIdentifier.flatMap(Int.init) {
                                result[id] = response.targetText
                            }
                        }
                        cursor += chunkSize
                        let done = Double(min(cursor, blocks.count)) / Double(blocks.count)
                        await MainActor.run { chapterTranslationProgress = done }
                    }
                    await MainActor.run {
                        model.applyTranslation(result, language: targetKey)
                        isTranslatingChapter = false
                        chapterTranslationProgress = 1
                        translationJob = nil
                    }
                } catch {
                    await MainActor.run {
                        isTranslatingChapter = false
                        translationJob = nil
                        showToast(error.localizedDescription)
                    }
                }
            }
        }
        .sheet(isPresented: $model.showTOC) { tocSheet }
        .sheet(isPresented: $model.showSearch) { searchSheet }
        .sheet(isPresented: $model.showNotes) {
            EbookNotesPanel(
                book: book,
                highlights: model.highlights,
                focusedID: model.focusedHighlightID,
                onJump: { model.jumpToHighlight($0) },
                onColor: { model.setHighlightColor($0, $1) },
                onNote: { model.setHighlightNote($0, note: $1) },
                onDelete: { model.removeHighlight($0) },
                onExportBook: { exportNotes(all: false) },
                onExportAll: { exportNotes(all: true) },
                onCopy: { copyNotes() },
                onClose: { model.showNotes = false })
        }
        .alert(String(localized: "Add note"), isPresented: $showNotePrompt) {
            TextField(String(localized: "Note"), text: $noteText)
            Button(String(localized: "Save")) {
                if let selection = model.selection {
                    addHighlight(selection, note: noteText)
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
        .overlay(alignment: .top) {
            if isTranslating || translatedText != nil || translationError != nil {
                translationCard
                    .padding(.top, 44)
            }
        }
        .onAppear { model.startReadingSession() }
        .onDisappear {
            stopReadingAloud()
            model.endReadingSession()
            model.saveProgress(force: true)
            EbookReaderSession.shared.clear(bookID: book.id)
        }
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
                model.showNotes = true
            } label: {
                Image(systemName: "highlighter")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Notes & Highlights"))
            Button { summarizeChapter() } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Summarize Chapter"))
            if isTranslatingChapter {
                ProgressView(value: chapterTranslationProgress)
                    .controlSize(.small)
                    .frame(width: 42)
            }
            Menu {
                if model.hasTranslation {
                    Button(String(localized: "Hide Translation")) {
                        model.clearTranslation()
                    }
                }
                Button(String(localized: "Translate Chapter")) { translateChapter() }
                    .disabled(isTranslatingChapter)
                Menu(String(localized: "Target Language")) {
                    ForEach(translationTargets) { option in
                        Button {
                            translationTargetCode = option.code
                            if model.hasTranslation { model.clearTranslation() }
                            translateChapter()
                        } label: {
                            if translationTargetCode == option.code {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(model.hasTranslation
                             ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            .help(String(localized: "Translate chapter"))
            Menu {
                if speech.isSpeaking {
                    Button(speech.isPaused
                           ? String(localized: "Resume Reading")
                           : String(localized: "Pause Reading")) {
                        speech.togglePause()
                    }
                    Button(String(localized: "Stop Reading")) { stopReadingAloud() }
                } else {
                    Button(String(localized: "Read Chapter Aloud")) { startReadingAloud() }
                }
            } label: {
                Image(systemName: speech.isSpeaking
                      ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(speech.isSpeaking
                             ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            .help(String(localized: "Read aloud"))
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
                             onSelection: { model.setSelection($0) },
                             onHighlight: { model.openHighlight($0) })
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

    // MARK: - 划词翻译

    private func translateSelection(_ selection: EbookSelection) {
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.clearSelection()
        translationText = text
        translatedText = nil
        translationError = nil
        isTranslating = true
        translationJob = .selection(text)
        let source = detectLanguage(text)
        let system = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        let target: Locale.Language
        if let source, source.languageCode == system.languageCode {
            target = Locale.Language(identifier: "en")
        } else {
            target = system
        }
        var config = TranslationSession.Configuration(source: source, target: target)
        config.invalidate()
        translationConfig = config
    }

    private func detectLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let identifier = recognizer.dominantLanguage?.rawValue else { return nil }
        return Locale.Language(identifier: identifier)
    }

    private func translateChapter() {
        guard !isTranslatingChapter else { return }
        Task { @MainActor in
            let blocks = await model.translationBlocks()
            guard !blocks.isEmpty else {
                showToast(String(localized: "Nothing to translate"))
                return
            }
            let sample = blocks.prefix(3).map { $0.text }.joined(separator: " ")
            let source = detectLanguage(sample)
            let spec = targetSpec(code: translationTargetCode, source: source)
            if let cached = model.cachedTranslation(language: spec.cacheKey) {
                model.applyTranslation(cached, language: spec.cacheKey)
                showToast(String(localized: "Translation restored"))
                return
            }
            isTranslatingChapter = true
            chapterTranslationProgress = 0
            translationJob = .chapter(blocks: blocks, targetKey: spec.cacheKey)
            var config = TranslationSession.Configuration(source: source,
                                                          target: spec.language)
            config.invalidate()
            translationConfig = config
        }
    }

    private func targetSpec(code: String,
                            source: Locale.Language?) -> (language: Locale.Language,
                                                          cacheKey: String) {
        if code == "system" {
            let raw = Locale.preferredLanguages.first ?? "en"
            var language = Locale.Language(identifier: raw)
            if let source, source.languageCode == language.languageCode {
                language = Locale.Language(identifier: "en")
                return (language, "en")
            }
            return (language, raw)
        }
        return (Locale.Language(identifier: code), code)
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Translation"))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button {
                    closeTranslation()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(translationText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Divider()
            if isTranslating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Translating…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let translationError {
                Text(translationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let translatedText {
                ScrollView {
                    Text(translatedText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            if translatedText != nil {
                HStack(spacing: 8) {
                    Button(String(localized: "Copy")) { copyTranslation() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(String(localized: "Save to Excerpts")) {
                        saveTranslationToExcerpts()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func copyTranslation() {
        guard let translatedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        showToast(String(localized: "Copied"))
    }

    private func saveTranslationToExcerpts() {
        guard let translatedText else { return }
        let added = ExcerptStore.shared.add(
            kind: .readerHighlight, title: book.title, source: model.bookRoot.path,
            content: translationText, note: translatedText)
        showToast(added ? String(localized: "Saved to Excerpts")
                        : String(localized: "Already in Excerpts"))
    }

    private func closeTranslation() {
        translationConfig = nil
        translationJob = nil
        translationText = ""
        translatedText = nil
        translationError = nil
        isTranslating = false
    }

    private func selectionToolbar(_ selection: EbookSelection) -> some View {
        HStack(spacing: 12) {
            Button {
                addHighlight(selection, note: nil)
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
                speech.onFinish = nil
                speech.onSpeakRange = nil
                if speech.isSpeaking {
                    speech.stop()
                } else {
                    speech.speak(selection.text)
                }
            } label: {
                Label(String(localized: "Speak"), systemImage: "speaker.wave.2")
            }
            Button {
                translateSelection(selection)
            } label: {
                Label(String(localized: "Translate"), systemImage: "character.bubble")
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
        .frame(maxWidth: 660)
    }

    private func startReadingAloud() {
        let text = model.chapterPlainText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(String(localized: "Nothing to read"))
            return
        }
        speech.onFinish = {
            if model.speechAdvanceChapter() {
                startReadingAloud()
            }
        }
        speech.onSpeakRange = { location, _, total in
            model.speechProgress(location: location, total: total)
        }
        speech.speak(text)
    }

    private func stopReadingAloud() {
        speech.onFinish = nil
        speech.onSpeakRange = nil
        speech.stop()
    }

    private func summarizeChapter() {
        let text = model.chapterPlainText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(String(localized: "Nothing to read"))
            return
        }
        let excerpt = String(text.prefix(12_000))
        let prompt = """
        Summarize chapter \(model.currentChapter + 1) ("\(model.chapterTitle)") of "\(book.title)" in 5 bullet points, then quote 3 key passages. After that, call addBookNote with the summary text so it is saved to Excerpts.

        <chapter>
        \(excerpt)
        </chapter>
        """
        AgentDraftInbox.shared.send(prompt)
    }

    private func openSearch() {
        searchText = model.searchQuery
        didSearch = false
        model.showSearch = true
    }

    private func closeOverlays() {
        if model.showNotes { model.showNotes = false; return }
        if model.showSearch { model.showSearch = false; return }
        if model.showTOC { model.showTOC = false; return }
        if translatedText != nil || isTranslating || translationError != nil {
            closeTranslation()
            return
        }
        model.clearSelection()
    }

    private func addHighlight(_ selection: EbookSelection, note: String?) {
        guard let created = model.addHighlight(from: selection, note: note) else { return }
        if created.isNew {
            showToast(created.excerptAdded
                      ? String(localized: "Saved to Excerpts")
                      : String(localized: "Highlight saved"))
        } else if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            showToast(String(localized: "Note saved"))
        } else {
            showToast(String(localized: "Already highlighted"))
        }
        model.clearSelection()
    }

    /// 导出/复制用的 Markdown：全部导出时当前书取内存值，其余书读盘。
    private func notesMarkdown(all: Bool) -> String? {
        if all {
            let entries = EbookLibraryStore.shared.books.compactMap {
                item -> (title: String, author: String, highlights: [EbookHighlight])? in
                let items = item.id == book.id ? model.highlights
                    : EbookHighlightStore.load(item.id)
                guard !items.isEmpty else { return nil }
                return (item.title, item.author, items)
            }
            guard !entries.isEmpty else { return nil }
            return EbookNotesExportCore.markdown(books: entries)
        }
        guard !model.highlights.isEmpty else { return nil }
        return EbookNotesExportCore.markdown(
            title: book.title, author: book.author, highlights: model.highlights)
    }

    private func exportNotes(all: Bool) {
        guard let markdown = notesMarkdown(all: all) else {
            showToast(String(localized: "No highlights to export"))
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = EbookNotesExportCore.filename(
            for: all ? String(localized: "All books") : book.title)
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            showToast(String(localized: "Exported"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func copyNotes() {
        guard let markdown = notesMarkdown(all: false) else {
            showToast(String(localized: "No highlights to export"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        showToast(String(localized: "Copied"))
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
