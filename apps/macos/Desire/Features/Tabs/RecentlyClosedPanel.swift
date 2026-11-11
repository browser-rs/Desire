import SwiftUI

/// 最近关闭标签面板（v0.8.40 扩展）：跨窗口、跨启动的关闭历史，
/// 可搜索、可逐条恢复；⌘⇧T 仍回放当前窗口的最后一条。
struct RecentlyClosedPanel: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var settings: Settings
    @ObservedObject private var store = RecentlyClosedStore.shared
    /// 整窗快照（v0.8.52 批 2）：关闭的窗口可整窗重开。
    @ObservedObject private var windowsStore = ClosedWindowStore.shared
    private let contentBlocker: ContentBlockerStore?
    private let videoAdBlocker: VideoAdBlocker?
    /// 整窗重开回调（由 ContentView 提供 openWindow 环境）。
    private let onOpenClosedWindow: ((ClosedWindow) -> Void)?
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(tabManager: TabManager, settings: Settings,
         contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker?,
         onOpenClosedWindow: ((ClosedWindow) -> Void)? = nil) {
        self.tabManager = tabManager
        self.settings = settings
        self.contentBlocker = contentBlocker
        self.videoAdBlocker = videoAdBlocker
        self.onOpenClosedWindow = onOpenClosedWindow
    }

    private var records: [RecentlyClosedEntry] {
        store.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(appAccent)
                Text("Recently Closed")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(store.entries.count + windowsStore.windows.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if !store.entries.isEmpty || !windowsStore.windows.isEmpty {
                    Button(String(localized: "Clear")) {
                        store.clear()
                        windowsStore.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            TextField(String(localized: "Search closed tabs…"), text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()

            if query.isEmpty, !windowsStore.windows.isEmpty {
                windowsSection
                Divider()
            }

            if records.isEmpty {
                Text(store.entries.isEmpty
                     ? String(localized: "No recently closed tabs yet")
                     : String(localized: "No matches"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 560)
    }

    /// 关闭窗口分段（整窗重开）：标题 + 行内恢复/删除。
    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(appAccent)
                Text("Windows")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(windowsStore.windows.prefix(6)) { closed in
                windowRow(closed)
            }
        }
        .padding(.bottom, 6)
    }

    private func windowRow(_ closed: ClosedWindow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(closed.displayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text("\(closed.tabCount) tab(s)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(closed.closedAt, style: .relative)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Button {
                onOpenClosedWindow?(closed)
                dismiss()
            } label: {
                Text(String(localized: "Restore"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(onOpenClosedWindow == nil)
            Button {
                windowsStore.remove(closed.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func row(_ record: RecentlyClosedEntry) -> some View {
        Button {
            tabManager.reopen(
                record: TabManager.RecentlyClosedTab(
                    url: record.url,
                    isIncognito: record.isIncognito,
                    containerID: record.containerID),
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker)
            store.remove(record.id)
        } label: {
            HStack(spacing: 8) {
                FaviconView(urlString: record.url, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(record.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if record.isIncognito {
                    Text("Private")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(record.closedAt, style: .relative)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(appAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
