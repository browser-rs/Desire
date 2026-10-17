import Quartz
import SwiftUI

/// 下载文件的**行内预览**（v0.7.19）：QuickLook 内嵌视图——图片/视频/音频/
/// PDF/文本统一渲染，完成下载的文件在面板里直接看，不用跳 Finder。
/// 系统组件零自研（QLPreviewView），格式覆盖面跟着 QuickLook 走。
struct DownloadPreviewSheet: View {
    let fileURL: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            QuickLookPreview(url: fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 800, minHeight: 460, idealHeight: 560)
    }
}

/// QLPreviewView 的 SwiftUI 封装（macOS 26：Quartz 框架的非弃用路径）。
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}
