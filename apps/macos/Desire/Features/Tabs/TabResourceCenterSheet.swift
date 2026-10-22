import SwiftUI
import WebKit

/// 标签资源中心（v0.8.1）：按站点汇总当前窗口的标签，识别重复页面，提供
/// 可行动的批量操作（挂起后台 / 关闭重复 / 按站关闭）。
///
/// WebKit 不公开每标签内存，所以面板不展示假的“占用 XX MB”——只展示真实
/// 可观察的状态（挂起、播放音频、固定、分组、重复）与能真正降低占用的操作。
struct TabResourceCenterSheet: View {
    @ObservedObject var manager: TabManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    @State private var confirmsCloseDuplicates = false
    @State private var hostToClose: String?

    private var items: [TabResourceItem] {
        manager.tabs.map { tab in
            let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
            return TabResourceItem(
                id: tab.id, url: url, title: tab.displayTitle,
                host: URL(string: url)?.host?.lowercased() ?? "",
                isSuspended: tab.isSuspended,
                isPinned: tab.isPinned,
                isIncognito: tab.isIncognito,
                isPlayingAudio: tab.browser.isPlayingAudio,
                groupName: AppState.live?.tabGroupStore.group(for: tab.id)?.name)
        }
    }

    private var duplicates: [TabResourcePlan.DuplicateGroup] {
        TabResourcePlan.duplicates(items)
    }

    private var hosts: [TabResourcePlan.HostRow] {
        TabResourcePlan.hostRows(items)
    }

    private var suspendedCount: Int { items.filter(\.isSuspended).count }
    private var playingCount: Int { items.filter(\.isPlayingAudio).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                Button(String(localized: "Suspend Background Tabs")) {
                    manager.suspendAllBackgroundTabs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manager.tabs.count <= 1)
                Button(String(localized: "Close Duplicates")) {
                    confirmsCloseDuplicates = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(duplicates.isEmpty)
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !duplicates.isEmpty {
                        sectionTitle(String(localized: "Duplicate pages"))
                        VStack(spacing: 0) {
                            ForEach(Array(duplicates.enumerated()), id: \.offset) { _, group in
                                duplicateRow(group)
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    sectionTitle(String(localized: "By site"))
                    VStack(spacing: 0) {
                        ForEach(hosts, id: \.host) { row in
                            hostRow(row)
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
            Text(String(localized: "Memory use per tab isn't exposed by WebKit. Suspending a tab frees its live page while keeping a restorable snapshot; pinned, incognito, split-pane and the current tab are never suspended."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .alert(String(localized: "Close extra copies?"), isPresented: $confirmsCloseDuplicates) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Close Extras"), role: .destructive) {
                closeDuplicates()
            }
        } message: {
            Text(String(localized: "Keeps one copy of each duplicated page (the selected tab when it's part of the group)."))
        }
        .alert(String(localized: "Close all tabs from \(hostToClose ?? "")?"),
               isPresented: Binding(
                get: { hostToClose != nil },
                set: { if !$0 { hostToClose = nil } })) {
            Button(String(localized: "Cancel"), role: .cancel) { hostToClose = nil }
            Button(String(localized: "Close All"), role: .destructive) {
                if let host = hostToClose { closeHost(host) }
                hostToClose = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tab Resources")
                    .font(.system(size: 16, weight: .semibold))
                Text(String(localized: "\(manager.tabs.count) tabs · \(suspendedCount) suspended · \(playingCount) playing audio · \(duplicates.count) duplicate group(s)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 18))
                .foregroundStyle(appAccent)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func duplicateRow(_ group: TabResourcePlan.DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayURL)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(localized: "\(group.tabIDs.count) copies"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Close Extras")) {
                closes(group, keepingSelected: true)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func hostRow(_ row: TabResourcePlan.HostRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.playingAudio > 0 ? "speaker.wave.2.fill" : "globe")
                .foregroundStyle(row.playingAudio > 0 ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.host)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(row.count) tabs · \(row.suspended) suspended"
                     + (row.playingAudio > 0 ? " · \(row.playingAudio) audio" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Close All")) {
                hostToClose = row.host
            }
            .controlSize(.small)
            .disabled(row.count >= manager.tabs.count)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func closeDuplicates() {
        for group in duplicates {
            closes(group, keepingSelected: true)
        }
    }

    private func closes(_ group: TabResourcePlan.DuplicateGroup,
                        keepingSelected: Bool) {
        let selected = manager.selectedTab?.id
        let keep: UUID
        if keepingSelected, let selected, group.tabIDs.contains(selected) {
            keep = selected
        } else {
            keep = group.tabIDs[0]
        }
        let toClose = group.tabIDs.filter { $0 != keep }
        close(ids: toClose)
    }

    private func closeHost(_ host: String) {
        guard let row = hosts.first(where: { $0.host == host }) else { return }
        // 保留当前标签，避免一次操作把窗口关掉或让用户失去锚点。
        let selected = manager.selectedTab?.id
        let ids = row.tabIDs.filter { $0 != selected }
        close(ids: ids)
    }

    private func close(ids: [UUID]) {
        let indexes = ids.compactMap { id in
            manager.tabs.firstIndex(where: { $0.id == id })
        }.sorted(by: >)
        for index in indexes where manager.tabs.count > 1 {
            manager.closeTab(at: index)
        }
    }
}
