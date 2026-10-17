import Foundation

/// 鼠标手势轨迹 → 动作的**映射表**（v0.7.20 抽出为纯逻辑：Foundation-only
/// 进 tests/run.sh）。轨迹是方向字符序列：l/r/u/d（小写，连续同向已去重）。
/// nil = 未映射（忽略该手势——包括单 "u" 这种在部分手势扩展里含义冲突的）。
enum MouseGestureTrail {
    /// 支持的五式（0.7.13 起的行为，勿改语义）。
    static let supported: [(trail: String, action: String)] = [
        ("l", "back"),
        ("r", "forward"),
        ("lr", "reload"),
        ("d", "new-tab"),
        ("u", "close-tab"),
    ]

    static func action(for trail: String) -> String? {
        switch trail {
        case "l": return "back"
        case "r": return "forward"
        case "rl", "lr": return "reload"   // 先左后右/先右后左都算刷新（历史语义）
        case "d": return "new-tab"
        case "u": return "close-tab"
        default: return nil
        }
    }
}
