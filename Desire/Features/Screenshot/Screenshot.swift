import AppKit
import Foundation

/// 截图流程的状态机。`editing` 关联当前正在编辑的图片。
enum ScreenshotPhase: Equatable {
    case idle
    case selecting
    case editing(NSImage)

    static func == (lhs: ScreenshotPhase, rhs: ScreenshotPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.selecting, .selecting): return true
        case (.editing, .editing): return true
        default: return false
        }
    }
}
