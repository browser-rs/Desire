import Foundation

/// 搭桥测试探针（DEBUG-only）：编辑器把关键交互状态写进来，
/// `POST /editor/synthetic {action:"state"}` 读取。生产构建为空实现。
@MainActor
enum ImageEditorDebug {
    static var latest: [String: Any] = [:]
    /// 瞬时事件值（不被 writeProbe 的整体赋值冲掉）。
    static var lastStamp: [String: Any] = [:]
}
