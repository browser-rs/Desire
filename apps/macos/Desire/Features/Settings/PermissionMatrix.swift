import Foundation

/// 隐私面板权限矩阵的纯逻辑（v0.8.6）：把 PermissionStore 的平铺规则
/// 聚合成"站点 × 权限类型"的矩阵行，并定义单元格点击的三态循环
/// （未设置 → 允许 → 拒绝 → 未设置）。Foundation-only，进 tests/run.sh。
nonisolated enum PermissionMatrix {
    /// 矩阵列展示的权限类型。`cameraAndMicrophone` 是站点独立申请的
    /// 联合权限，作为单独一列（决策查询按类型精确匹配，不能并入单列）。
    /// v0.8.80 增弹窗 / 剪贴板读取两列。
    static let columns: [PermissionType] = [
        .camera, .microphone, .cameraAndMicrophone, .geolocation, .popups, .clipboardRead,
    ]

    struct Row: Equatable {
        let host: String
        /// 仅含有规则的类型 → 决策。
        let decisions: [PermissionType: PermissionDecision]

        var hasAnyRule: Bool { !decisions.isEmpty }
    }

    /// 平铺规则 → 按站点聚合、按主机名排序的矩阵行。
    static func build(from rules: [PermissionRule]) -> [Row] {
        var byHost: [String: [PermissionType: PermissionDecision]] = [:]
        for rule in rules {
            byHost[rule.host, default: [:]][rule.type] = rule.decision
        }
        return byHost
            .map { Row(host: $0.key, decisions: $0.value) }
            .sorted { $0.host < $1.host }
    }

    /// 单元格三态循环：未设置 → 允许 → 拒绝 → 未设置（= 删除该条规则）。
    static func cycled(_ current: PermissionDecision?) -> PermissionDecision? {
        switch current {
        case nil: return .allow
        case .allow: return .deny
        default: return nil
        }
    }

    /// 摄像头 / 麦克风行写规则时，联合权限（`cameraAndMicrophone`）跟着走：
    /// 两者都允许才允许，任一拒绝即拒绝，否则未设置。锁弹层按"摄像头/麦克风"
    /// 两行展示，但 WebKit 对 `getUserMedia({video, audio})` 问的是联合类型——
    /// 只写单类会让"我明明允许了摄像头和麦克风"的站点仍然被问。纯逻辑，进 harness。
    static func combinedDecision(camera: PermissionDecision?,
                                 microphone: PermissionDecision?) -> PermissionDecision? {
        switch (camera, microphone) {
        case (.allow, .allow): return .allow
        case (.deny, _), (_, .deny): return .deny
        default: return nil
        }
    }

    /// 清除浏览数据的时间范围（v0.8.80）：nil = 全部时间（`.distantPast`）。
    enum ClearRange: String, CaseIterable {
        case pastHour, pastDay, pastWeek, allTime

        /// 该范围的起点（`allTime` = nil）。
        func since(now: Date = Date()) -> Date? {
            let interval: TimeInterval?
            switch self {
            case .pastHour: interval = 3_600
            case .pastDay: interval = 86_400
            case .pastWeek: interval = 7 * 86_400
            case .allTime: interval = nil
            }
            return interval.map { now.addingTimeInterval(-$0) }
        }
    }
}
