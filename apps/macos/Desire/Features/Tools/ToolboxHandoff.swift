import Combine
import Foundation
import SwiftUI

/// 工具页交接（v0.8.27 媒体批；v0.8.33 扩展文本载荷）：
/// 查看器/右键/剪贴板把文件或文本递给目标工具；深链 `?text=` 也走这里。
///
/// 用 token 而不是"onAppear 一次性取走"：目标工具可能**已经是当前选中项**
/// （用户停在视频剪辑页、又在播放器里点了"剪辑"），此时视图不会重建、
/// onAppear 不会再来；token 变化经 onChange 通知在位视图消费。
@MainActor
final class ToolboxHandoff: ObservableObject {
    static let shared = ToolboxHandoff()

    @Published private(set) var token = 0
    @Published private(set) var requestToken = 0
    private var files: [String: URL] = [:]
    private var texts: [String: String] = [:]
    private var requestedTool: ToolID?

    func setPendingFile(_ url: URL, for tool: ToolID) {
        files[tool.rawValue] = url
        token += 1
    }

    func takeFile(for tool: ToolID) -> URL? {
        files.removeValue(forKey: tool.rawValue)
    }

    func setPendingText(_ text: String, for tool: ToolID) {
        texts[tool.rawValue] = text
        token += 1
    }

    func takeText(for tool: ToolID) -> String? {
        texts.removeValue(forKey: tool.rawValue)
    }

    /// 在工具箱页内请求切换到目标工具（结果接力用；不新开标签）。
    func requestTool(_ tool: ToolID, text: String) {
        setPendingText(text, for: tool)
        requestedTool = tool
        requestToken += 1
    }

    func takeRequestedTool() -> ToolID? {
        defer { requestedTool = nil }
        return requestedTool
    }
}

/// 跨功能入口：带上文本并打开工具箱的目标工具（新标签）。
@MainActor
enum ToolboxLauncher {
    /// 右键/剪贴板/结果接力的常用目标（纯文本类）。
    static let textTools: [ToolID] = [
        .base64, .url, .json, .hash, .markdown, .regexReplace,
        .zhConvert, .pinyin, .morse,
    ]

    static func open(_ tool: ToolID, text: String) {
        ToolboxHandoff.shared.setPendingText(text, for: tool)
        InternalPages.openAnywhere(.tools(param: tool.rawValue))
    }

    static func matchTool(_ raw: String?) -> ToolID? {
        guard let raw, !raw.isEmpty else { return nil }
        let needle = raw.lowercased()
        return ToolID.allCases.first { $0.rawValue.lowercased() == needle }
    }
}

/// 让工具的主输入框接收交接文本（深链 `?text=` / 右键 / 剪贴板）。
private struct ToolboxTextSeedModifier: ViewModifier {
    let tool: ToolID
    @Binding var text: String
    @ObservedObject private var handoff = ToolboxHandoff.shared

    func body(content: Content) -> some View {
        content
            .onAppear { consume() }
            .onChange(of: handoff.token) { _, _ in consume() }
    }

    private func consume() {
        guard let value = handoff.takeText(for: tool) else { return }
        text = value
    }
}

extension View {
    func toolboxTextSeed(_ tool: ToolID, into text: Binding<String>) -> some View {
        modifier(ToolboxTextSeedModifier(tool: tool, text: text))
    }
}
