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

    /// 字符预算换算（v0.8.70 事故定案重构）：
    /// - 窗口未知（档案未设、provider 未自报）→ **不做窗口换算**，维持
    ///   默认字符预算 160k（0.8.59 口径）——per-模型名猜测表已永久移除
    ///   （GLM-5.3-Flash 1M 被猜成 32k、生效预算崩 19k 的根源）；
    /// - 窗口已知（用户显式 / provider 自报 / 溢出学习）→ 窗口 × 0.9 ÷
    ///   比率（校准 ≥minSamples 用实测比率，否则默认比率 2.5）。**窗口是
    ///   权威——不再被 160k 封顶**（封顶曾把用户显式的 1M 静默压回 160k）。
    ///   下限 20k 仅防手滑填 0。
    static func budgetChars(windowTokens: Int?, calibration: Entry?) -> Int {
        let ratio: Double
        if let calibration, calibration.samples >= minSamples {
            ratio = calibration.ratio
        } else {
            ratio = defaultRatio
        }
        guard let windowTokens, windowTokens > 0 else { return fallbackBudgetChars }
        let byWindow = Double(windowTokens) * windowSafety / ratio
        return max(20_000, Int(byWindow))
    }

    /// per-模型名默认窗口表已**永久移除**（v0.8.70 事故：猜测表把 GLM-5.3-Flash
    /// 的 1M 窗口估成 32k → 生效预算崩 19k → 模型"失忆"）。窗口来源 =
    /// 用户在档案里显式设置（serviceEditor 输入框）> provider /models 自报
    /// （modelContextWindows）> 溢出错误自动学习（`parseWindowTokens`）。
    /// 窗口未知 → 预算回退 160k 字符默认，**不猜**。

    /// 溢出错误文本里的窗口数字模式（v0.8.71 批 B 溢出学习）：只认"窗口
    /// 关键词**后面**紧跟的数字"——报错里请求自身的 token 数出现在别处
    /// （"your messages resulted in N tokens"），认它会把请求大小当成窗口。
    static let overflowWindowPattern =
        "(?:maximum context length|context length|context window|max(?:imum)? context|context limit|最大上下文)[^0-9]{0,40}([0-9][0-9,]{2,})"

    /// 溢出错误文本 → 真实窗口 tokens。解析不出或数字不可信（<1024 或
    /// >10M）返回 nil——宁可不学，不学错。（文本不可变、单次现算，无
    /// NSRange 缓存风险。）
    static func parseWindowTokens(from errorText: String) -> Int? {
        let text = String(errorText.lowercased().prefix(2_000))
        guard let regex = try? NSRegularExpression(pattern: overflowWindowPattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else { return nil }
        let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
        guard let value = Int(raw), value >= 1024, value <= 10_000_000 else { return nil }
        return value
    }
}
