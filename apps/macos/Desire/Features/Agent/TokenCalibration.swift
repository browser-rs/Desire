import Foundation

/// **Token 校准**（v0.8.60 批 1，Foundation-only 进 tests/run.sh）：
/// 上下文预算从"160k 字符盲猜"升级为 token 真值——每个模型用实测样本
/// （请求字符数 ÷ 服务端自报 promptTokens）维护一个 EMA 字符/令牌比，
/// 结合档案的窗口 tokens 换算出**字符预算**（压缩/芯片/自动压缩触发继续
/// 以字符为工作单位，只在换算层做真值化——改动面最小）。
///
/// 灰度安全：样本 < `minSamples` 的模型没有可信比率 → 回退默认字符预算
/// （160k），行为与 0.8.59 完全一致。`compactionBudgetOverride`（超限/
/// 空响应重试写的"按真实窗口校准"）在消费端优先于本换算。
nonisolated enum TokenCalibration {

    /// 无校准样本时的回退字符预算（= 0.8.59 的固定口径）。
    static let fallbackBudgetChars = 160_000
    /// 可信校准需要的最少样本数。
    static let minSamples = 3
    /// 比率夹逼：中文/混合文本实测大致 1.8–3.5 chars/token，夹宽一点防
    /// 畸形样本（纯 base64/纯 ASCII）把比率拽飞。
    static let ratioLower: Double = 1.5
    static let ratioUpper: Double = 6.0
    /// EMA 平滑因子（新样本权重）。
    static let emaAlpha: Double = 0.3
    /// 换算预算时的安全系数（窗口 × 0.9 ÷ 比率）。
    static let windowSafety: Double = 0.9
    /// 无校准样本时的假设比率（中英混合文本的常见值）。
    static let defaultRatio: Double = 2.5

    /// 单模型校准记录（Codable，落 `AgentPreferenceStore.modelCalibration`）。
    struct Entry: Codable, Equatable {
        /// 当前 EMA 比率（chars/token）。
        var ratio: Double
        /// 累计样本数。
        var samples: Int
        /// 最后更新（诊断）。
        var updatedAt: Date

        init(ratio: Double, samples: Int, updatedAt: Date = Date()) {
            self.ratio = ratio
            self.samples = samples
            self.updatedAt = updatedAt
        }
    }

    /// 模型名 → 校准表的 key（网关会改写模型名，按请求时选的记）。
    static func key(forModel model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 单条样本并入：新样本 = chars/promptTokens（promptTokens > 0 才有效），
    /// 首样本直接立值，之后 EMA；比率始终夹逼。
    static func update(_ entry: Entry?, chars: Int, promptTokens: Int) -> Entry? {
        guard promptTokens > 0, chars > 0 else { return entry }
        let sample = Double(chars) / Double(promptTokens)
        guard sample.isFinite, sample > 0 else { return entry }
        let clamped = min(ratioUpper, max(ratioLower, sample))
        guard let entry else {
            return Entry(ratio: clamped, samples: 1)
        }
        let blended = entry.ratio * (1 - emaAlpha) + clamped * emaAlpha
        return Entry(ratio: min(ratioUpper, max(ratioLower, blended)),
                     samples: entry.samples + 1,
                     updatedAt: Date())
    }

    /// 字符预算换算：
    /// - 无窗口且无校准 → 160k（0.8.59 口径）；
    /// - 有校准（≥minSamples）→ min(160k, 窗口 × 0.9 ÷ 比率)；窗口 nil 视为
    ///   不设限（只按比率收紧字符预算会误伤大窗口模型，保守回退）；
    /// - 有窗口无校准 → min(160k, 窗口 × 0.9 ÷ 默认比率 2.5)。
    static func budgetChars(windowTokens: Int?, calibration: Entry?) -> Int {
        let ratio: Double
        if let calibration, calibration.samples >= minSamples {
            ratio = calibration.ratio
        } else {
            ratio = defaultRatio
        }
        // 没配窗口时不做换算（比率只能换算字符↔token，没有窗口就没得换），
        // 维持默认字符预算。
        guard let windowTokens, windowTokens > 0 else { return fallbackBudgetChars }
        let byWindow = Double(windowTokens) * windowSafety / ratio
        return max(20_000, min(fallbackBudgetChars, Int(byWindow)))
    }

    /// 模型名前缀默认窗口表（档案未设 contextWindowTokens 时用）。
    static func defaultWindowTokens(forModel model: String) -> Int {
        let m = model.lowercased()
        if m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return 200_000 }
        if m.hasPrefix("gpt-4") || m.hasPrefix("gpt-3") { return 128_000 }
        if m.hasPrefix("claude") { return 200_000 }
        if m.hasPrefix("deepseek") { return 64_000 }
        if m.hasPrefix("qwen") || m.hasPrefix("qwq") { return 128_000 }
        if m.hasPrefix("gemini") { return 1_000_000 }
        if m.hasPrefix("llama") || m.hasPrefix("mistral") || m.hasPrefix("glm") { return 32_000 }
        return 32_000   // 本地/未知 → 保守值
    }
}
