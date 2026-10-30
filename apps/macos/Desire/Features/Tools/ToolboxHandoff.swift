import Combine
import Foundation

/// 工具页交接（v0.8.27 媒体批）：查看器（媒体播放器等）把文件递给工具页的
/// 目标工具——desire://tools/<id> 深链只带工具 id，文件走这个进程内交接。
///
/// 用 token 而不是"onAppear 一次性取走"：目标工具可能**已经是当前选中项**
/// （用户停在视频剪辑页、又在播放器里点了"剪辑"），此时视图不会重建、
/// onAppear 不会再来；token 变化经 onChange 通知在位视图消费。
@MainActor
final class ToolboxHandoff: ObservableObject {
    static let shared = ToolboxHandoff()

    @Published private(set) var token = 0
    private var files: [String: URL] = [:]

    func setPendingFile(_ url: URL, for tool: ToolID) {
        files[tool.rawValue] = url
        token += 1
    }

    func takeFile(for tool: ToolID) -> URL? {
        files.removeValue(forKey: tool.rawValue)
    }
}
