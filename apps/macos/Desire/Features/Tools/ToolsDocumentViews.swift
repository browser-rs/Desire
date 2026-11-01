import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// 文档工具视图（v0.8.33 批次一）：PDF 合并/拆分/旋转/导出图片/图片合成 PDF、
// OCR、字幕转换。逻辑在 PDFToolCore / PDFToolEngine / OCRToolEngine /
// SubtitleCore，这里只做界面与文件面板。

// MARK: - 运行状态

@MainActor
final class DocumentToolState: ObservableObject {
    @Published var isWorking = false
    @Published var completed = 0
    @Published var total = 0
    @Published var errorMessage: String?
    @Published var outputs: [URL] = []
    @Published var note: String?

    var progressHandler: PDFToolEngine.ProgressHandler {
        { completed, total in
            Task { @MainActor in
                self.completed = completed
                self.total = total
            }
        }
    }

    func begin() {
        isWorking = true
        completed = 0
        total = 0
        errorMessage = nil
        outputs = []
        note = nil
    }

    func fail(_ error: Error) {
        isWorking = false
        errorMessage = error.localizedDescription
    }
}

// MARK: - 文件面板

@MainActor
private enum DocumentToolUI {
    static func pickPDFs(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func pickImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func pickDocumentOrImage() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .image]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func pickSubtitle() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func savePDF(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func saveText(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func saveSubtitle(name: String, fileExtension ext: String) -> URL? {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - 共用小件

private struct DocumentField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 160
    var mono = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .frame(width: width)
        }
    }
}

private struct DocumentFileList: View {
    @Binding var urls: [URL]

    var body: some View {
        if !urls.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if index > 0 {
                            Button {
                                urls.swapAt(index, index - 1)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(String(localized: "Move up"))
                        }
                        if index < urls.count - 1 {
                            Button {
                                urls.swapAt(index, index + 1)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(String(localized: "Move down"))
                        }
                        Button {
                            urls.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help(String(localized: "Remove"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
        }
    }
}

private struct DocumentProgressView: View {
    let completed: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            if total > 1 {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(width: 180)
                Text(verbatim: "\(completed)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct DocumentResultList: View {
    let urls: [URL]

    @ViewBuilder
    var body: some View {
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Output"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.checkmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button(String(localized: "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DocumentPasswordField: View {
    @Binding var password: String

    var body: some View {
        SecureField(String(localized: "Password (optional)"), text: $password)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5))
            .frame(width: 220)
    }
}

// MARK: - PDF 合并

struct PDFMergeToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var urls: [URL] = []
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Add PDFs…")) {
                    urls.append(contentsOf: DocumentToolUI.pickPDFs(multiple: true))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !urls.isEmpty {
                    Text(verbatim: "\(urls.count) PDF")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if urls.isEmpty {
                Text(String(localized: "Add PDFs in the order you want them merged."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            DocumentFileList(urls: $urls)
            HStack(spacing: 12) {
                DocumentPasswordField(password: $password)
                Text(String(localized: "Used for any encrypted files."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Button(String(localized: "Merge & Save…")) { merge() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(urls.isEmpty || task.isWorking)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DocumentResultList(urls: task.outputs)
        }
    }

    private func merge() {
        guard let destination = DocumentToolUI.savePDF(name: "Merged.pdf") else { return }
        task.begin()
        Task {
            do {
                let pages = try await PDFToolEngine.merge(
                    urls: urls,
                    password: password.isEmpty ? nil : password,
                    to: destination,
                    progress: task.progressHandler)
                task.note = String(localized: "Merged \(pages) pages.")
                task.outputs = [destination]
                RecentLocalFiles.record(url: destination)
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }
}

// MARK: - PDF 拆分

private enum PDFSplitMode: String, CaseIterable, Identifiable {
    case ranges, everyPage
    var id: String { rawValue }
}

struct PDFSplitToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var source: URL?
    @State private var pageCount = 0
    @State private var isLocked = false
    @State private var password = ""
    @State private var mode: PDFSplitMode = .ranges
    @State private var rangeText = "1-"
    @State private var loadingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose PDF…")) { chooseSource() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                DocumentSourceLabel(url: source, pageCount: pageCount,
                                    isLocked: isLocked, loading: loadingInfo)
            }
            Picker("", selection: $mode) {
                Text(String(localized: "Page ranges")).tag(PDFSplitMode.ranges)
                Text(String(localized: "One file per page")).tag(PDFSplitMode.everyPage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            if mode == .ranges {
                HStack(spacing: 8) {
                    DocumentField(title: String(localized: "Pages"), text: $rangeText, width: 180)
                    Text(String(localized: "Example: 1-3,5,8-"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                if let plan = resolvedPlan {
                    Text(verbatim: "\(plan.groups.count) files · \(plan.flat.count) pages")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if isLocked {
                DocumentPasswordField(password: $password)
            }
            Button(String(localized: "Split & Save…")) { split() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(source == nil || task.isWorking || resolvedPlan == nil)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DocumentResultList(urls: task.outputs)
        }
    }

    private var resolvedPlan: PDFToolCore.PagePlan? {
        guard pageCount > 0 else { return nil }
        switch mode {
        case .ranges:
            return PDFToolCore.parsePagePlan(rangeText, pageCount: pageCount)
        case .everyPage:
            return PDFToolCore.PagePlan(groups: (1...pageCount).map { [$0] })
        }
    }

    private func chooseSource() {
        guard let url = DocumentToolUI.pickPDFs(multiple: false).first else { return }
        source = url
        task.outputs = []
        task.errorMessage = nil
        task.note = nil
        pageCount = 0
        isLocked = false
        loadingInfo = true
        Task {
            let info = await PDFToolEngine.info(for: url)
            pageCount = info?.pageCount ?? 0
            isLocked = info?.isLocked ?? false
            if rangeText.isEmpty || rangeText == "1-" {
                rangeText = pageCount > 0 ? "1-\(pageCount)" : "1-"
            }
            loadingInfo = false
        }
    }

    private func split() {
        guard let source, let plan = resolvedPlan else {
            task.errorMessage = PDFToolError.invalidPageRange.localizedDescription
            return
        }
        guard let directory = DocumentToolUI.chooseDirectory() else { return }
        task.begin()
        Task {
            do {
                let outputs = try await PDFToolEngine.split(
                    url: source, plan: plan, to: directory,
                    password: password.isEmpty ? nil : password,
                    progress: task.progressHandler)
                task.outputs = outputs
                task.note = String(localized: "Wrote \(outputs.count) files.")
                RecentLocalFiles.record(url: outputs[0])
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }
}

private struct DocumentSourceLabel: View {
    let url: URL?
    let pageCount: Int
    let isLocked: Bool
    let loading: Bool

    var body: some View {
        if let url {
            HStack(spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if loading {
                    ProgressView().controlSize(.mini)
                } else if pageCount > 0 {
                    Text(verbatim: "· \(pageCount)p")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - PDF 旋转

struct PDFRotateToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var source: URL?
    @State private var pageCount = 0
    @State private var isLocked = false
    @State private var password = ""
    @State private var rangeText = ""
    @State private var turns = 1
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose PDF…")) { chooseSource() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                DocumentSourceLabel(url: source, pageCount: pageCount,
                                    isLocked: isLocked, loading: false)
            }
            HStack(spacing: 12) {
                DocumentField(title: String(localized: "Pages"), text: $rangeText, width: 150)
                Text(String(localized: "Blank means all pages."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Picker("", selection: $turns) {
                Text(verbatim: "90°").tag(1)
                Text(verbatim: "180°").tag(2)
                Text(verbatim: "270°").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            if isLocked {
                DocumentPasswordField(password: $password)
            }
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
            }
            Button(String(localized: "Rotate & Save…")) { rotate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(source == nil || task.isWorking)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DocumentResultList(urls: task.outputs)
        }
        .onChange(of: turns) { _, _ in updatePreview() }
        .onChange(of: password) { _, _ in updatePreview() }
    }

    private var resolvedPages: [Int]? {
        let trimmed = rangeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, pageCount > 0 else { return nil }
        return PDFToolCore.parsePageNumbers(trimmed, pageCount: pageCount)
    }

    private func chooseSource() {
        guard let url = DocumentToolUI.pickPDFs(multiple: false).first else { return }
        source = url
        task.outputs = []
        task.errorMessage = nil
        task.note = nil
        rangeText = ""
        pageCount = 0
        isLocked = false
        Task {
            let info = await PDFToolEngine.info(for: url)
            pageCount = info?.pageCount ?? 0
            isLocked = info?.isLocked ?? false
            updatePreview()
        }
    }

    private func updatePreview() {
        guard let source, let document = PDFDocument(url: source) else {
            preview = nil
            return
        }
        if document.isLocked {
            guard !password.isEmpty, document.unlock(withPassword: password) else {
                preview = nil
                return
            }
        }
        guard let page = document.page(at: 0) else {
            preview = nil
            return
        }
        let copy = (page.copy() as? PDFPage) ?? page
        copy.rotation = ((copy.rotation + turns * 90) % 360 + 360) % 360
        preview = copy.thumbnail(of: NSSize(width: 360, height: 480), for: .cropBox)
    }

    private func rotate() {
        guard let source else { return }
        if !rangeText.trimmingCharacters(in: .whitespaces).isEmpty, resolvedPages == nil {
            task.errorMessage = PDFToolError.invalidPageRange.localizedDescription
            return
        }
        let name = (source.lastPathComponent as NSString).deletingPathExtension + "-rotated.pdf"
        guard let destination = DocumentToolUI.savePDF(name: name) else { return }
        task.begin()
        Task {
            do {
                try await PDFToolEngine.rotate(
                    url: source, pages: resolvedPages, quarterTurns: turns,
                    to: destination, password: password.isEmpty ? nil : password)
                task.outputs = [destination]
                task.note = String(localized: "Rotation applied.")
                RecentLocalFiles.record(url: destination)
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }
}

// MARK: - PDF → 图片

struct PDFToImagesToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var source: URL?
    @State private var pageCount = 0
    @State private var isLocked = false
    @State private var password = ""
    @State private var rangeText = ""
    @State private var dpi = 144
    @State private var format: PDFToolEngine.ImageFormat = .png

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose PDF…")) { chooseSource() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                DocumentSourceLabel(url: source, pageCount: pageCount,
                                    isLocked: isLocked, loading: false)
            }
            HStack(spacing: 12) {
                DocumentField(title: String(localized: "Pages"), text: $rangeText, width: 150)
                Text(String(localized: "Blank means all pages."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 16) {
                Picker("", selection: $dpi) {
                    Text(verbatim: "72 DPI").tag(72)
                    Text(verbatim: "144 DPI").tag(144)
                    Text(verbatim: "300 DPI").tag(300)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Picker("", selection: $format) {
                    ForEach(PDFToolEngine.ImageFormat.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            if isLocked {
                DocumentPasswordField(password: $password)
            }
            Button(String(localized: "Export Images…")) { export() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(source == nil || task.isWorking)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DocumentResultList(urls: task.outputs)
        }
    }

    private var resolvedPages: [Int]? {
        let trimmed = rangeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, pageCount > 0 else { return nil }
        return PDFToolCore.parsePageNumbers(trimmed, pageCount: pageCount)
    }

    private func chooseSource() {
        guard let url = DocumentToolUI.pickPDFs(multiple: false).first else { return }
        source = url
        task.outputs = []
        task.errorMessage = nil
        task.note = nil
        rangeText = ""
        pageCount = 0
        isLocked = false
        Task {
            let info = await PDFToolEngine.info(for: url)
            pageCount = info?.pageCount ?? 0
            isLocked = info?.isLocked ?? false
        }
    }

    private func export() {
        guard let source else { return }
        if !rangeText.trimmingCharacters(in: .whitespaces).isEmpty, resolvedPages == nil {
            task.errorMessage = PDFToolError.invalidPageRange.localizedDescription
            return
        }
        guard let directory = DocumentToolUI.chooseDirectory() else { return }
        task.begin()
        Task {
            do {
                let outputs = try await PDFToolEngine.renderImages(
                    url: source, pages: resolvedPages, dpi: Double(dpi),
                    format: format, to: directory,
                    password: password.isEmpty ? nil : password,
                    progress: task.progressHandler)
                task.outputs = outputs
                task.note = String(localized: "Exported \(outputs.count) images.")
                RecentLocalFiles.record(url: outputs[0])
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }
}

// MARK: - 图片 → PDF

struct ImagesToPDFToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var urls: [URL] = []
    @State private var layout: PDFToolEngine.PageLayout = .a4
    @State private var margin = "24"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Add Images…")) {
                    urls.append(contentsOf: DocumentToolUI.pickImages())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !urls.isEmpty {
                    Text(verbatim: "\(urls.count) images")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if urls.isEmpty {
                Text(String(localized: "Add images in the order you want them in the PDF."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            DocumentFileList(urls: $urls)
            HStack(spacing: 16) {
                Picker("", selection: $layout) {
                    Text(String(localized: "A4 page")).tag(PDFToolEngine.PageLayout.a4)
                    Text(String(localized: "Original size")).tag(PDFToolEngine.PageLayout.original)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                DocumentField(title: String(localized: "Page margin"), text: $margin, width: 60)
                Text(verbatim: "pt")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Button(String(localized: "Create PDF…")) { create() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(urls.isEmpty || task.isWorking)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            DocumentResultList(urls: task.outputs)
        }
    }

    private func create() {
        guard let destination = DocumentToolUI.savePDF(name: "Images.pdf") else { return }
        let marginValue = Double(margin) ?? 24
        task.begin()
        Task {
            do {
                let pages = try await PDFToolEngine.imagesToPDF(
                    urls: urls, layout: layout, margin: marginValue,
                    to: destination, progress: task.progressHandler)
                task.outputs = [destination]
                task.note = String(localized: "Created a \(pages)-page PDF.")
                RecentLocalFiles.record(url: destination)
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }
}

// MARK: - OCR

struct ImageOCRToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var source: URL?
    @State private var isPDF = false
    @State private var isLocked = false
    @State private var pageCount = 0
    @State private var password = ""
    @State private var rangeText = ""
    @State private var dpi = 200
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Image or PDF…")) { chooseSource() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "From Clipboard")) { recognizeClipboard() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let source {
                    Text(source.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if isPDF {
                HStack(spacing: 12) {
                    DocumentField(title: String(localized: "Pages"), text: $rangeText, width: 150)
                    Text(String(localized: "Blank means all pages."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    Picker("", selection: $dpi) {
                        Text(verbatim: "150 DPI").tag(150)
                        Text(verbatim: "200 DPI").tag(200)
                        Text(verbatim: "300 DPI").tag(300)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    if isLocked {
                        DocumentPasswordField(password: $password)
                    }
                }
            }
            Button(String(localized: "Recognize Text")) { recognizeFile() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled((source == nil && text.isEmpty) || task.isWorking)
            if task.isWorking {
                DocumentProgressView(completed: task.completed, total: task.total)
            }
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ToolOutput(text: text,
                       title: String(localized: "Recognized text"),
                       minHeight: 160,
                       monospaced: false)
            HStack(spacing: 8) {
                Button(String(localized: "Save as Text…")) { saveText() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(text.isEmpty)
                Button(String(localized: "Clear")) {
                    text = ""
                    task.outputs = []
                    task.note = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(text.isEmpty || task.isWorking)
            }
        }
    }

    private func chooseSource() {
        guard let url = DocumentToolUI.pickDocumentOrImage() else { return }
        source = url
        isPDF = url.pathExtension.lowercased() == "pdf"
        isLocked = false
        pageCount = 0
        text = ""
        task.outputs = []
        task.errorMessage = nil
        task.note = nil
        rangeText = isPDF ? "1-" : ""
        if isPDF {
            let url = url
            Task {
                let info = await PDFToolEngine.info(for: url)
                pageCount = info?.pageCount ?? 0
                isLocked = info?.isLocked ?? false
            }
        }
    }

    private func recognizeFile() {
        guard let source else { return }
        var pages: [Int]? = nil
        if isPDF, !rangeText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard pageCount > 0 else {
                task.errorMessage = PDFToolError.cannotOpen(source.lastPathComponent)
                    .localizedDescription
                return
            }
            pages = PDFToolCore.parsePageNumbers(rangeText, pageCount: pageCount)
            if pages == nil {
                task.errorMessage = PDFToolError.invalidPageRange.localizedDescription
                return
            }
        }
        task.begin()
        Task {
            do {
                let result = try await OCRToolEngine.recognize(
                    url: source, pages: pages,
                    password: password.isEmpty ? nil : password,
                    dpi: Double(dpi), progress: task.progressHandler)
                text = result.text
                task.note = result.text.isEmpty
                    ? String(localized: "No text found.")
                    : String(localized: "Recognized \(result.pages.count) pages.")
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }

    private func recognizeClipboard() {
        guard let data = NSPasteboard.general.data(forType: .tiff),
              let image = NSImage(data: data) else {
            task.errorMessage = String(localized: "No image in the clipboard.")
            return
        }
        task.begin()
        Task {
            do {
                let result = try await VisionOCRService.recognize(image: image)
                text = result.text
                task.note = String(localized: "Recognized the clipboard image.")
            } catch let error as VisionOCRService.OCRError {
                if case .noText = error {
                    text = ""
                    task.note = String(localized: "No text found.")
                } else {
                    task.fail(error)
                }
            } catch {
                task.fail(error)
            }
            task.isWorking = false
        }
    }

    private func saveText() {
        guard let destination = DocumentToolUI.saveText(name: "OCR.txt") else { return }
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
            task.outputs = [destination]
            RecentLocalFiles.record(url: destination)
        } catch {
            task.fail(error)
        }
    }
}

// MARK: - 字幕转换

struct SubtitleToolView: View {
    @StateObject private var task = DocumentToolState()
    @State private var source: URL?
    @State private var sourceFormat: SubtitleCore.Format?
    @State private var cues: [SubtitleCore.Cue] = []
    @State private var targetFormat: SubtitleCore.Format = .srt
    @State private var offsetText = "0"
    @State private var mergeBilingual = false
    @State private var secondary: URL?
    @State private var secondaryCues: [SubtitleCore.Cue] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Subtitle…")) { choosePrimary() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let source {
                    Text(verbatim: "\(source.lastPathComponent) · \(cues.count) cues")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 16) {
                Picker("", selection: $targetFormat) {
                    ForEach(SubtitleCore.Format.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                DocumentField(title: String(localized: "Offset"), text: $offsetText, width: 70)
                Text(verbatim: "ms")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                ToolToggle(title: String(localized: "Merge a second subtitle"),
                           isOn: $mergeBilingual)
                if mergeBilingual {
                    Button(secondary?.lastPathComponent ?? String(localized: "Choose Second Subtitle…")) {
                        chooseSecondary()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            Button(String(localized: "Convert & Save…")) { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cues.isEmpty || task.isWorking)
            if let error = task.errorMessage {
                ToolErrorText(text: error)
            }
            if let note = task.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !cues.isEmpty {
                ToolOutput(text: previewText,
                           title: String(localized: "Preview"),
                           minHeight: 120)
            }
            DocumentResultList(urls: task.outputs)
        }
    }

    private var offsetSeconds: Double {
        (Double(offsetText) ?? 0) / 1000
    }

    private var shiftedCues: [SubtitleCore.Cue] {
        offsetSeconds == 0 ? cues : SubtitleCore.shift(cues, by: offsetSeconds)
    }

    private var outputCues: [SubtitleCore.Cue] {
        let shifted = shiftedCues
        guard mergeBilingual, !secondaryCues.isEmpty else { return shifted }
        let second = offsetSeconds == 0
            ? secondaryCues
            : SubtitleCore.shift(secondaryCues, by: offsetSeconds)
        return SubtitleCore.mergeBilingual(primary: shifted, secondary: second)
    }

    private var previewText: String {
        let sample = Array(outputCues.prefix(8))
        return SubtitleCore.encode(sample, as: targetFormat)
    }

    private func choosePrimary() {
        guard let url = DocumentToolUI.pickSubtitle() else { return }
        load(url: url, isSecondary: false)
    }

    private func chooseSecondary() {
        guard let url = DocumentToolUI.pickSubtitle() else { return }
        load(url: url, isSecondary: true)
    }

    private func load(url: URL, isSecondary: Bool) {
        task.errorMessage = nil
        task.note = nil
        task.outputs = []
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = SubtitleCore.parse(data), !parsed.isEmpty else {
                throw SubtitleToolError.unrecognized
            }
            if isSecondary {
                secondary = url
                secondaryCues = parsed
            } else {
                source = url
                sourceFormat = SubtitleCore.detectFormat(data)
                cues = parsed
                targetFormat = sourceFormat ?? .srt
                task.note = String(localized: "Loaded \(parsed.count) cues.")
            }
        } catch {
            task.fail(error)
        }
    }

    private func save() {
        guard !cues.isEmpty else { return }
        let trimmedOffset = offsetText.trimmingCharacters(in: .whitespaces)
        if !trimmedOffset.isEmpty && Double(trimmedOffset) == nil {
            task.errorMessage = String(localized: "Offset must be a number of milliseconds.")
            return
        }
        let stem = source.map { ($0.lastPathComponent as NSString).deletingPathExtension }
            ?? "subtitle"
        guard let destination = DocumentToolUI.saveSubtitle(
            name: "\(stem).\(targetFormat.fileExtension)",
            fileExtension: targetFormat.fileExtension) else { return }
        let output = SubtitleCore.encode(outputCues, as: targetFormat)
        do {
            try output.write(to: destination, atomically: true, encoding: .utf8)
            task.outputs = [destination]
            task.note = String(localized: "Saved \(outputCues.count) cues.")
            RecentLocalFiles.record(url: destination)
        } catch {
            task.fail(error)
        }
    }
}

nonisolated enum SubtitleToolError: LocalizedError {
    case unrecognized
    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return String(localized: "Could not recognize this subtitle file.")
        }
    }
}
