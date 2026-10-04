import AppKit
import SwiftUI

/// 气泡内联的 Mermaid 图：异步经共享渲染服务出 SVG → NSImage，
/// 结果按源码哈希缓存（跨气泡共享）。hover 出"投到白板"。
struct MermaidInlineView: View {
    let code: String
    @Environment(\.appAccent) private var appAccent: Color
    @State private var image: NSImage?
    @State private var failed = false
    @State private var addedToBoard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                group
                    .padding(.top, addedToBoard ? 0 : 18)
                if !addedToBoard {
                    Button {
                        addToBoard()
                    } label: {
                        Label("投到白板", systemImage: "rectangle.dashed")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(appAccent.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if addedToBoard {
                Text("已加入白板 ✓")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: code) {
            do {
                let svg = try await MermaidRenderService.shared.render(code)
                if let data = svg.data(using: .utf8), let img = NSImage(data: data) {
                    MermaidRenderService.shared.storeImage(img, for: code)
                    image = img
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private var group: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 460)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
        } else if failed {
            // 渲染失败兜底：回退普通代码块展示（原文可见不丢信息）
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("渲染 Mermaid…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func addToBoard() {
        let conversationID = AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
        WhiteboardStore.shared.append(
            [WhiteboardBlock(type: WhiteboardBlock.Kind.mermaid, title: "来自消息", content: code)],
            title: nil, conversationID: conversationID)
        WhiteboardPanel.shared.show()
        addedToBoard = true
    }
}
