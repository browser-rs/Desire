import SwiftUI

/// 白板快照卡（/panel/snapshot?name=whiteboard 离屏渲染用）：
/// 块清单概览（真实成图在面板的 webview 里——离屏 NSHostingView 不驱动
/// webview，这里呈现每块的类型/标题/内容摘要）。
struct WhiteboardSnapshotView: View {
    let board: WhiteboardSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(board.title)
                .font(.system(size: 15, weight: .bold))
            if board.blocks.isEmpty {
                Text("白板是空的——让智能体画点什么。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(board.blocks.enumerated()), id: \.offset) { idx, block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(block.type.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        if let title = block.title {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    Text(block.content)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(6)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
