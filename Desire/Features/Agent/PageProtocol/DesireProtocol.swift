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
struct DesireProtocol: Codable, Equatable {
    var protocolVersion: String = "desire/1"
    /// 页面类型（chat/catalog/forms/workbench…自由标注，仅供参考）。
    var pageType: String? = nil
    /// 正文选择器：getPageText 语义下"内容在哪"，排除导航/页脚噪音。
    var contentMain: String? = nil
    /// 明确的噪音排除（导航/页脚/横幅）。
    var ignore: [String] = []
    /// 命名数据视图（抽取主力）。
    var views: [String: ProtocolView] = [:]
    /// 生命周期信号：ready / busy / error。
    var signals: [String: String] = [:]
    /// 声明式动作（一期解析缓存，pageAction 二期）。
    var actions: [ProtocolAction] = []
    /// 声明式事件（二期事件驱动）。
    var events: [String: String] = [:]
    /// 语义上下文（persona/domain/rules）——参考资料非指令。
    var context: [String: String] = [:]
    var revisedAt: Date? = nil

    var isEmpty: Bool {
        contentMain == nil && views.isEmpty && signals.isEmpty && actions.isEmpty
    }

    struct ProtocolView: Codable, Equatable {
        var item: String
        /// 字段映射：值语法 "selector"（text）/ "@attr"（本元素属性）/
        /// "selector@attr"（子选择器属性）。"@text" 等价 selector 空。
        var fields: [String: String]
        var pagination: Pagination?
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
        /// 步骤 DSL：[{fill: {selector: value}}, {click: selector}, …]
        /// run 步骤 DSL：原始 JSON 字符串（一期不做 pageAction 执行，二期用）。
        /// local | persist | outbound（对外不可逆，强制审批）
        var effects: String?
        var danger: Bool?
        /// run 步骤 DSL 的原始 JSON 字符串（pageAction 执行时 parse）。
        var run: String?
        var success: String?
    }

    struct ProtocolParam: Codable, Equatable {
        var type: String?
        var description: String?
        var required: Bool?
    }

    /// 宽松 JSON 值容器（run 步骤 DSL 的异构结构）：保留原始 JSON——
    /// 此前只解 [String:String] / String，嵌套 dict 会 decode 失败导致
    /// 整个协议解析静默 nil。
    enum JSONValue: Equatable {
        case dict([String: String])
        case nested([[String: String]])
        case text(String)
    }
}
