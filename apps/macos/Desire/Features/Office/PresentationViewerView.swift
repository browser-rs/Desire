import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 演示文稿查看器（v0.8.26 办公增强）：PPTX 直开——按幻灯片顺序列出
/// 标题 / 要点 / 备注，可导出 Markdown 或 PDF。解析走 `PresentationReader`
/// （系统 unzip + DrawingML XML），不依赖 Office。
struct PresentationViewerView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var document: PresentationDocument?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var includeNotes = true
    @State private var flashNote: String?
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(loadError)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let flashNote {
                            Text(flashNote)
                                .font(.system(size: 11))
                                .foregroundStyle(appAccent)
                        }
                        ForEach(document.slides, id: \.index) { slide in
                            slideCard(slide)
                        }
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { onBack() } label: {
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
            Spacer(minLength: 8)
            Toggle(String(localized: "Show Notes"), isOn: $includeNotes)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Button(String(localized: "Copy Markdown")) { copyMarkdown() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(document == nil)
            Button(String(localized: "Export Markdown…")) { exportMarkdown() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(document == nil)
            Button(String(localized: "Export PDF…")) { exportPDF() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(document == nil || exporting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func slideCard(_ slide: PresentationSlide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(slide.index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(appAccent)
                    .frame(width: 22, height: 18)
                    .background(Capsule().fill(appAccent.opacity(0.12)))
                Text(slide.title.isEmpty ? String(localized: "Slide \(slide.index)") : slide.title)
                    .font(.system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
            }
            if !slide.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(slide.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.leading, CGFloat(min(max(bullet.level, 0), 6)) * 14)
                            Text(bullet.text)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 30)
            }
            if includeNotes, !slide.notes.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    Text(slide.notes.joined(separator: " / "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let document {
                Text(String(localized: "\(document.slides.count) slides"))
                    .monospacedDigit()
                Text(document.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(fileURL.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func load() {
        let url = fileURL
        Task { @MainActor in
            let result = await Task.detached { PresentationReader.read(url: url) }.value
            isLoading = false
            switch result {
            case .success(let doc):
                document = doc
            case .failure(let error):
                loadError = error.message
            }
        }
    }

    private func markdown() -> String {
        guard let document else { return "" }
        return PresentationReaderCore.markdown(title: document.title, slides: document.slides,
                                               includeNotes: includeNotes)
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(), forType: .string)
        flash(String(localized: "Copied Markdown"))
    }

    private func exportMarkdown() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try markdown().write(to: dest, atomically: true, encoding: .utf8)
            flash(String(localized: "Exported → \(dest.lastPathComponent)"))
        } catch {
            flash(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        _ = document
    }

    private func exportPDF() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        exporting = true
        let html = PresentationReaderCore.html(title: document.title, slides: document.slides,
                                               includeNotes: includeNotes)
        Task { @MainActor in
            let ok = await DocumentConvert.renderHTMLToPDF(html, to: dest)
            exporting = false
            flash(ok ? String(localized: "Exported → \(dest.lastPathComponent)")
                     : String(localized: "PDF export failed"))
        }
    }

    private func flash(_ text: String) {
        flashNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if flashNote == text { flashNote = nil }
        }
    }
}
