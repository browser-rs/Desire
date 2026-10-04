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

    private init() {
        let d = UserDefaults.standard
        // enabled 缺省 true（协议解析是既有默认行为）；其余按保守缺省。
        enabled = d.object(forKey: "dpp.enabled") as? Bool ?? true
        promptHints = d.object(forKey: "dpp.promptHints") as? Bool ?? true
        let mode = d.string(forKey: "dpp.defaultEventMode") ?? PageEventPolicy.modeOff
        defaultEventMode = PageEventPolicy.isValidMode(mode) ? mode : PageEventPolicy.modeOff
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
