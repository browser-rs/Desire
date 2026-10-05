import SwiftUI

/// DevTools「DPP」页签（0.6.7）：当前页 Desire 协议声明的只读检查器——
/// 声明树（views 逐字段选择器 / actions 的 effects·danger 标注 / events /
/// warnings）+ 已派发事件流（PageEventHub 环形历史）。
struct DPPInspectorPanel: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var eventHub = PageEventHub.shared
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        if let dpp = tab.browser.effectiveProtocol {
            content(dpp)
        } else {
            undeclared
        }
    }

    private var undeclared: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No DPP declaration on this page")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pages declare views/actions/events via DPP (L1-L3). See desire.mankong.icu — demo hall has live examples.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ dpp: DesireProtocol) -> some View {
        List {
            declarationSection(dpp)
            if !dpp.views.isEmpty { viewsSection(dpp.views) }
            if !dpp.actions.isEmpty { actionsSection(dpp.actions) }
            if !dpp.events.isEmpty { eventsSection(dpp.events) }
            firedEventsSection
            if !dpp.warnings.isEmpty { warningsSection(dpp.warnings) }
        }
        .listStyle(.inset)
    }

    // MARK: - 声明段

    private func declarationSection(_ dpp: DesireProtocol) -> some View {
        Section("Declaration") {
            row("Profile", dpp.profile)
            row("Page type", dpp.pageType)
            row("Content main", dpp.contentMain)
            ForEach(Array(dpp.sections.keys).sorted(), id: \.self) { key in
                row("Section: \(key)", dpp.sections[key])
            }
            ForEach(Array(dpp.ignore).sorted(), id: \.self) { sel in
                row("Ignore", sel)
            }
        }
    }

    // MARK: - Views

    private func viewsSection(_ views: [String: DesireProtocol.ProtocolView]) -> some View {
        // 显式中间数组：Dictionary.sorted 的元组 + 条件解包在 List 内会触发
        // ForEach 推断爆炸（Binding<C> 误选），先物化成具名元组数组。
        let rows: [(name: String, view: DesireProtocol.ProtocolView)] =
            views.keys.sorted().compactMap { name in views[name].map { (name, $0) } }
        return Section("Views (\(rows.count))") {
            ForEach(rows, id: \.name) { row in
                DisclosureGroup {
                    ForEach(fieldRows(row.view.fields), id: \.key) { fr in
                        row2(fr.key, fr.value)
                    }
                } label: {
                    Text(row.name).font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    /// 字段行物化（ViewBuilder 内 for 循环在此 WebKit/Swift 组合下受限时的
    /// 规避——数据先成具名元组数组再 ForEach）。
    private func fieldRows(_ fields: [String: DesireProtocol.FieldSpec]) -> [(key: String, value: String)] {
        fields.keys.sorted().compactMap { key in
            fields[key].map { (key, fieldText($0)) }
        }
    }

    private func row2(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func actionsSection(_ actions: [DesireProtocol.ProtocolAction]) -> some View {
        Section("Actions (\(actions.count))") {
            ForEach(actions, id: \.name) { action in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(action.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if action.danger == true {
                            tag("danger", .red)
                        }
                        if action.effects == "outbound" {
                            tag("outbound", .orange)
                        }
                    }
                    if let run = action.run, !run.isEmpty {
                        Text(run)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Events

    private func eventsSection(_ events: [String: String]) -> some View {
        Section("Events (\(events.count))") {
            ForEach(events.keys.sorted(), id: \.self) { name in
                row(name, events[name])
            }
        }
    }

    // MARK: - 已派发事件流

    private var firedEventsSection: some View {
        Section("Fired events (latest \(eventHub.firedEvents.count))") {
            if eventHub.firedEvents.isEmpty {
                Text("No events yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(eventHub.firedEvents) { ev in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ev.host).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(ev.at, style: .time).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(ev.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        if !ev.detail.isEmpty {
                            Text(ev.detail.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Warnings

    private func warningsSection(_ warnings: [String]) -> some View {
        Section("Parse warnings") {
            ForEach(warnings, id: \.self) { w in
                Text(w).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func fieldText(_ spec: DesireProtocol.FieldSpec?) -> String {
        guard let spec else { return "" }
        if let type = spec.type { return "\(spec.expression) (\(type))" }
        return spec.expression
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
