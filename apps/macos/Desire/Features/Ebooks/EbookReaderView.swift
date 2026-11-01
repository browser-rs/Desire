import SwiftUI

/// 电子书阅读器（v0.8.34 批次一）：EPUB/TXT 章节阅读、目录、进度、主题。
struct EbookReaderView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let book: Ebook
    let onBack: () -> Void

    @StateObject private var model: EbookReaderModel

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
                             })
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
                Text(String(localized: "Contents"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { model.showTOC = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            Divider()
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
        .frame(width: 440, height: 520)
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
                EbookReaderView(book: book, onBack: onBack)
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
