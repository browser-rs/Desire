import AppKit
import SwiftUI

/// 白板模板社区 sheet（v0.7.24）：拉取 index.json → 列表 → 单板导入
///（信任摘要确认，追加/替换语义与本地 .board 导入同款）。
struct BoardGallerySheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: WhiteboardStore
    let conversationID: String?
    let onClose: () -> Void

    @State private var boards: [BoardGallery.Board] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var statusText: String?
    @State private var importingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(appAccent)
                Text("白板模板社区")
                    .font(.headline)
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("来自 desire.mankong.icu/gallery 的模板。.board 是纯数据文件（图表源码 / Markdown / 图片），不含脚本或宏。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if isLoading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    VStack(spacing: 8) {
                        Label(errorText, systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { load() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(boards) { board in
                                row(board)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task { load() }
    }

    private func row(_ board: BoardGallery.Board) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(board.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(board.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let blocks = board.blocks {
                    Text("\(blocks) 块")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            SettingsCapsuleButton(
                "导入",
                isDisabled: importingID != nil,
                action: { importBoard(board) }
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func load() {
        isLoading = true
        errorText = nil
        Task { @MainActor in
            do {
                boards = try await BoardGalleryService.fetchIndex()
            } catch {
                errorText = "社区不可达：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func importBoard(_ board: BoardGallery.Board) {
        importingID = board.id
        Task { @MainActor in
            defer { importingID = nil }
            do {
                let spec = try await BoardGalleryService.fetchBoard(board)
                guard confirmImport(spec) else { return }
                statusText = "已导入「\(spec.title)」（\(spec.blocks.count) 块）✓"
            } catch {
                statusText = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    /// 信任摘要确认（与本地 .board 导入同款语义）：空板=导入；非空=追加/替换。
    private func confirmImport(_ spec: WhiteboardSpec) -> Bool {
        let current = store.board(for: conversationID)
        let alert = NSAlert()
        alert.messageText = "导入社区模板"
        alert.informativeText = spec.importSummary
            + (current.blocks.isEmpty ? "" : "\n\n当前白板已有 \(current.blocks.count) 块。")
        if current.blocks.isEmpty {
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            store.set(WhiteboardSpec(title: spec.title, blocks: spec.blocks), conversationID: conversationID)
        } else {
            alert.addButton(withTitle: "追加")
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return false }
            if response == .alertSecondButtonReturn {
                store.set(WhiteboardSpec(title: spec.title, blocks: spec.blocks), conversationID: conversationID)
            } else {
                store.append(spec.blocks, title: spec.title, conversationID: conversationID)
            }
        }
        return true
    }
}
