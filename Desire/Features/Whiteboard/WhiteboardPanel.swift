import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 白板窗口（一期）：承载**当前活跃 AI 会话**的白板（按 conversationId 取板）。
/// 单例（AgentScheduler.deliveryTarget 决定显示哪个会话的板；无活跃会话时
/// 沿用最后一次持有的）。入口 = Agent 面板头部按钮 / CommandBus
/// `.toggleWhiteboard` / 桥 `POST /command toggleWhiteboard`。
@MainActor
final class WhiteboardPanel {
    static let shared = WhiteboardPanel()

    private var window: NSWindow?
    /// 最后持有的会话（deliveryTarget 是 weak——会话空闲时兜底）。
    private var lastSession: AgentSessionStore?

    private var currentSession: AgentSessionStore? {
        if let target = AgentScheduler.shared.deliveryTarget {
            lastSession = target
        }
        return lastSession
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let session = currentSession ?? {
            let fallback = AgentSessionStore(
                preference: AppState.live?.aiPreference ?? AgentPreferenceStore(),
                conversationStore: AppState.live?.conversationStore ?? ConversationStore())
            lastSession = fallback
            return fallback
        }() else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "白板"
        window.minSize = NSSize(width: 480, height: 360)
        let hostingController = NSHostingController(
            rootView: WhiteboardPanelView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 独立窗口：ContentView 的强调色注入不跨窗口（见 AppAccent.swift）。
                .appAccent(Color(nsColor: .controlAccentColor))
        )
        window.contentViewController = hostingController
        window.setFrameAutosaveName("WhiteboardPanel")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
    }

    func cleanup() {
        window?.close()
        window = nil
    }
}

/// 白板窗口内容：当前会话的板 + 工具条（刷新 / 导出 PNG / 清空）。
struct WhiteboardPanelView: View {
    @ObservedObject var session: AgentSessionStore
    @ObservedObject private var store = WhiteboardStore.shared
    @Environment(\.appAccent) private var appAccent: Color
    @State private var exportStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.6)
            WhiteboardWebView(spec: store.board(for: session.conversationId?.uuidString))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(store.board(for: session.conversationId?.uuidString).title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let exportStatus {
                Text(exportStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            CapsuleButton(systemName: "square.and.arrow.down", action: { exportPNG() })
                .help("导出 PNG 到下载目录")
            Menu {
                Button("便签") { addBlock(WhiteboardBlock.Kind.note, "## 新便签\n- ") }
                Button("Mermaid 导图/流程图") { addBlock(WhiteboardBlock.Kind.mermaid, "graph TD\n    A[节点] --> B[节点]") }
                Button("图表（ECharts）") { addBlock(WhiteboardBlock.Kind.chart, "{\"xAxis\":{\"data\":[\"A\",\"B\"]},\"yAxis\":{},\"series\":[{\"type\":\"bar\",\"data\":[1,2]}]}") }
                Button("表格") { addBlock(WhiteboardBlock.Kind.table, "| 列一 | 列二 |\n| --- | --- |\n| a | b |") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("手动添加块（进入源码编辑）")
            CapsuleButton(systemName: "square.and.arrow.up.on.square", action: { exportBoardFile() })
                .help("导出 .board（JSON）")
            CapsuleButton(systemName: "square.and.arrow.down.on.square", action: { importBoardFile() })
                .help("导入 .board（追加块）")
            CapsuleButton(systemName: "trash", action: { store.clear(conversationID: session.conversationId?.uuidString) })
                .help("清空白板")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 手动加块：追加模板块并进入源码编辑（面板编辑态由渲染层按 index 恢复——
    /// 这里直接把新块置为编辑源码的初始内容，用户改完保存即落库）。
    private func addBlock(_ type: String, _ template: String) {
        let id = session.conversationId?.uuidString
        store.append([WhiteboardBlock(type: type, title: nil, content: template)],
                     title: nil, conversationID: id)
    }

    /// 导出 .board（JSON 文本，含全部块）。
    private func exportBoardFile() {
        let spec = store.board(for: session.conversationId?.uuidString)
        guard let data = try? JSONEncoder().encode(spec) else {
            exportStatus = "编码失败"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "(\(spec.title)).board".replacingOccurrences(of: "/", with: "-")
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url); exportStatus = "已导出 ✓" }
            catch { exportStatus = "写入失败" }
        }
    }

    /// 导入 .board：块**追加**到当前板（不覆盖既有内容）。
    private func importBoardFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url),
           let spec = try? JSONDecoder().decode(WhiteboardSpec.self, from: data) {
            let id = session.conversationId?.uuidString
            store.append(spec.blocks, title: spec.title, conversationID: id)
            exportStatus = "已导入 \(spec.blocks.count) 块 ✓"
        }
    }

    /// 把当前白板窗口内容快照成 PNG 存到下载目录。
    private func exportPNG() {
        guard let window = NSApp.windows.first(where: { $0.title == "白板" && $0.isVisible }),
              let contentView = window.contentView else {
            exportStatus = "找不到白板窗口"
            return
        }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            exportStatus = "快照失败"
            return
        }
        contentView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            exportStatus = "PNG 编码失败"
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("白板-\(stamp).png")
        do {
            try png.write(to: url)
            exportStatus = "已存到下载目录 ✓"
        } catch {
            exportStatus = "写入失败：\(error.localizedDescription)"
        }
    }
}
