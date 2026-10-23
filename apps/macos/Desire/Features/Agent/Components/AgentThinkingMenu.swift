import SwiftUI

/// 输入栏的思考等级（reasoning effort）下拉：🧠 等级 ⌄，摆在模型选择器的
/// 右侧（上下文用量在左侧——用户参照主流客户端布局提的需求）。
/// "off" 是默认档：请求体里不带任何思考参数（见 `AgentService.buildBody`）。
///
/// **能力感知（v0.8.3）**：菜单只列当前模型真正支持的档位。支持的取值表来自
/// 服务端报错（"Supported types are xhigh, medium, and low"），由
/// `ReasoningEffortPolicy` 学会并按 endpoint|model 记住。网关把最大档叫
/// xhigh/max 时，选 "Highest" 会映射过去而不是报 "unsupported"。
struct AgentThinkingMenu: View {
    @ObservedObject var preference: AgentPreferenceStore

    private var supported: [String]? {
        preference.reasoningCapabilities(endpoint: preference.endpoint, model: preference.model)
    }

    private var levels: [String] {
        ReasoningEffortPolicy.offeredLevels(supported: supported)
    }

    /// 服务明确表示不支持可调档（学到了空列表）。
    private var isUnsupported: Bool { supported?.isEmpty == true }

    private var wireValue: String? {
        ReasoningEffortPolicy.wireValue(for: preference.reasoningEffort, supported: supported)
    }

    var body: some View {
        Menu {
            Section(String(localized: "Thinking Level")) {
                ForEach(levels, id: \.self) { effort in
                    Button {
                        preference.reasoningEffort = effort
                    } label: {
                        Label(
                            Self.title(for: effort),
                            systemImage: preference.reasoningEffort == effort ? "checkmark" : "brain.head.profile"
                        )
                    }
                }
            }
            if isUnsupported {
                Divider()
                Text("This model doesn't support adjustable thinking levels.")
            } else if let wireValue, wireValue != preference.reasoningEffort {
                Divider()
                Text(String(localized: "Sent to this service as \(wireValue)"))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 9, weight: .medium))
                Text(displayTitle)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        // 胶囊底/描边挂 Menu 整体 + 系统原生下拉指示（同 AgentModelMenu）。
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .tint(.secondary)
        .menuStyle(.borderlessButton)
        .help(helpText)
    }

    private var displayTitle: String {
        isUnsupported ? String(localized: "Not supported") : Self.title(for: preference.reasoningEffort)
    }

    private var helpText: String {
        if isUnsupported {
            return String(localized: "This model doesn't support adjustable thinking levels.")
        }
        if let supported, !supported.isEmpty {
            return String(localized: "This service supports: \(supported.joined(separator: ", "))")
        }
        return String(localized: "Thinking Level")
    }

    /// 档位显示名：off/medium 复用目录里已有的键，low/high 新增三语。
    static func title(for effort: String) -> String {
        switch effort {
        case "low": return String(localized: "Low")
        case "medium": return String(localized: "Medium")
        case "high": return String(localized: "Highest")
        default: return String(localized: "Off")
        }
    }
}
