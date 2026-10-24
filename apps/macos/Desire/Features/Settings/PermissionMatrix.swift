import Foundation

/// 隐私面板权限矩阵的纯逻辑（v0.8.6）：把 PermissionStore 的平铺规则
/// 聚合成"站点 × 权限类型"的矩阵行，并定义单元格点击的三态循环
/// （未设置 → 允许 → 拒绝 → 未设置）。Foundation-only，进 tests/run.sh。
nonisolated enum PermissionMatrix {
    /// 矩阵列展示的权限类型。`cameraAndMicrophone` 是站点独立申请的
    /// 联合权限，作为单独一列（决策查询按类型精确匹配，不能并入单列）。
    static let columns: [PermissionType] = [
        .camera, .microphone, .cameraAndMicrophone, .geolocation,
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
}
