import Foundation

/// DPP 第三方适配包（2026-10-10）：站点没主动接入 DPP 时，由第三方按
/// host 编写的**声明式**适配（与 L3 SDK `expose()` 同一套协议格式——
/// views/signals/actions/sections/ignore…）。纯 JSON 无代码：动作的 run
/// 步骤由既有 pageAction 执行器执行，审批链照常生效，适配包不引入新
/// 执行面。
///
/// 优先级：**页面原生声明（L0–L3 任意形态）> 适配器**——适配器只补空白，
/// 不覆盖站点自己的声明（站点接入后适配包自然失效）。解析接入点在
/// `WebView.Coordinator.parsePageProtocol`（页面无原生声明 → 查 host 索引）。
/// Foundation-only：进 tests/run.sh（匹配/解码回退语义）。
nonisolated struct DPPAdapter: Codable, Equatable, Identifiable {
    /// 格式版本，当前固定 "desire/adapter-1"。
    var format: String = "desire/adapter-1"
    /// 适配包名（唯一 id，也是文件名基）。
    var name: String
    /// 适配的 host 列表（精确或 `前缀*` 子域通配，如 ".juejin.cn" 匹配
    /// 所有子域——存储语义见 matches(host:)）。
    var hosts: [String]
    /// 可选的路径前缀过滤（如 ["/entry/", "/post/"]——空 = 全站命中）。
    var pathPrefixes: [String] = []
    /// 替站点声明的协议体（DesireProtocol 的 Codable 子集——整份复用，
    /// well-known 专用字段 pages 随它去，适配器用不上）。
    var protocolBody: DesireProtocol
    /// 一句话说明（来源/校准状态），设置页展示。
    var notes: String = ""
    /// 安装来源（URL 安装时记录；文件导入 = nil）。供应链审计用。
    var sourceURL: String?
    /// 最近一次安装/更新的时间（陈旧提示用）。
    var installedAt: Date?
    /// 运营契约版本（v0.8.3）：nil = 非运营包；1 = `ops/1`。旧包缺键 = nil。
    var opsVersion: Int? = nil
    /// 登录页地址（v0.8.8 A3 登录态指引）：opsLoginRequired 命中时"打开
    /// 登录页"按钮的目标。缺省回退站点根。
    var loginURL: String? = nil
    /// 最近一次**真实页面核对/测试**的时间（运营包的健康展示基准；与
    /// installedAt 区分：安装/覆盖不等于核对过）。
    var verifiedAt: Date? = nil

    var id: String { name }

    // 手写解码：format/notes/pathPrefixes 是**缺省键**（合成 Codable 会因
    // 默认值不兜底而要求键存在——适配包作者不该被逼着写 format）。
    init(name: String, hosts: [String], pathPrefixes: [String] = [],
         protocolBody: DesireProtocol = DesireProtocol(), notes: String = "",
         sourceURL: String? = nil, installedAt: Date? = nil,
         opsVersion: Int? = nil, verifiedAt: Date? = nil,
         loginURL: String? = nil) {
        self.format = "desire/adapter-1"
        self.name = name
        self.hosts = hosts
        self.pathPrefixes = pathPrefixes
        self.protocolBody = protocolBody
        self.notes = notes
        self.sourceURL = sourceURL
        self.installedAt = installedAt
        self.opsVersion = opsVersion
        self.loginURL = loginURL
        self.verifiedAt = verifiedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? "desire/adapter-1"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        hosts = (try? c.decode([String].self, forKey: .hosts)) ?? []
        pathPrefixes = (try? c.decode([String].self, forKey: .pathPrefixes)) ?? []
        protocolBody = (try? c.decodeIfPresent(DesireProtocol.self, forKey: .protocolBody)) ?? DesireProtocol()
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        sourceURL = (try? c.decodeIfPresent(String.self, forKey: .sourceURL)) ?? nil
        installedAt = (try? c.decodeIfPresent(Date.self, forKey: .installedAt)) ?? nil
        opsVersion = (try? c.decodeIfPresent(Int.self, forKey: .opsVersion)) ?? nil
        verifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .verifiedAt)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case format, name, hosts, pathPrefixes, protocolBody, notes, sourceURL, installedAt,
             opsVersion, verifiedAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(name, forKey: .name)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(pathPrefixes, forKey: .pathPrefixes)
        try c.encode(protocolBody, forKey: .protocolBody)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(installedAt, forKey: .installedAt)
        try c.encodeIfPresent(opsVersion, forKey: .opsVersion)
        try c.encodeIfPresent(verifiedAt, forKey: .verifiedAt)
    }

    // MARK: - Matching

    /// host 匹配：精确相等，或包以"."开头做子域通配（".juejin.cn" 命中
    /// juejin.cn / www.juejin.cn / x.juejin.cn）。大小写不敏感。
    func matchesHost(_ host: String) -> Bool {
        let h = host.lowercased()
        for pattern in hosts {
            let p = pattern.lowercased()
            if p.hasPrefix(".") {
                if h == p.dropFirst() || h.hasSuffix(p) { return true }
            } else if h == p {
                return true
            }
        }
        return false
    }

    /// 路径过滤：pathPrefixes 为空 = 全站；否则路径须以任一前缀开头。
    func matchesPath(_ path: String) -> Bool {
        guard !pathPrefixes.isEmpty else { return true }
        return pathPrefixes.contains { path.hasPrefix($0) }
    }

    func matches(url: URL) -> Bool {
        guard let host = url.host, matchesHost(host) else { return false }
        return matchesPath(url.path)
    }
}

// MARK: - 解码（容错：坏包只拒自己，不影响其他适配器）

extension DPPAdapter {
    /// 宽松解码：protocolBody 也接受 "protocol" 键名（手写适配包最常见的
    /// 另一种拼写）；坏格式返回 nil 并给出原因。手写 init 对缺键全兜底，
    /// 所以回退条件是"协议体为空且顶层 protocol 键存在"而非解码抛错。
    static func decode(_ data: Data) -> (adapter: DPPAdapter?, error: String?) {
        func finish(_ a: DPPAdapter) -> (DPPAdapter?, String?) {
            let name = a.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return (nil, "missing name") }
            guard !a.hosts.isEmpty else { return (nil, "missing hosts") }
            var fixed = a
            fixed.name = name
            fixed.protocolBody.warnings.append("adapter: \(name)")
            return (fixed, nil)
        }
        var raw = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if raw["protocolBody"] == nil, raw["protocol"] != nil {
            raw["protocolBody"] = raw.removeValue(forKey: "protocol")
            guard let retryData = try? JSONSerialization.data(withJSONObject: raw),
                  let retried = try? JSONDecoder().decode(DPPAdapter.self, from: retryData) else {
                return (nil, "protocol body not decodable")
            }
            return finish(retried)
        }
        let adapter = try? JSONDecoder().decode(DPPAdapter.self, from: data)
        guard let adapter else {
            return (nil, "protocol body not decodable")
        }
        return finish(adapter)
    }
}
