import PDFKit
import SwiftUI

/// 内建 PDF 查看器（对齐 Safari 的标签页内 PDF 预览）：
/// 主框架导航落 application/pdf 时由 BrowserState.presentPDFViewer 拦下，
/// 下载到临时文件后在这里用 PDFKit 渲染——此前是白页（WKWebView 不渲染
/// PDF，用户只能靠下载+外部打开）。
struct PDFViewerView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var document: PDFDocument?
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
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

                Spacer(minLength: 8)

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
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open in Preview"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }

            if let document {
                PDFKitRepresentedView(document: document, zoom: $zoom)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            document = PDFDocument(url: fileURL)
        }
    }
}

/// PDFKit 包装。缩放**双向**：± 按钮/重置写 scaleFactor；PDFView 自带的
/// 捏合/⌘滚轮缩放经 NotificationCenter（PDFViewScaleChanged）回写 @State——
/// 单向写会在每次 SwiftUI 刷新时覆盖用户手势缩放（旧实现 userInteracted
/// 从未置 true，等于从未生效）。
private struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        context.coordinator.view = view
        context.coordinator.onScale = { [weak view] in
            guard let view else { return }
            zoom = view.scaleFactor
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: .PDFViewScaleChanged,
            object: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        // 只在外部 zoom 值与视图实际值偏差明显时回写（防抖动循环）。
        if abs(view.scaleFactor - zoom) > 0.01 {
            view.scaleFactor = zoom
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: PDFView?
        var onScale: (() -> Void)?
        @objc func scaleChanged() { onScale?() }
    }
}
