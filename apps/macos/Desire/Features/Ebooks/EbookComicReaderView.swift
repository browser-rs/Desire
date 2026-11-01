import AppKit
import SwiftUI

/// CBZ 漫画阅读器（v0.8.34 批次四）：解包后的图片按文件名排序翻页。
struct EbookComicReaderView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let book: Ebook
    let onBack: () -> Void

    @State private var images: [URL] = []
    @State private var pageIndex = 0
    @State private var image: NSImage?
    @State private var loading = true
    @State private var error: String?

    private var pageCount: Int { max(1, images.count) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(pageIndex)
                        .transition(.opacity)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { previousPage() }
                            .frame(width: geometry.size.width / 3)
                        Spacer(minLength: 0)
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { nextPage() }
                            .frame(width: geometry.size.width / 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .background(Color.black)
        .task { load() }
        .onDisappear { saveProgress() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                Label(String(localized: "Library"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(book.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(verbatim: "\(pageIndex + 1)/\(pageCount)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { previousPage() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(pageIndex == 0)
            Slider(value: Binding(
                get: { pageCount > 1 ? Double(pageIndex) / Double(pageCount - 1) : 0 },
                set: { value in
                    let target = Int((value * Double(pageCount - 1)).rounded())
                    go(to: target)
                }
            ), in: 0...1)
            .controlSize(.small)
            .frame(maxWidth: 460)
            Button { nextPage() } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(pageIndex + 1 >= pageCount)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func load() {
        loading = true
        let directory = EbookImporter.rootDirectory
            .appendingPathComponent(book.containerDirectory, isDirectory: true)
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                EbookImporter.comicImageURLs(bookDirectory: directory)
            }.value
            images = urls
            pageIndex = min(max(book.lastChapterIndex, 0), max(0, urls.count - 1))
            loading = false
            if urls.isEmpty {
                error = String(localized: "This comic archive has no readable images.")
            }
            showCurrentImage()
        }
    }

    private func showCurrentImage() {
        guard images.indices.contains(pageIndex) else {
            image = nil
            return
        }
        image = NSImage(contentsOf: images[pageIndex])
    }

    private func nextPage() {
        guard pageIndex + 1 < pageCount else { return }
        go(to: pageIndex + 1)
    }

    private func previousPage() {
        guard pageIndex > 0 else { return }
        go(to: pageIndex - 1)
    }

    private func go(to target: Int) {
        let clamped = min(max(target, 0), pageCount - 1)
        guard clamped != pageIndex else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            pageIndex = clamped
        }
        showCurrentImage()
        saveProgress()
    }

    private func saveProgress() {
        let overall = pageCount > 1
            ? Double(pageIndex) / Double(pageCount - 1) : 0
        EbookLibraryStore.shared.updateProgress(
            book.id, chapterIndex: pageIndex, chapterProgress: overall, overall: overall)
    }
}
