import Combine
import Foundation
import os

/// DPP 第三方适配包仓库（2026-10-10）：`Application Support/Desire/
/// DPPAdapters/*.json`。每包一个文件，启停状态独立持久化（UserDefaults
/// `dpp.adapter.disabled`——包文件本体保持"作者原样"，启停不污染文件）。
/// 适配器清单变化的通知：打开中的页面据此重新解析协议（`WebView.Coordinator` 观察）。
extension Notification.Name {
    static let dppAdaptersChanged = Notification.Name("dppAdaptersChanged")
}

/// 解析接入点：`WebView.Coordinator.parsePageProtocol` 页面无原生声明时
/// 按本 store 的索引查适配。
@MainActor
final class DPPAdapterStore: ObservableObject {
    static let shared = DPPAdapterStore()

    @Published private(set) var adapters: [DPPAdapter] = []
    /// 加载失败的文件（文件名 → 原因），设置页透出。
    @Published private(set) var loadErrors: [String: String] = [:]
    /// 装载来源目录里的 adapter name → 文件名（启停/删除要定位文件）。
    private var fileNames: [String: String] = [:]

    private static let disabledKey = "dpp.adapter.disabled"
    private var disabled: Set<String> = []

    static var directory: URL {
        let base = StorageRoot.directory
        let dir = base.appendingPathComponent("DPPAdapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        disabled = Set(AppPrefs.defaults.stringArray(forKey: Self.disabledKey) ?? [])
        autoDisabled = Set(AppPrefs.defaults.stringArray(forKey: Self.autoDisabledKey) ?? [])
        health = Self.loadHealth()
        reload()
    }

    func isEnabled(_ adapter: DPPAdapter) -> Bool {
        !disabled.contains(adapter.name)
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        AppPrefs.defaults.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        objectWillChange.send()
    }

    /// host+url 命中的**第一个启用**适配器（文件名排序决定优先级——
    /// 稳定、可预期；同名场景极少，先不做包内优先级配置）。
    func adapter(for url: URL) -> DPPAdapter? {
        adapters
            .filter { isEnabled($0) && !autoDisabled.contains($0.name) && $0.matches(url: url) }
            .min { $0.name < $1.name }
    }

    // MARK: - 存活度（设计评审 #8）：适配包会随站点改版静默失效——
    // 记录每个包的抽取/动作失败次数，连续失败达到阈值在 inspect/设置页
    // 亮"疑似失效"，达到硬阈值自动禁用（用户可重新启用）。
    //
    // v0.8.3：健康记录**持久化**（此前只在内存里，重启即忘），并补上
    // 最近成功/失败时间与最近错误——运营页"这个渠道还能不能用"直接读它。

    struct Health: Codable, Equatable {
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var successCount: Int = 0
        var failureCount: Int = 0
        var lastError: String?
    }

    @Published private(set) var health: [String: Health] = [:]

    private var failureCounts: [String: Int] = [:]
    private let softThreshold = 3
    private let hardThreshold = 8
    private static let autoDisabledKey = "dpp.adapter.autodisabled"
    private static let healthKey = "dpp.adapter.health"

    private(set) var autoDisabled: Set<String> = []

    /// 适配包参与的抽取/动作失败时上报（名字来自 warnings 戳）。
    func reportFailure(adapterName: String, error: String? = nil) {
        var record = health[adapterName] ?? Health()
        record.failureCount += 1
        record.lastFailureAt = Date()
        if let error, !error.isEmpty { record.lastError = error }
        health[adapterName] = record
        persistHealth()
        failureCounts[adapterName, default: 0] += 1
        if failureCounts[adapterName] == hardThreshold {
            autoDisabled.insert(adapterName)
            AppPrefs.defaults.set(Array(autoDisabled), forKey: Self.autoDisabledKey)
            Log.agent.warning("adapter '\(adapterName, privacy: .public)' auto-disabled after \(self.hardThreshold) consecutive failures")
        }
    }

    func reportSuccess(adapterName: String) {
        var record = health[adapterName] ?? Health()
        record.successCount += 1
        record.lastSuccessAt = Date()
        record.failureCount = 0
        record.lastError = nil
        health[adapterName] = record
        persistHealth()
        failureCounts[adapterName] = 0
        if autoDisabled.contains(adapterName) {
            autoDisabled.remove(adapterName)
            AppPrefs.defaults.set(Array(autoDisabled), forKey: Self.autoDisabledKey)
        }
    }

    /// 存活度状态（设置页/inspect 透出）：ok / suspect / autoDisabled。
    func health(of name: String) -> String {
        if autoDisabled.contains(name) { return "autoDisabled" }
        let n = health[name]?.failureCount ?? failureCounts[name] ?? 0
        if n >= softThreshold { return "suspect" }
        return "ok"
    }

    func healthRecord(for name: String) -> Health? { health[name] }

    private func persistHealth() {
        guard let data = try? JSONEncoder().encode(health) else { return }
        AppPrefs.defaults.set(data, forKey: Self.healthKey)
    }

    private static func loadHealth() -> [String: Health] {
        guard let data = AppPrefs.defaults.data(forKey: healthKey),
              let decoded = try? JSONDecoder().decode([String: Health].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: - 加载

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil
        ) else { return }
        var loaded: [DPPAdapter] = []
        var errors: [String: String] = [:]
        var filesByName: [String: String] = [:]
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else {
                errors[url.lastPathComponent] = "unreadable"
                continue
            }
            let (adapter, error) = DPPAdapter.decode(data)
            if let adapter {
                // 同名包后加载的覆盖（目录名即身份，与 SkillStore 同语义）。
                loaded.removeAll { $0.name == adapter.name }
                loaded.append(adapter)
                filesByName[adapter.name] = url.lastPathComponent
            } else {
                errors[url.lastPathComponent] = error ?? "invalid"
            }
        }
        adapters = loaded.sorted { $0.name < $1.name }
        loadErrors = errors
        fileNames = filesByName
        // 带下载段的适配器 → 同步一段说明性技能（指纹变了才写；v0.8.77 批 2）。
        SiteDownloadSkillSync.reconcile(with: adapters)
        // 清单变了（导入 / 删除 / 启用 / 编辑）：让**打开中的页面**重新解析——
        // 否则"导入了没反应、刷新一下才有"（2026-11-26 实测就这么以为没打通）。
        NotificationCenter.default.post(name: .dppAdaptersChanged, object: nil)
    }

    // MARK: - 站点下载规则（v0.8.77 批 2）

    /// 这个地址命中的、**已启用**适配器的下载规则；没命中 / 适配器不管下载 = nil。
    func downloadRules(for url: URL) -> (adapter: DPPAdapter, rules: DPPDownloadRules)? {
        guard let adapter = adapter(for: url), let rules = adapter.download else { return nil }
        return (adapter, rules)
    }

    /// 回写前的旧版备份目录。放在适配器目录**之外**：适配器目录会被重扫，
    /// 备份待在里面会被当成适配包。
    static var downloadBackupDirectory: URL {
        let dir = StorageRoot.directory.appendingPathComponent("dpp-adapter-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 按一次下载任务的结果回写规则（"不停打磨"）。只动 download 段：
    /// - **不走 `saveDraft`**——它会把适配器打回禁用草稿，参数微调不该要求用户重新启用；
    /// - 覆盖前把旧文件备份一份；
    /// - 规则没变（健康规则、参数已触底）不写盘。
    /// 返回是否落盘。
    @discardableResult
    func refineDownloadRules(adapterName: String,
                             signal: DPPDownloadRules.AdaptationSignal) -> Bool {
        guard let adapter = adapters.first(where: { $0.name == adapterName }),
              var rules = adapter.download, rules.needsWrite(for: signal) else { return false }
        rules = rules.adapting(to: signal)
        var updated = adapter
        updated.download = rules
        guard let file = fileNames[adapterName] else { return false }
        let target = Self.directory.appendingPathComponent(file)
        let fm = FileManager.default
        let backup = Self.downloadBackupDirectory.appendingPathComponent(
            "\(FilePathing.sanitizeFileName(adapterName))-\(Self.backupStamp()).json")
        do {
            try fm.createDirectory(at: Self.downloadBackupDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.copyItem(at: target, to: backup) }
            try JSONEncoder().encode(updated).write(to: target, options: .atomic)
        } catch {
            Log.agent.error("download rule refinement failed for '\(adapterName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return false
        }
        reload()
        return true
    }

    /// 把一次实测并入适配器的下载画像（v0.8.79）。**遥测字段**：不产修订、不备份
    /// （否则每次下载都落一份备份）；变化不到 5%、样本没增加、连接数没变时跳过写盘。
    func recordMeasured(adapterName: String, evidence: ParallelTuning.Evidence) {
        guard let index = adapters.firstIndex(where: { $0.name == adapterName }),
              let rules = adapters[index].download else { return }
        let updatedRules = rules.recording(evidence)
        guard let after = updatedRules.measured else { return }
        if let before = rules.measured {
            let delta = abs(after.parallelBytesPerSecond - before.parallelBytesPerSecond)
                / max(before.parallelBytesPerSecond, 1)
            // 只有**样本已封顶**时才允许按"变化小"跳过：否则样本数会被一起冻住，
            // 永远到不了门槛（2），画像就永远不可用。
            let atCap = before.samples >= DPPDownloadRules.measuredSampleCap
            if delta < 0.05, atCap, after.connections == before.connections { return }
        }
        var updated = adapters[index]
        updated.download = updatedRules
        guard let file = fileNames[adapterName] else { return }
        let target = Self.directory.appendingPathComponent(file)
        do {
            try JSONEncoder().encode(updated).write(to: target, options: .atomic)
        } catch {
            Log.agent.error("record measured speed failed for '\(adapterName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 导入 / 删除

    /// 导入一个适配包文件（拷进目录；同名 = 覆盖更新）。
    /// 来源标记：URL 导入记 http(s) 链接，文件导入记 file 路径（供应链审计）。
    func importFile(at source: URL) throws -> DPPAdapter {
        let data = try Data(contentsOf: source)
        let (adapter, error) = DPPAdapter.decode(data)
        guard var adapter else {
            throw ImportError.invalid(error ?? "invalid")
        }
        adapter.sourceURL = source.absoluteString
        adapter.installedAt = Date()
        let enriched = try JSONEncoder().encode(adapter)
        let target = Self.directory.appendingPathComponent("\(adapter.name).json")
        try enriched.write(to: target, options: .atomic)
        reload()
        return adapter
    }

    /// 从 URL 安装社区适配包（http(s) 直链 JSON；同名 = 覆盖更新）。
    /// 社区分发的最小闭环：仓库 docs/dpp-adapters/ 的 GitHub raw 链接、
    /// 任何静态托管都能当包源。http 不落地（协议降级拒收）。
    @discardableResult
    func installFromURL(_ urlString: String) async throws -> DPPAdapter {
        guard let url = URL(string: urlString), url.scheme == "https" else {
            throw ImportError.invalid("URL must be https (http is rejected — adapter packages control selectors and actions for a host)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImportError.invalid("server returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard data.count < 2_000_000 else {
            throw ImportError.invalid("package over 2MB — not a declaration")
        }
        let (adapter, error) = DPPAdapter.decode(data)
        guard var adapter else {
            throw ImportError.invalid(error ?? "invalid")
        }
        // 供应链记录：来源 URL + 安装时间随包落盘（设置页透出、换机不丢）。
        adapter.sourceURL = urlString
        adapter.installedAt = Date()
        let enriched = try JSONEncoder().encode(adapter)
        let target = Self.directory.appendingPathComponent("\(adapter.name).json")
        try enriched.write(to: target, options: .atomic)
        reload()
        return adapter
    }

    /// Studio / Agent 草稿落盘（v0.8.3）：写入后**默认禁用**——适配包会真实
    /// 参与页面解析与动作，未经用户过目不得生效。同名覆盖同样回到禁用态，
    /// 逼一次显式启用（避免"悄悄换了选择器"）。
    func saveDraft(_ adapter: DPPAdapter) throws {
        let name = adapter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw ImportError.invalid("adapter name is required and cannot contain /")
        }
        let data = try JSONEncoder().encode(adapter)
        let target = Self.directory.appendingPathComponent("\(name).json")
        try data.write(to: target, options: .atomic)
        disabled.insert(name)
        AppPrefs.defaults.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        reload()
    }

    func remove(_ name: String) {
        if let file = fileNames[name] {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
        disabled.remove(name)
        AppPrefs.defaults.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        reload()
    }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Invalid adapter package: \(detail)"
            }
        }
    }
}
