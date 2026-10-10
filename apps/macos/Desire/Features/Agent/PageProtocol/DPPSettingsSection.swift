import SwiftUI
import UniformTypeIdentifiers

/// AI 设置页里的「DPP 协议」区块：Agent 智能接管的统一开关面。
/// 此前事件三档只有桥端点（`/dpp/mode`）可改、协议解析与提示注入
/// 完全没有配置——用户看不见也关不掉。
struct DPPSettingsSection: View {
    @ObservedObject private var config = DPPConfigStore.shared
    @ObservedObject private var hub = PageEventHub.shared
    /// 第三方适配包（2026-10-10）。
    @ObservedObject private var adapters = DPPAdapterStore.shared
    @Environment(\.appAccent) private var appAccent: Color
    @State private var importError: String?

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
            adaptersBlock
        }
        .alert(
            String(localized: "Import failed"),
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button(String(localized: "OK")) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// 第三方适配包：站点没接入 DPP 时由社区声明（页面声明优先，适配器
    /// 只补空白）。导入 JSON / 逐包启停 / 删除。
    @ViewBuilder
    private var adaptersBlock: some View {
        SettingsRowDivider()
        SettingsRow(
            String(localized: "Third-Party Adapters"),
            subtitle: String(localized: "Community-written DPP declarations for popular sites (applied only when the page has no native declaration). Drop JSON files or import below.")
        ) {
            HStack(spacing: 8) {
                Button {
                    pickAndImport()
                } label: {
                    Text(String(localized: "Import"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    installFromURLPrompt()
                } label: {
                    Text("URL")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "Install an adapter package from an http(s) URL"))
            }
        }
        if !adapters.adapters.isEmpty || !adapters.loadErrors.isEmpty {
            SettingsRowDivider()
            VStack(spacing: 0) {
                ForEach(adapters.adapters) { adapter in
                    adapterRow(adapter)
                    SettingsRowDivider()
                }
                ForEach(adapters.loadErrors.keys.sorted(), id: \.self) { file in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(file)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(adapters.loadErrors[file] ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.vertical, 6)
                    if file != adapters.loadErrors.keys.sorted().last {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    private func adapterRow(_ adapter: DPPAdapter) -> some View {
        SettingsRow(
            adapter.name,
            subtitle: "\(adapter.hosts.joined(separator: ", "))\(adapter.notes.isEmpty ? "" : " — \(adapter.notes)")",
            systemImage: "puzzlepiece.extension"
        ) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { adapters.isEnabled(adapter) },
                    set: { adapters.setEnabled($0, for: adapter.name) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Button {
                    adapters.remove(adapter.name)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Delete"))
            }
        }
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try adapters.importFile(at: url)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// URL 安装：系统弹窗输入直链（仓库 docs/dpp-adapters/ 的 GitHub raw
    /// 链接、任何静态托管），拉取校验后落盘。
    private func installFromURLPrompt() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install Adapter from URL")
        alert.informativeText = String(localized: "Paste an http(s) URL to an adapter JSON (e.g. from docs/dpp-adapters).")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…/juejin.json"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { @MainActor in
                do {
                    _ = try await adapters.installFromURL(trimmed)
                } catch {
                    importError = error.localizedDescription
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
