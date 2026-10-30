import SwiftUI

/// 站点控制中心（v0.7.21）：锁图标弹层里的"本站所有覆盖"一站式管理——
/// 缩放 / 暗色 / 自动播放 / 页面字体 / 元素拦截，外加"清除本站覆盖"。
/// 数据直接观察 `SiteSettingsStore`（弹层属 Panel 例外：可以持有 store），
/// 一切动作走 props 回调（Props in, Callbacks out）。
struct SiteControlsView: View {
    struct Actions {
        let zoomIn: () -> Void
        let zoomOut: () -> Void
        let zoomReset: () -> Void
        let toggleDarkMode: () -> Void
        let toggleAutoPlay: () -> Void
        let editFont: () -> Void
        let manageBlocked: () -> Void
        let clearOverrides: () -> Void
        /// 站点动作栏（v0.8.1）：读文章 / 盯这一页 / 录制工作流。
        let toggleReader: () -> Void
        let watchPage: () -> Void
        let recordWorkflow: () -> Void
    }

    let host: String
    @ObservedObject var store: SiteSettingsStore
    /// 站点动作栏的状态观察：已盯页面 + 是否正在录制。
    @ObservedObject private var pageWatches = PageWatchStore.shared
    @ObservedObject private var workflows = WorkflowStore.shared
    /// 本站广告拦截计数（视频广告规则 + 首击防护，锁弹层只读展示）。
    @ObservedObject private var adStats = AdBlockStatsStore.shared
    /// 站点级 Agent 偏好（v0.8.25）：允许自动操作 / 需要确认 / 始终隔离。
    /// 面板例外：直接观察 store（与 SiteSettingsStore 同规）。
    @ObservedObject private var agentPrefs = SiteAgentPreferenceStore.shared
    /// 全局自动播放档（视频平台默认豁免的解析基准）。
    let globalAutoPlay: AutoPlayPolicy
    /// 当前页缩放（Tab.applyPageZoom 的真实值，1.0 = 100%）。
    let pageZoom: Double
    /// 本站元素拦截规则数（父视图按 host 派生）。
    let blockedCount: Int
    /// 当前页 URL / 阅读模式状态（站点动作栏用）。
    let currentURL: String?
    let isReaderActive: Bool
    let actions: Actions

    @Environment(\.appAccent) private var appAccent: Color

    private var font: SiteFont { store.effectiveFont(for: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Site Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // 缩放
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Zoom")
                    .font(.system(size: 12.5))
                Spacer()
                Button("Zoom Out", systemImage: "minus") { actions.zoomOut() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                Text("\(Int((pageZoom * 100).rounded()))%")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 44)
                    .onTapGesture { actions.zoomReset() }
                    .help("Reset to 100%")
                Button("Zoom In", systemImage: "plus") { actions.zoomIn() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }

            // 暗色 / 自动播放
            HStack(spacing: 8) {
                Image(systemName: "moon.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Dark Mode")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.darkModeEnabled(for: host) },
                    set: { _ in actions.toggleDarkMode() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Auto-Play")
                    .font(.system(size: 12.5))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.isAutoPlayAllowed(for: host, global: globalAutoPlay) },
                    set: { _ in actions.toggleAutoPlay() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            // 站点动作栏（v0.8.1）：阅读 / 盯页 / 录制——把“针对本站做一件事”
            // 的入口集中到同一个弹层，而不是散落在菜单里。
            Divider()
            Text("Site Actions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            siteActionRow(
                icon: "doc.richtext",
                title: "Reader Mode",
                value: isReaderActive ? "On" : "Off",
                action: actions.toggleReader)
            siteActionRow(
                icon: "eye",
                title: "Watch This Page",
                value: currentURL == nil ? "—" : (isWatched ? "Watching" : "every 30 min"),
                enabled: currentURL != nil && !isWatched,
                action: actions.watchPage)
            siteActionRow(
                icon: "record.circle",
                title: "Record Workflow",
                value: workflows.isRecording && workflows.recordingHost == host ? "Recording…" : "",
                enabled: currentURL != nil && !workflows.isRecording,
                action: actions.recordWorkflow)

            // Agent on this site（v0.8.25）：与审批策略（工具 × 站点）互补的
            // 整体姿态。开关写 SiteAgentPreferenceStore，执行侧在审批闸里读取。
            Divider()
            Text("Agent on This Site")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            agentToggle("bolt.circle", "Auto-Operate",
                        help: "Let the agent run state-changing actions here without asking (dangerous actions still ask)",
                        isOn: Binding(
                            get: { agentPrefs.preference(for: host)?.autoOperate ?? false },
                            set: { agentPrefs.update(host: host, autoOperate: $0) }))
            agentToggle("hand.raised.circle", "Require Confirmation",
                        help: "Always ask before the agent acts on this site (overrides auto-operate and other auto-allow rules)",
                        isOn: Binding(
                            get: { agentPrefs.preference(for: host)?.requireConfirmation ?? false },
                            set: { agentPrefs.update(host: host, requireConfirmation: $0) }))
            agentToggle("shippingbox", "Always Isolate",
                        help: "New tabs the agent opens for this site use an isolated container",
                        isOn: Binding(
                            get: { agentPrefs.preference(for: host)?.alwaysIsolate ?? false },
                            set: { agentPrefs.update(host: host, alwaysIsolate: $0) }))

            // 字体（摘要行 → 打开既有站点字体弹层）
            Button {
                actions.editFont()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Page Font")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(fontSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 本站广告拦截（计数 = 该站视频广告 + 首击防护的累计值）
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Ads Blocked Here")
                    .font(.system(size: 12.5))
                Spacer()
                Text("\(adStats.count(forHost: host))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .help(String(format: String(localized: "All-time video-ad blocks recorded for this site: %lld"), adStats.count(forHost: host)))

            // 元素拦截
            Button {
                actions.manageBlocked()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Blocked Elements")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("\(blockedCount)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            Button("Clear Site Overrides") { actions.clearOverrides() }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
        }
    }

    private func agentToggle(_ icon: String, _ title: String, help: String,
                             isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .help(help)
    }

    private var fontSummary: String {
        var parts: [String] = []
        parts.append(font.minFontSize > 0 ? "\(font.minFontSize) px" : String(localized: "Off"))
        if !font.fontFamily.isEmpty { parts.append(font.fontFamily) }
        return parts.joined(separator: " · ")
    }

    private var isWatched: Bool {
        guard let currentURL else { return false }
        return pageWatches.watches.contains { $0.url == currentURL }
    }

    private func siteActionRow(icon: String, title: String, value: String,
                               enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer()
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
