import Foundation

/// 批任务卡死判定（v0.8.2，纯逻辑，进 harness）。
///
/// 看门狗不能只看进度回调：有的下载在拿到第一段数据前就挂死（从未回调），
/// 只有 startedAt 可用；cancel 发出后 completion 也可能永远不来。统一策略：
/// - 180s 无进度（无进度时间则从进入 downloading 算）→ cancel；
/// - cancel 后 60s 仍未收尾 → 本机强制失败，释放并发槽；
/// - 已经能收尾/还没超时 → 不动。
nonisolated enum BatchStallPolicy {
    enum Action: Equatable {
        case none
        case cancel
        case forceFail
    }

    static func action(lastProgressAt: Date?, startedAt: Date?,
                       cancelledAt: Date?, now: Date = Date(),
                       stallSeconds: TimeInterval = 180,
                       cancelGraceSeconds: TimeInterval = 60) -> Action {
        guard let reference = lastProgressAt ?? startedAt,
              now.timeIntervalSince(reference) > stallSeconds else { return .none }
        if let cancelledAt {
            return now.timeIntervalSince(cancelledAt) > cancelGraceSeconds
                ? .forceFail : .none
        }
        return .cancel
    }
}
