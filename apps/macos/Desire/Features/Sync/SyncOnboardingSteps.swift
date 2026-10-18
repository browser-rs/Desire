import Foundation

/// 新设备接入引导（v0.7.23）：把"登录之后到底还要做什么"从散在同步设置各页
/// 的四件事（账号 / 密钥 / 类目 / 首次拉取）收拢成一份 checklist。
///
/// **不新增任何状态**——四步完成度全部从 SyncStore 既有字段派生
///（authState / hasSyncKey / isEnabled 统计 / lastSyncAt），纯函数（Foundation-only）
/// 进 harness 测；文案与本地化留在视图层，这里只出结构与原始事实（fact）。
enum SyncOnboardingSteps {
    enum StepID: String, CaseIterable {
        case signIn
        case key
        case categories
        case firstSync
    }

    struct Step: Equatable {
        let id: StepID
        let isDone: Bool
        /// 要嵌进视图文案的原始事实（账号名 / 密钥指纹 / 类目数 / 相对时间），无则 nil。
        /// 视图按 id 取本地化模板再插值，这里绝不出整句。
        let fact: String?
    }

    /// 粗粒度相对时间（刚刚 / N 分钟前 / N 小时前 / N 天前）。
    /// 不用 RelativeDateTimeFormatter：这一档对语言环境不敏感且可单测。
    static func coarseRelative(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    /// `enabledCount` 由调用方统计（`SyncDomain.allCases.filter { store.isEnabled($0) }`），
    /// 纯函数不碰 store。
    static func derive(
        account: String?,
        hasKey: Bool,
        fingerprint: String?,
        enabledCount: Int,
        lastSyncAt: Date?,
        now: Date
    ) -> [Step] {
        [
            Step(id: .signIn, isDone: account != nil, fact: account),
            Step(id: .key, isDone: hasKey, fact: fingerprint),
            Step(id: .categories, isDone: enabledCount > 0,
                 fact: enabledCount > 0 ? "\(enabledCount)" : nil),
            Step(id: .firstSync, isDone: lastSyncAt != nil,
                 fact: lastSyncAt.map { coarseRelative(from: $0, to: now) }),
        ]
    }
}
