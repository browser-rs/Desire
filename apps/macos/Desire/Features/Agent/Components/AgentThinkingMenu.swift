import SwiftUI

/// 输入栏的思考等级（reasoning effort）下拉：🧠 等级 ⌄，摆在模型选择器的
/// 右侧（上下文用量在左侧——用户参照主流客户端布局提的需求）。
/// "off" 是默认档：请求体里不带任何思考参数（见 `AgentService.buildBody`）。
struct AgentThinkingMenu: View {
    @ObservedObject var preference: AgentPreferenceStore

    var body: some View {
        Menu {
            Section(String(localized: "Thinking Level")) {
                ForEach(AgentPreferenceStore.reasoningEfforts, id: \.self) { effort in
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 9, weight: .medium))
                Text(Self.title(for: preference.reasoningEffort))
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
        .help(String(localized: "Thinking Level"))
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
