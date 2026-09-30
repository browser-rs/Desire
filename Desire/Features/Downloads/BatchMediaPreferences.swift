import Foundation

/// 批量下载的用户偏好（引擎的确定性默认值来源）。
///
/// 三条来源，优先级：**工具调用显式参数 > 这里的持久偏好 > 内置默认**。
/// 偏好在两处落笔：
/// - UserDefaults（引擎读的真相）：`batch.naming` / `batch.baseDirectory` /
///   `batch.lowSpaceGB`；
/// - **Agent 长期记忆**（`AgentMemoryStore.addFact`）：用户表达过的偏好同步
///   写一条 fact，模型在后续会话里看得见、能主动照着办（2026-09-26 实测
///   教训：模型只有"写文件"这一条路记偏好，用户点出该用长期记忆）。
enum BatchMediaPreferences {
    /// **已下载去重开关**：批量重跑同一列表时跳过索引里已有的项
    /// （`force` 参数可对单个批次绕过）。默认开。
    static var skipDownloaded: Bool {
        get { defaults.object(forKey: skipDownloadedKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: skipDownloadedKey) }
    }

    /// 同批下载并发上限（1-4，默认 2）。
    static var maxConcurrent: Int {
        get {
            let raw = defaults.object(forKey: "batch.maxConcurrent") as? Int ?? 2
            return max(1, min(raw, 4))
        }
        set { defaults.set(max(1, min(newValue, 4)), forKey: "batch.maxConcurrent") }
    }

    private static let defaults = UserDefaults.standard
    private static let namingKey = "batch.naming"
    private static let baseDirectoryKey = "batch.baseDirectory"
    private static let reserveKey = "batch.reserveGB"
    private static let skipDownloadedKey = "batch.skipDownloaded"

    /// 命名风格。默认 `clean`：真实站点那批的原始标题是"描述-代号"模板重复
    /// 三遍再 80 字符硬截，用户原话"文件命名也是奇葩"。
    static var namingStyle: BatchMediaPlan.NamingStyle {
        get {
            defaults.string(forKey: namingKey)
                .flatMap(BatchMediaPlan.NamingStyle.init(rawValue:)) ?? .clean
        }
        set {
            defaults.set(newValue.rawValue, forKey: namingKey)
            remember("批量下载命名风格 = \(namingStyleDescription(newValue))")
        }
    }

    /// 自定义保存根目录（nil = ~/Downloads）。用户在低空间询问里选过
    /// "换位置"后持久化，后续批次默认落这里。
    static var baseDirectory: String? {
        get { defaults.string(forKey: baseDirectoryKey) }
        set {
            defaults.set(newValue, forKey: baseDirectoryKey)
            if let newValue {
                remember("批量下载保存位置 = \(newValue)（之后的批次默认存这里）")
            }
        }
    }

    /// **分卷规则（默认值）**：目标目录下每 N 个文件滚动 archivedNNN 子文件夹
    /// （nil = 不分卷）。批的显式 `splitEvery` 参数优先；这里是无参数时的默认。
    /// 出厂默认 **120**（用户规则：每 120 个文件一卷）。显式关闭会存 0
    /// （get 回 nil）——不能靠删键回默认，否则"关掉"与"未设置"无法区分。
    static var splitEvery: Int? {
        get {
            guard let raw = defaults.object(forKey: splitKey) as? Int else { return 120 }
            return raw > 0 ? raw : nil
        }
        set {
            if let v = newValue, v > 0 {
                defaults.set(v, forKey: splitKey)
            } else {
                defaults.set(0, forKey: splitKey)
            }
        }
    }

    /// 首次进入"视频任务"面板时的设置引导已完成（不再自动弹出）。
    static var onboardingDone: Bool {
        get { defaults.bool(forKey: onboardingKey) }
        set { defaults.set(newValue, forKey: onboardingKey) }
    }

    /// **单个下载任务的总时长上限（分钟）**：HLS/直连/ffmpeg 共用一条 deadline，
    /// 到点判 `.timedOut` 失败（可重试）。默认 120（用户实测 30 分钟不够
    /// 长视频慢网络）；0 = 不限制。
    /// nonisolated：错误文案（非隔离上下文）也要读它；只碰 UserDefaults。
    nonisolated static var exportTimeoutMinutes: Int {
        get { UserDefaults.standard.object(forKey: Self.exportTimeoutKey) as? Int ?? 120 }
        set { UserDefaults.standard.set(max(0, min(newValue, 600)), forKey: Self.exportTimeoutKey) }
    }

    private nonisolated static let exportTimeoutKey = "media.exportTimeoutMinutes"
    private static let onboardingKey = "batch.onboardingDone"
    private static let splitKey = "batch.splitEvery"

    /// **磁盘预留空间（GB）**：保存位置剩余低于该值时挂起批次并提醒用户，
    /// 空间回到 `预留 + 512MB` 以上自动续跑——硬底线，不做"继续"绕过
    ///（防止把用户磁盘写满是目的，绕过就失去意义）。默认 5GB。
    static var reserveGB: Int {
        get {
            let raw = defaults.object(forKey: reserveKey) as? Int ?? 5
            return max(1, min(raw, 1000))
        }
        set {
            defaults.set(max(1, min(newValue, 1000)), forKey: reserveKey)
        }
    }

    static var namingStyleDescription: String {
        namingStyleDescription(namingStyle)
    }

    /// 工具调用显式带了 naming 参数 = 用户偏好经模型转达 → 记成持久默认。
    static func applyExplicitNaming(_ raw: String?) {
        guard let raw,
              let style = BatchMediaPlan.NamingStyle(rawValue: raw.lowercased()) else { return }
        namingStyle = style
    }

    private static func namingStyleDescription(_ style: BatchMediaPlan.NamingStyle) -> String {
        switch style {
        case .clean: "清洗标题（折叠站点模板重复段，60 字符内）"
        case .title: "页面标题原样"
        case .code: "番号/代号优先（如 MOV-2024001，无代号退回清洗标题）"
        }
    }

    /// 偏好写入长期记忆（去重由 addFact 负责；失败静默——记忆是辅助通道，
    /// UserDefaults 才是引擎读的真相）。
    private static func remember(_ content: String) {
        AgentMemoryStore.shared.addFact(content: content, category: "preference")
    }
}
