import SwiftUI

/// AI 设置页里的「DPP 协议」区块：Agent 智能接管的统一开关面。
/// 此前事件三档只有桥端点（`/dpp/mode`）可改、协议解析与提示注入
/// 完全没有配置——用户看不见也关不掉。
struct DPPSettingsSection: View {
    @ObservedObject private var config = DPPConfigStore.shared
    @ObservedObject private var hub = PageEventHub.shared
    @Environment(\.appAccent) private var appAccent: Color

    var body: some View {
        SettingsSection(
            title: String(localized: "DPP Protocol"),
            subtitle: String(localized: "Declared pages (Desire Page Protocol) let the agent read structured data, run declared actions, and wake on page events."),
            icon: "doc.text.magnifyingglass"
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    String(localized: "Protocol Parsing"),
                    subtitle: String(localized: "Off disables DPP entirely: no parsing, no hints, no page events.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.enabled },
                        set: { config.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "Hints in Tool Results"),
                    subtitle: String(localized: "Attach declaration summaries (views/actions) to page tool results and page context.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.promptHints },
                        set: { config.setPromptHints($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                SettingsRowDivider()
                SettingsRow(
                    String(localized: "New Sites' Events"),
                    subtitle: String(localized: "Default automation level for sites you haven't configured. Auto = the agent wakes on page events and acts (sensitive actions still ask).")
                ) {
                    Picker("", selection: Binding(
                        get: { config.defaultEventMode },
                        set: { config.setDefaultEventMode($0) }
                    )) {
                        Text(String(localized: "Off")).tag(PageEventPolicy.modeOff)
                        Text(String(localized: "Draft")).tag(PageEventPolicy.modeDraft)
                        Text(String(localized: "Auto")).tag(PageEventPolicy.modeAuto)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }
            if !hub.siteModes.isEmpty {
                SettingsRowDivider()
                VStack(spacing: 0) {
                    ForEach(hub.siteModes.keys.sorted(), id: \.self) { host in
                        siteModeRow(host: host)
                        if host != hub.siteModes.keys.sorted().last {
                            SettingsRowDivider()
                        }
                    }
                }
            }
        }
    }

    /// 已显式配置过的站点行：三档 Menu + 移除（回到默认档）。
    private func siteModeRow(host: String) -> some View {
        SettingsRow(host, subtitle: nil, systemImage: "globe") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { hub.siteModes[host] ?? config.defaultEventMode },
                    set: { hub.setMode($0, for: host) }
                )) {
                    Text(String(localized: "Off")).tag(PageEventPolicy.modeOff)
                    Text(String(localized: "Draft")).tag(PageEventPolicy.modeDraft)
                    Text(String(localized: "Auto")).tag(PageEventPolicy.modeAuto)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)
                Button {
                    hub.setMode(PageEventPolicy.modeOff, for: host)
                    // 移除显式配置 = 回落到默认档（siteModes 删除该键）
                    hub.removeMode(for: host)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove — fall back to the default level"))
            }
        }
    }
}
