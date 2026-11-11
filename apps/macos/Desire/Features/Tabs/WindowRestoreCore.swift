import Foundation

/// 多窗口恢复的**纯逻辑**（v0.8.52 批 1）：从持久化快照里决定恢复哪些窗口，
/// 以及把保存的 frame 裁回当前可见区。Foundation-only、进 tests/run.sh。
///
/// 设计口径：
/// - 只恢复用户窗口（Agent 窗口按角色路径恢复，混进来会互相顶）；
/// - 只恢复磁盘上确有会话文件、且标签数 > 0 的窗口（空窗/幽灵窗不复活）；
/// - 崩溃/强杀时套年龄过滤（默认 7 天）与数量上限（默认 5），防测试残留复活；
/// - 顺序：活动窗口优先，其次最近活跃时间降序（会话键做稳定 tie-break）。
nonisolated enum WindowRestoreCore {
    static let defaultCap = 5
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let cascadeStep: Double = 24
    static let minimumSize = (width: 480.0, height: 320.0)
    static let fallbackSize = (width: 1000.0, height: 700.0)

    /// 挑选本次要**补开**的窗口（首窗已认领的不在其中）。
    /// - Parameter existingKeys: 磁盘上存在非空会话文件的 key 集合。
    /// - Parameter adoptedKey: 首窗已认领的 key（排除，避免重复开）。
    static func plan(snapshots: [WindowSnapshot],
                     mode: WindowRestoreMode,
                     existingKeys: Set<String>,
                     adoptedKey: String?,
                     cap: Int = defaultCap,
                     maxAge: TimeInterval = maxAge,
                     now: Date = Date()) -> [WindowSnapshot] {
        guard mode == .all else { return [] }
        let candidates = snapshots.filter { snapshot in
            let role = snapshot.role.isEmpty ? "user" : snapshot.role
            guard role == "user" else { return false }
            guard existingKeys.contains(snapshot.sessionKey) else { return false }
            guard snapshot.tabCount > 0 else { return false }
            guard adoptedKey == nil || snapshot.sessionKey != adoptedKey else { return false }
            guard now.timeIntervalSince(snapshot.lastActiveAt) <= maxAge else { return false }
            return true
        }
        let sorted = candidates.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.lastActiveAt != b.lastActiveAt { return a.lastActiveAt > b.lastActiveAt }
            return a.sessionKey < b.sessionKey
        }
        return Array(sorted.prefix(max(0, cap)))
    }

    /// 给一组待恢复窗口分配阶梯序号：只有保存时就在同一位置（≤2pt）的窗口
    /// 才依次错开，不同位置原样回位。nil frame 的窗口不参与（序号 0）。
    static func cascadeIndexes(for frames: [WindowFrame?]) -> [Int] {
        // 以 2pt 为粒度量化原点：同位置的窗口计数递增（第 n 个错开 n 档），
        // 不同位置互不影响。
        var counts: [String: Int] = [:]
        var result: [Int] = []
        for frame in frames {
            guard let frame else {
                result.append(0)
                continue
            }
            let key = "\(Int((frame.x / 2).rounded())),\(Int((frame.y / 2).rounded()))"
            let count = counts[key] ?? 0
            counts[key] = count + 1
            result.append(min(count, 7))
        }
        return result
    }

    /// 把保存的 frame 裁回可见区。屏幕坐标原点左下、y 向上（NSWindow 语义）。
    ///
    /// 规则：选重叠面积最大的屏幕（都无交集则主屏）→ 尺寸限制在可见区内、
    /// 不小于最小尺寸 → 原点完整落在可见区内 → 叠加阶梯偏移（同帧多窗不
    /// 完全重叠）后再裁一次。
    static func clampedFrame(_ frame: WindowFrame, screens: [WindowFrame],
                             cascadeIndex: Int = 0) -> WindowFrame {
        guard !screens.isEmpty else {
            return sanitized(frame)
        }
        let size = sanitizedSize(frame)
        let target = targetScreen(for: frame, screens: screens) ?? screens[0]
        let offset = max(0, cascadeIndex) == 0
            ? 0
            : Double(max(0, cascadeIndex) % 8) * cascadeStep

        let width = min(size.width, max(minimumSize.width, target.width))
        let height = min(size.height, max(minimumSize.height, target.height))
        var x = frame.x + offset
        var y = frame.y + offset
        let maxX = target.x + max(0, target.width - width)
        let maxY = target.y + max(0, target.height - height)
        x = min(max(x, target.x), max(target.x, maxX))
        y = min(max(y, target.y), max(target.y, maxY))
        return WindowFrame(x: x, y: y, width: width, height: height)
    }

    /// 与任一屏幕有可见交集（用于判断"这扇窗回得来看得见"）。
    static func isVisible(_ frame: WindowFrame, screens: [WindowFrame]) -> Bool {
        screens.contains { screen in
            let overlapWidth = min(frame.x + frame.width, screen.x + screen.width)
                - max(frame.x, screen.x)
            let overlapHeight = min(frame.y + frame.height, screen.y + screen.height)
                - max(frame.y, screen.y)
            return overlapWidth >= 80 && overlapHeight >= 40
        }
    }

    private static func targetScreen(for frame: WindowFrame,
                                     screens: [WindowFrame]) -> WindowFrame? {
        func overlap(_ screen: WindowFrame) -> Double {
            let width = min(frame.x + frame.width, screen.x + screen.width)
                - max(frame.x, screen.x)
            let height = min(frame.y + frame.height, screen.y + screen.height)
                - max(frame.y, screen.y)
            guard width > 0, height > 0 else { return 0 }
            return width * height
        }
        let scored = screens.map { (screen: $0, area: overlap($0)) }
        guard let best = scored.max(by: { $0.area < $1.area }), best.area > 0 else {
            return screens.first
        }
        return best.screen
    }

    private static func sanitized(_ frame: WindowFrame) -> WindowFrame {
        let size = sanitizedSize(frame)
        return WindowFrame(x: frame.x.isFinite ? frame.x : 0,
                           y: frame.y.isFinite ? frame.y : 0,
                           width: size.width, height: size.height)
    }

    private static func sanitizedSize(_ frame: WindowFrame) -> (width: Double, height: Double) {
        let width = frame.width.isFinite && frame.width >= minimumSize.width
            ? frame.width : fallbackSize.width
        let height = frame.height.isFinite && frame.height >= minimumSize.height
            ? frame.height : fallbackSize.height
        return (width, height)
    }
}
