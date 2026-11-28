import Foundation

/// 资源退避（v0.8.84 批 3 第 15 件，纯逻辑进 harness）：把内存压力/热状态/
/// 低电量折算成后台作业档位。**定时 Agent 任务不受影响**——那是用户交代的
/// 事；受影响的是下载并发、缩略图轮捕这类后台作业。
nonisolated enum ResourceGovernor {

    /// 热状态用 ProcessInfo.ThermalState 的 rawValue（0 nominal…3 critical），
    /// 保持 Foundation-only 可测。
    struct Conditions: Equatable, Sendable {
        var memoryPressure: Bool = false
        var thermalRaw: Int = 0
        var lowPower: Bool = false

        static let nominal = Conditions()
    }

    enum Load: String, Equatable, Sendable {
        /// 照常。
        case normal
        /// 后台作业降速（并发减半、轮询降频）。
        case reduced
        /// 后台作业暂停入队（Agent 定时任务照常）。
        case paused
    }

    static func load(_ c: Conditions) -> Load {
        // critical 热状态等同内存压力：先保护硬件。
        if c.memoryPressure || c.thermalRaw >= 3 { return .paused }
        if c.lowPower || c.thermalRaw >= 2 { return .reduced }
        return .normal
    }

    /// 折算并发上限：reduced 减半（至少留 1），paused 归零（排队）。
    /// **currentMax = 0 是"不限"**——normal/reduced 原样透传（0/1 不动，
    /// ≥2 才减半），paused 仍归零（对"不限"也是"新入队全停"）。
    /// 调用方要先用 load 自己判 paused，不能拿 0 当"不许跑"（v0.8.84
    /// 发版闸门真事故：0 被当上限 → 默认设置每个下载永远排队）。
    static func concurrency(currentMax: Int, load: Load) -> Int {
        switch load {
        case .normal: return currentMax
        case .reduced: return currentMax <= 1 ? currentMax : max(1, currentMax / 2)
        case .paused: return 0
        }
    }
}
