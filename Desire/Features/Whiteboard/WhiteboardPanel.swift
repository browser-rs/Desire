import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

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
    @State private var renamingTitle = false
    @State private var titleDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.6)
            WhiteboardWebView(spec: store.board(for: session.conversationId?.uuidString))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if renamingTitle {
                TextField("", text: $titleDraft)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 200)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let draft = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !draft.isEmpty {
                            store.apply({ $0.title = draft }, conversationID: session.conversationId?.uuidString)
                        }
                        renamingTitle = false
                    }
            } else {
                Text(store.board(for: session.conversationId?.uuidString).title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture {
                        titleDraft = store.board(for: session.conversationId?.uuidString).title
                        renamingTitle = true
                    }
                    .help("点击重命名")
            }
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

    /// 导入 .board：当前板为空直接追加；非空时问一次（追加 / 替换 / 取消）。
    private func importBoardFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let spec = try? JSONDecoder().decode(WhiteboardSpec.self, from: data) else { return }
        let id = session.conversationId?.uuidString
        let current = store.board(for: id)
        var replace = false
        if !current.blocks.isEmpty {
            let alert = NSAlert()
            alert.messageText = "导入白板"
            alert.informativeText = "当前白板已有 \(current.blocks.count) 块。导入「\(spec.title)」（\(spec.blocks.count) 块）："
            alert.addButton(withTitle: "追加")
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            replace = response == .alertSecondButtonReturn
        }
        if replace {
            store.set(WhiteboardSpec(title: spec.title, blocks: spec.blocks), conversationID: id)
        } else {
            store.append(spec.blocks, title: spec.title, conversationID: id)
        }
        exportStatus = "已导入 \(spec.blocks.count) 块 ✓"
    }

    /// 把当前白板窗口内容快照成 PNG 存到下载目录。
    /// cacheDisplay 对 WKWebView 的合成层不可靠（常拍出空白/缺内容）——
    /// 优先 takeSnapshot：先量出全内容高，rect 取整个文档区域（可超出
    /// 可视视口，WebKit 会渲染该区域），失败再回退 cacheDisplay。
    private func exportPNG() {
        guard let window = NSApp.windows.first(where: { $0.title == "白板" && $0.isVisible }),
              let contentView = window.contentView else {
            exportStatus = "找不到白板窗口"
            return
        }
        exportStatus = "正在导出…"
        Task { @MainActor in
            guard let png = await Self.captureBoardPNG(from: contentView) else {
                exportStatus = "快照失败"
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

    /// 成图：takeSnapshot 拍全内容高（超出视口的部分 WebKit 会渲染出来）。
    private static func captureBoardPNG(from contentView: NSView) async -> Data? {
        if let webview = findBoardWebView(in: contentView) {
            let height = (try? await webview.evaluateJavaScript("document.body.scrollHeight")) as? Double ?? 0
            if height > 10 {
                let config = WKSnapshotConfiguration()
                // 上限防病态巨板（12000pt ≈ 16 屏）。
                config.rect = NSRect(x: 0, y: 0, width: webview.bounds.width, height: min(height, 12_000))
                let image: NSImage? = await withCheckedContinuation { cont in
                    webview.takeSnapshot(with: config) { img, _ in cont.resume(returning: img) }
                }
                if let image,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    return rep.representation(using: .png, properties: [:])
                }
            }
        }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        contentView.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func findBoardWebView(in view: NSView) -> WhiteboardWebView.WhiteboardWKWebView? {
        if let webview = view as? WhiteboardWebView.WhiteboardWKWebView { return webview }
        for sub in view.subviews {
            if let found = findBoardWebView(in: sub) { return found }
        }
        return nil
    }
}
