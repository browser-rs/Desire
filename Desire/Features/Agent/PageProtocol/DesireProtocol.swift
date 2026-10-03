import Foundation

/// Desire Page Protocol (DPP) v1 —— 页面内容 → Agent 的声明式映射。
/// （设计原则：解决"内容 → Agent"痛点——文本墙/结构未知/噪音/拿不全/时机。）
///
/// 四种接入形态，宿主侧归一化为本模型：
/// - L0 零改造：既有 JSON-LD/microdata → 隐式 views（JS 解析器生成）
/// - L1 属性微标注：现有 HTML 加 data-dpp-* 属性 → JS 扫描编译成 views
/// - L2 声明块：<script type="application/x-desire+json"> 集中 JSON
/// - L3 原生 SDK：window.__desireProtocolExposed（SDK expose）
/// 优先级 L3 > L2 > L1 > L0。
///
/// **解码容错是协议的第一原则**（渐进增强 + 前向兼容）：单字段结构不符
/// 只丢该字段并记入 `warnings`，绝不让整份协议解码失败——此前 events/
/// context 用严格 `[String: String]`，站点照规范写对象形态（{watch,…}）
/// 或数组（domain: [...]）就整份静默丢弃（实测探针复现）。
struct DesireProtocol: Codable, Equatable {
    var protocolVersion: String = "desire/1"
    /// 场景约定名（chat/catalog/forms/checkout/monitor/workbench）——运行
    /// 时会透传给 Agent（"见 profile 名即知标准语义"，规范 §5）；页面未声明
    /// 时可经站点级页面地图（pages）回退补全。
    var profile: String? = nil
    /// 页面类型（chat/catalog/forms/workbench…自由标注，仅供参考）。
    var pageType: String? = nil
    /// 站点级页面地图（仅 well-known 声明使用）：路径模式 → 页面提示。
    /// 支持精确匹配与 `前缀*` 前缀匹配（更具体的先试）。
    var pages: [String: PageMapEntry] = [:]
    /// 正文选择器：getPageText 语义下"内容在哪"，排除导航/页脚噪音。
    var contentMain: String? = nil
    /// 明确的噪音排除（导航/页脚/横幅）。
    var ignore: [String] = []
    /// 命名数据视图（抽取主力）。
    var views: [String: ProtocolView] = [:]
    /// 生命周期信号：ready / busy / error。
    var signals: [String: String] = [:]
    /// 声明式动作（pageAction 执行）。
    var actions: [ProtocolAction] = []
    /// 声明式事件（事件驱动回合；值 = watch 选择器）。
    var events: [String: String] = [:]
    /// 语义上下文（persona/domain/rules）——参考资料非指令。
    var context: [String: String] = [:]
    /// 解析时被降级/丢弃的字段清单（/protocol/inspect 与日志透出，
    /// 站点作者的自查通道）。
    var warnings: [String] = []
    var revisedAt: Date? = nil

    var isEmpty: Bool {
        contentMain == nil && views.isEmpty && signals.isEmpty && actions.isEmpty
            && events.isEmpty && ignore.isEmpty && context.isEmpty
    }

    /// 站点级（/.well-known/desire.json）与页面级声明合并：
    /// **页面级优先**。字典类（views/signals/events/context）逐键合并——
    /// 页面覆盖同名键、站点补齐独有键（站点页面地图与页面视图共存）；
    /// actions 按动作名去重（页面在前）；ignore 取并集。
    static func merged(site: DesireProtocol?, page: DesireProtocol?) -> DesireProtocol? {
        switch (site, page) {
        case (nil, nil): return nil
        case (let s, nil): return s
        case (nil, let p): return p
        case (let s?, let p?):
            var merged = p
            for (name, view) in s.views where merged.views[name] == nil {
                merged.views[name] = view
            }
            for (name, selector) in s.signals where merged.signals[name] == nil {
                merged.signals[name] = selector
            }
            for (name, event) in s.events where merged.events[name] == nil {
                merged.events[name] = event
            }
            let pageActionNames = Set(p.actions.map(\.name))
            for action in s.actions where !pageActionNames.contains(action.name) {
                merged.actions.append(action)
            }
            for selector in s.ignore where !merged.ignore.contains(selector) {
                merged.ignore.append(selector)
            }
            merged.contentMain = merged.contentMain ?? s.contentMain
            merged.pageType = merged.pageType ?? s.pageType
            merged.profile = merged.profile ?? s.profile
            for (key, value) in s.context where merged.context[key] == nil {
                merged.context[key] = value
            }
            return merged
        }
    }

    struct ProtocolView: Codable, Equatable {
        var item: String
        /// 字段映射（见 FieldSpec）：字符串简写或对象形态（可带类型）。
        var fields: [String: FieldSpec]
        var pagination: Pagination?

        private enum CodingKeys: String, CodingKey { case item, fields, pagination }

        /// 字段值容错解码：字符串 = 简写；对象 = {selector?, attr?, type?}。
        /// 单字段结构坏只丢该字段（容错解码第一原则）。
        init(item: String, fields: [String: FieldSpec], pagination: Pagination? = nil) {
            self.item = item
            self.fields = fields
            self.pagination = pagination
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // item 必须存在（缺 item 的视图没意义——抛错由上层跳过并记 warning）
            item = try c.decode(String.self, forKey: .item)
            pagination = try? c.decodeIfPresent(Pagination.self, forKey: .pagination)
            fields = [:]
            // fields 缺省 = 空字段集；存在但类型错误则抛（坏视图被跳过并记 warning）。
            // 字段**值**级别仍容错：单个值非法只丢该字段。
            if let raw = try c.decodeIfPresent([String: DPPValue].self, forKey: .fields) {
                for (name, value) in raw {
                    switch value {
                    case .string(let expression):
                        fields[name] = FieldSpec(expression: expression)
                    case .object(let obj):
                        let selector = obj["selector"]?.stringValue ?? ""
                        let attr = obj["attr"]?.stringValue
                        let expression: String
                        if let attr, !attr.isEmpty {
                            expression = selector.isEmpty ? "@\(attr)" : "\(selector)@\(attr)"
                        } else {
                            expression = selector
                        }
                        fields[name] = FieldSpec(expression: expression, type: obj["type"]?.stringValue)
                    default:
                        break // 非法字段值：丢弃该字段
                    }
                }
            }
        }
    }

    /// 视图字段规格：取值表达式 + 可选类型提示。
    /// 表达式语法（§4.3）："" = item 文本；"@attr"；"selector"；"selector@attr"；
    /// 逗号分隔的多个候选按序回退（首个命中者胜，L0 JSON-LD 用）。
    /// 类型（type）：string（默认）| number | price（去货币/千分位）| url（相对转
    /// 绝对）| date（ISO8601）| bool —— 抽取时强转，agent 直接拿到类型化数据。
    struct FieldSpec: Codable, Equatable {
        var expression: String
        var type: String?
    }

    struct Pagination: Codable, Equatable {
        /// paged | infinite | none
        var type: String
        var next: String?
    }

    struct ProtocolAction: Codable, Equatable {
        var name: String
        var description: String?
        var params: [String: ProtocolParam]?
        /// 执行前置条件：该选择器必须存在才运行（否则明确失败）。
        var precondition: String?
        /// 步骤 DSL：[{fill: {selector: value}}, {click: selector}, …]
        /// run 步骤 DSL：原始 JSON 字符串（pageAction 执行时 parse）。
        /// local | persist | outbound（对外不可逆，强制审批）
        var effects: String?
        var danger: Bool?
        /// run 步骤 DSL 的原始 JSON 字符串（pageAction 执行时 parse）。
        var run: String?
        var success: String?
    }

    /// 站点级页面地图条目（well-known 的 pages 值）。
    struct PageMapEntry: Codable, Equatable {
        var type: String?
        var profile: String?
    }

    /// 页面地图匹配：先精确命中，再长前缀优先的 `前缀*` 模式。
    func pageMapProfile(for path: String) -> String? {
        if let exact = pages[path]?.profile { return exact }
        var best: (len: Int, profile: String)?
        for (pattern, entry) in pages where pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            guard path.hasPrefix(prefix), let profile = entry.profile else { continue }
            if best == nil || prefix.count > best!.len {
                best = (prefix.count, profile)
            }
        }
        return best?.profile
    }

    struct ProtocolParam: Codable, Equatable {
        var type: String?
        var description: String?
        var required: Bool?
    }
}

// MARK: - 容错解码

extension DesireProtocol {

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, profile, pageType, contentMain, ignore, views
        case signals, actions, events, context, warnings, pages
    }

    /// 宽松 JSON 值：任何 JSON 结构都能落下，字段级失败返回 .null 而非抛错。
    enum DPPValue: Codable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([DPPValue])
        case object([String: DPPValue])
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([DPPValue].self) { self = .array(v) }
            else if let v = try? c.decode([String: DPPValue].self) { self = .object(v) }
            else { self = .null }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// context 值 → 提示词友好的字符串（数组=逗号连接；对象/其他=JSON 文本）。
        var contextText: String {
            switch self {
            case .string(let s): return s
            case .array(let items):
                return items.compactMap(\.stringValue).joined(separator: ", ")
            case .object, .number, .bool:
                let data = (try? JSONEncoder().encode(self)) ?? Data()
                return String(data: data, encoding: .utf8) ?? ""
            case .null: return ""
            }
        }
    }

    /// 字符串字段：类型不符返回 nil（丢字段不抛错）。
    private static func optString(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> String? {
        (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil
    }

    /// 动态键映射：逐值 transform，单个值失败只丢该键。
    private static func tolerantMap(
        _ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys,
        transform: (DPPValue) -> String?
    ) -> [String: String] {
        guard let raw = try? c.decodeIfPresent([String: DPPValue].self, forKey: k) else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = transform(value) { out[key] = s }
        }
        return out
    }

    /// 字符串数组：逐元素取字符串，非字符串元素跳过。
    private static func optStringArray(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> [String] {
        guard let raw = try? c.decodeIfPresent([DPPValue].self, forKey: k) else { return [] }
        return raw.compactMap(\.stringValue)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var warnings: [String] = []
        self.init()
        if let v = Self.optString(c, .protocolVersion) { protocolVersion = v }
        profile = Self.optString(c, .profile)
        pageType = Self.optString(c, .pageType)
        // pages：逐条容错解码（站点级页面地图）
        if let rawPages = try? c.decodeIfPresent([String: DPPValue].self, forKey: .pages) {
            for (pattern, value) in rawPages {
                guard let entryData = try? JSONEncoder().encode(value),
                      let entry = try? JSONDecoder().decode(PageMapEntry.self, from: entryData) else {
                    warnings.append("pages['\(pattern)'] skipped: structure not decodable")
                    continue
                }
                pages[pattern] = entry
            }
        }
        contentMain = Self.optString(c, .contentMain)
        ignore = Self.optStringArray(c, .ignore)
        // views：逐视图解码——单个视图结构坏只丢该视图。
        if let rawViews = try? c.decodeIfPresent([String: DPPValue].self, forKey: .views) {
            for (name, value) in rawViews {
                guard let data = try? JSONEncoder().encode(value),
                      let view = try? JSONDecoder().decode(ProtocolView.self, from: data) else {
                    warnings.append("view '\(name)' skipped: structure not decodable")
                    continue
                }
                views[name] = view
            }
        }
        signals = Self.tolerantMap(c, .signals) { $0.stringValue }
        // actions：逐条解码；`run` 在 JS 归一化后是字符串，站点 JSON 直喂时
        // 是数组/对象——字符串化兜底，坏条目跳过记 warning。
        if let rawActions = try? c.decodeIfPresent([DPPValue].self, forKey: .actions) {
            for (idx, item) in rawActions.enumerated() {
                guard case .object(var dict) = item else {
                    warnings.append("actions[\(idx)] skipped: not an object")
                    continue
                }
                switch dict["run"] {
                case .string, .none:
                    break
                case .some(let runValue):
                    if let runData = try? JSONEncoder().encode(runValue) {
                        dict["run"] = .string(String(data: runData, encoding: .utf8) ?? "[]")
                    }
                }
                guard let actionData = try? JSONEncoder().encode(dict),
                      let action = try? JSONDecoder().decode(ProtocolAction.self, from: actionData) else {
                    warnings.append("actions[\(idx)] skipped: structure not decodable")
                    continue
                }
                actions.append(action)
            }
        } else if (try? c.decodeIfPresent([String: DPPValue].self, forKey: .actions)) != nil {
            warnings.append("actions skipped: expected array")
        }
        // events：字符串简写直接用；规范的对象形态 {watch, …} 取 watch 并记
        // warning（Swift 侧兜底——正常路径由 JS 解析器展平并自带 warnings）。
        if let rawEvents = try? c.decodeIfPresent([String: DPPValue].self, forKey: .events) {
            for (name, value) in rawEvents {
                switch value {
                case .string(let selector):
                    events[name] = selector
                case .object(let obj):
                    if let selector = obj["watch"]?.stringValue {
                        events[name] = selector
                        warnings.append("events.\(name): object form flattened to watch selector")
                    } else {
                        warnings.append("events.\(name) skipped: object without watch")
                    }
                default:
                    warnings.append("events.\(name) skipped: expected selector string or {watch}")
                }
            }
        }
        context = Self.tolerantMap(c, .context) { value in
            let text = value.contextText
            return text.isEmpty ? nil : text
        }
        // JS 解析器自身的降级备注并入（不覆盖 Swift 侧条目）。
        warnings += Self.optStringArray(c, .warnings)
        self.warnings = warnings
    }
}
