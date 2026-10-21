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
    }

    let host: String
    @ObservedObject var store: SiteSettingsStore
    /// 全局自动播放档（视频平台默认豁免的解析基准）。
    let globalAutoPlay: AutoPlayPolicy
    /// 当前页缩放（Tab.applyPageZoom 的真实值，1.0 = 100%）。
    let pageZoom: Double
    /// 本站元素拦截规则数（父视图按 host 派生）。
    let blockedCount: Int
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

    private var fontSummary: String {
        var parts: [String] = []
        parts.append(font.minFontSize > 0 ? "\(font.minFontSize) px" : String(localized: "Off"))
        if !font.fontFamily.isEmpty { parts.append(font.fontFamily) }
        return parts.joined(separator: " · ")
    }
}
