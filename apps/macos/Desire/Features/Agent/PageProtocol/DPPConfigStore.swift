import Combine
import Foundation

/// DPP 的 Agent 侧配置（设置页「DPP 协议」区块 + 桥 `/dpp/config`）。
/// 此前三件事各写死在各处：协议解析永远开、工具消息里的 [DPP] 提示
/// 永远注入、新站点的事件默认档硬编码 off——用户没有统一的接管开关。
@MainActor
final class DPPConfigStore: ObservableObject {
    static let shared = DPPConfigStore()

    /// 总开关：关 = 不解析声明、不注入提示、事件入口直接静默。
    @Published private(set) var enabled: Bool
    /// 工具消息里的 [DPP] 提示与页面上下文里的声明摘要。
    @Published private(set) var promptHints: Bool
    /// 未显式设置过的站点的事件默认档（off/draft/auto）。
    /// auto = 智能接管：页面事件直接唤醒智能体自动处理。
    @Published private(set) var defaultEventMode: String
    /// 按 host 关闭语义上下文注入（设计评审 #6）：页面 context 不进 system 层。
    @Published private(set) var contextDisabledHosts: Set<String>

    private init() {
        let d = UserDefaults.standard
        // enabled 缺省 true（协议解析是既有默认行为）；其余按保守缺省。
        enabled = d.object(forKey: "dpp.enabled") as? Bool ?? true
        promptHints = d.object(forKey: "dpp.promptHints") as? Bool ?? true
        let mode = d.string(forKey: "dpp.defaultEventMode") ?? PageEventPolicy.modeOff
        defaultEventMode = PageEventPolicy.isValidMode(mode) ? mode : PageEventPolicy.modeOff
        contextDisabledHosts = Set(d.stringArray(forKey: "dpp.contextDisabledHosts") ?? [])
    }

    /// 该 host 的语义上下文注入是否被用户关闭。
    func isContextDisabled(for host: String) -> Bool {
        contextDisabledHosts.contains(host.lowercased())
    }

    func setContextDisabled(_ disabled: Bool, for host: String) {
        let h = host.lowercased()
        if disabled { contextDisabledHosts.insert(h) } else { contextDisabledHosts.remove(h) }
        UserDefaults.standard.set(Array(contextDisabledHosts).sorted(), forKey: "dpp.contextDisabledHosts")
        objectWillChange.send()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "dpp.enabled")
    }

    func setPromptHints(_ value: Bool) {
        promptHints = value
        UserDefaults.standard.set(value, forKey: "dpp.promptHints")
    }

    func setDefaultEventMode(_ mode: String) {
        guard PageEventPolicy.isValidMode(mode) else { return }
        defaultEventMode = mode
        UserDefaults.standard.set(mode, forKey: "dpp.defaultEventMode")
    }
}
