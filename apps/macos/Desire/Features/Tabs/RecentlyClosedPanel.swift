import SwiftUI

/// 最近关闭标签面板（v0.8.11 标签快照恢复）：⌘⇧T 只能逐条回放，这里把
/// 队列整体列出（新→旧），逐条点恢复（含无痕/容器身份保留）。
struct RecentlyClosedPanel: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject private var settings: Settings
    private let contentBlocker: ContentBlockerStore?
    private let videoAdBlocker: VideoAdBlocker?
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss

    init(tabManager: TabManager, settings: Settings,
         contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker?) {
        self.tabManager = tabManager
        self.settings = settings
        self.contentBlocker = contentBlocker
        self.videoAdBlocker = videoAdBlocker
    }

    private var records: [TabManager.RecentlyClosedTab] {
        tabManager.recentlyClosedSnapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(appAccent)
                Text("Recently Closed Tabs")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            Divider()

            if records.isEmpty {
                Text("No recently closed tabs in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            row(record)
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    private func row(_ record: TabManager.RecentlyClosedTab) -> some View {
        Button {
            tabManager.reopen(
                record: record,
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker)
        } label: {
            HStack(spacing: 8) {
                FaviconView(urlString: record.url, size: 14)
                Text(record.url)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if record.isIncognito {
                    Text("Private")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 0)
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
