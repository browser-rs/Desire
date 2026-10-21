import SwiftUI

/// 活动中心面板（v0.7.29）：「现在在跑什么」——下载/批量媒体/导出/定时任务/
/// 运行中的 Agent 与 crew。每 3 秒刷新一次；纯构建与桥同源。
struct ActivityPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    var onClose: () -> Void

    @State private var items: [ActivityCenter.Item] = []
    @State private var filter: ActivityCenter.Kind?

    private var visible: [ActivityCenter.Item] {
        guard let filter else { return items }
        return items.filter { $0.kind == filter }
    }
    private var activeItems: [ActivityCenter.Item] { visible.filter(\.active) }
    private var recentItems: [ActivityCenter.Item] { visible.filter { !$0.active } }
    private var presentKinds: [ActivityCenter.Kind] {
        ActivityCenter.Kind.allCases.filter { kind in items.contains { $0.kind == kind } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !presentKinds.isEmpty {
                filterBar
                Divider()
            }
            if items.isEmpty {
                empty
            } else if visible.isEmpty {
                emptyFilter
            } else {
                List {
                    if !activeItems.isEmpty {
                        Section(String(localized: "Running")) {
                            ForEach(activeItems) { row($0) }
                        }
                    }
                    if !recentItems.isEmpty {
                        Section(String(localized: "Recent")) {
                            ForEach(recentItems) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 520)
        .task { await refreshLoop() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(appAccent)
            Text("Activity")
                .font(.system(size: 13, weight: .semibold))
            Text("\(items.filter(\.active).count)/\(items.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                items = ActivityCenter.build(ActivityCenterCollector.liveInputs())
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button("Close", action: onClose)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(nil, label: String(localized: "All"), count: items.count)
                ForEach(presentKinds, id: \.self) { kind in
                    filterChip(kind, label: kind.title,
                               count: items.filter { $0.kind == kind }.count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func filterChip(_ kind: ActivityCenter.Kind?, label: String, count: Int) -> some View {
        let active = filter == kind
        return Button {
            filter = kind
        } label: {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 10, weight: .medium))
                Text("\(count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? appAccent.opacity(0.12) : Color.clear))
            .overlay(Capsule().stroke(active ? appAccent.opacity(0.35) : Color.secondary.opacity(0.25),
                                      lineWidth: 0.7))
            .foregroundStyle(active ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: ActivityCenter.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(item.active ? appAccent : .secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let progress = item.progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.active ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                Text(relative(item.timestamp))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Nothing running")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Downloads, batch media, exports and agent work show up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFilter: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No activity in this category")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button(String(localized: "Show all")) { filter = nil }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(appAccent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            items = ActivityCenter.build(ActivityCenterCollector.liveInputs())
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
