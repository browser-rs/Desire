import Foundation

/// **站点下载规则的说明性技能**（v0.8.77 批 2）：适配器里有了（或改了）`download` 段，
/// 就同步一段很短的技能——只说"这个站点有适配器、直接用批量下载、不要自己写脚本或
/// 预先抓地址"，**不写提取细节**（规则只在适配器这一处，两处各写一份一定会漂移）。
///
/// 由 `DPPAdapterStore.reload()` 驱动：规则内容的指纹变了才重写；适配器删了或不再带
/// 下载段，对应的技能一并撤掉。指纹存偏好，不进技能正文。
@MainActor
enum SiteDownloadSkillSync {

    /// 技能正文里的标记：据此只清理**本机制同步出来的**技能，不碰用户手写的。
    static let marker = SyncedSkillPlacement.marker

    private static let fingerprintKey = "dpp.download.skillFingerprints"
    private static let nameKey = "dpp.download.syncedSkillNames"

    static func skillName(for adapter: DPPAdapter) -> String {
        var host = (adapter.hosts.first ?? "site").trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix(".") { host = String(host.dropFirst()) }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let cleaned = host.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let base = String(String(cleaned).drop { $0 == "-" }).replacingOccurrences(of: "--", with: "-")
        return (base.isEmpty ? "site" : base) + "-download"
    }

    static func markdown(for adapter: DPPAdapter) -> String {
        let rules = adapter.download ?? DPPDownloadRules()
        let hosts = adapter.hosts.joined(separator: ", ")
        var lines: [String] = []
        lines.append("\(hosts) 有站点下载适配器「\(adapter.name)」，只对这个站点生效。")
        lines.append("- 直接把**详情页地址**交给 `downloadVideoList(urls: …)`：隐藏解析器按适配器里的规则提取正片，播放地址在开下那一刻才取（签名地址会过期，不要预先一次性抓取）。")
        lines.append("- 不要为这个站点另写下载脚本，也不要用命令行直连详情页（过不了 Cloudflare）；需要页面里的数据就走当前页面（`executeJS` 里的 fetch）。")
        if !adapter.pathPrefixes.isEmpty {
            lines.append("- 规则只适用于路径前缀：\(adapter.pathPrefixes.joined(separator: "、"))。")
        }
        var facts: [String] = []
        switch rules.perPageRule {
        case .one: facts.append("每个详情页 1 部正片")
        case .many: facts.append("每个详情页可能有多部正片，全部下载")
        case nil: break
        }
        facts.append("每路 \(rules.connections ?? DPPDownloadRules.defaultConnections) 个连接")
        if let engine = rules.enginePreference {
            facts.append("下载方式由本站规则指定：\(engine.rawValue)")
        }
        facts.append("地址有效期按 \(rules.tokenMinutes ?? DPPDownloadRules.defaultTokenMinutes) 分钟计")
        if let exclude = rules.exclude, !exclude.isEmpty { facts.append("排除命中 \(exclude.count) 条特征的地址") }
        lines.append("- 已知参数：\(facts.joined(separator: "；"))。")
        if let listView = rules.listView, !listView.isEmpty {
            lines.append("- 列表页用 `pageExtract(view: \"\(listView)\", all: true)` 取全详情页链接。")
        }
        lines.append("- 规则会随每次下载任务自动打磨（地址中途过期会缩短有效期、被限流会降并发）；批次日志出现「规则待重学」说明页面结构变了——那时重新看页面并更新适配器的 download 段（`saveDPPAdapter`）。")
        return lines.joined(separator: "\n")
    }

    /// 技能正文里的标记（紧跟 frontmatter 之后）：据此只清理**本机制同步出来的**技能。
    static func isSynced(skillText: String) -> Bool { SyncedSkillPlacement.isSynced(skillText) }

    /// 技能名 → 适配器名。只记录本机制同步过的技能。
    private static var syncedNames: [String: String] {
        AppPrefs.defaults.dictionary(forKey: nameKey) as? [String: String] ?? [:]
    }

    private static func fingerprint(of rules: DPPDownloadRules?) -> String {
        guard let rules, let data = try? JSONEncoder().encode(rules) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 在 `DPPAdapterStore.reload()` 之后调用：新增/变更的同步，失效的撤掉。
    static func reconcile(with adapters: [DPPAdapter]) {
        var prints = AppPrefs.defaults.dictionary(forKey: fingerprintKey) as? [String: String] ?? [:]
        var names = syncedNames
        var changed = false
        let withRules = adapters.filter { $0.download != nil }
        func textAt(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func path(of skillName: String) -> URL {
            SkillStore.directory.appendingPathComponent(SyncedSkillPlacement.fileName(for: skillName))
        }
        for adapter in withRules {
            let print = fingerprint(of: adapter.download)
            // 落点：以前登记过、且位置上仍是本机制写的 → 沿用；否则现算。名字可能被一份
            // **别的技能**占着（用户手写的、或智能体自己存的）——绝不覆盖，顺延落点。
            let placement = SyncedSkillPlacement.destination(
                in: SkillStore.directory, skillName: skillName(for: adapter),
                registered: names.first { $0.value == adapter.name }?.key, textAt: textAt)
            let skillName = placement.name
            // 规则内容的指纹变了才重写。同步出来的技能被用户删了不补回——删掉就是不要，
            // 等下次规则变了再说。
            guard prints[adapter.name] != print else { continue }
            let text = """
            ---
            name: \(skillName)
            description: \(adapter.hosts.joined(separator: ", ")) 的批量下载：站点适配器「\(adapter.name)」已定义正片规则——把详情页地址直接交给 downloadVideoList，不要自己写脚本或预先抓播放地址。
            ---
            \(marker)
            \(markdown(for: adapter))
            """
            do {
                try text.write(to: placement.path, atomically: true, encoding: .utf8)
                prints[adapter.name] = print
                names[skillName] = adapter.name
                changed = true
            } catch {
                continue
            }
        }
        // 适配器已删 / 不再带下载段：撤掉当初同步出来的技能（只认带标记的文件）。
        let live = Set(withRules.map(\.name))
        for (skillName, adapterName) in names where !live.contains(adapterName) {
            let path = path(of: skillName)
            if SyncedSkillPlacement.isSynced(textAt(path)) {
                try? FileManager.default.removeItem(at: path)
                changed = true
            }
            names.removeValue(forKey: skillName)
            prints.removeValue(forKey: adapterName)
        }
        guard changed else { return }
        AppPrefs.defaults.set(prints, forKey: fingerprintKey)
        AppPrefs.defaults.set(names, forKey: nameKey)
        SkillStore.shared.reload()
    }
}
