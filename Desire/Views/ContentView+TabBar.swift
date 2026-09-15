import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension ContentView {
    /// Tab strip. Extracted from `body` (L1-1) to keep `body` scannable.
    /// Pure view slice — no state or logic moved, closures retained verbatim.
    @ViewBuilder
    func tabBarSection(for tab: Tab) -> some View {
        TabBar(
            tabs: tabManager.tabs,
            selectedIndex: tabManager.selectedIndex,
            isFullScreen: isFullScreen,
            showSwitcher: showTabSwitcher,
            onSelectTab: { index in
                isUrlFocused = false
                tabManager.selectTab(at: index)
                showTabSwitcher = false
                // 更新选中标签页的缩略图
                thumbnailStore.updateSelectedTabThumbnail(tabManager.selectedTab)
            },
            onCloseTab: { index in
                // 清除关闭标签页的缩略图缓存
                let tabId = tabManager.tabs[index].id
                thumbnailStore.clearThumbnail(for: tabId)
                tabManager.closeTab(at: index)
            },
            onAddTab: {
                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
                showTabSwitcher = false
            },
            containers: containerStore.containers,
            onAddTabInContainer: { container in
                tabManager.addTab(
                    javaScriptEnabled: settings.isJavaScriptEnabled,
                    contentBlocker: contentBlocker,
                    videoAdBlocker: videoAdBlocker,
                    newTabPosition: settings.newTabPosition,
                    containerID: container.id
                )
            },
            onMoveTab: { tabManager.moveTab(from: $0, to: $1) },
            onReloadTab: { $0.browser.webView.reload() },
            onCopyTabURL: { tab in
                if let url = tab.browser.webView.url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            },
            onCloseOtherTabs: { index in
                // 清除其他标签页的缩略图缓存
                let keptId = tabManager.tabs[index].id
                for tab in tabManager.tabs where tab.id != keptId {
                    thumbnailStore.clearThumbnail(for: tab.id)
                }
                tabManager.closeOthers(keeping: index)
            },
            onCloseTabsToRight: { index in
                // 清除右侧标签页的缩略图缓存
                for i in (index + 1..<tabManager.tabs.count) {
                    thumbnailStore.clearThumbnail(for: tabManager.tabs[i].id)
                }
                tabManager.closeToTheRight(of: index)
            },
            onToggleAudioMute: { index in
                // 使用 Tab 的 audioMuted 属性
                tabManager.tabs[index].audioMuted.toggle()
            },
            onTogglePin: { index in
                tabManager.tabs[index].isPinned.toggle()
            },
            // Derived from TabGroupStore — TabBar no longer holds the store.
            tabGroupColor: { [gColors = [Color.red, .orange, .yellow, .green, .blue, .purple, .pink, .brown]] tabId in
                tabGroupStore.group(for: tabId).map { gColors[$0.colorIndex % gColors.count] }
            },
            containerFor: { containerStore.container(for: $0) },
            tabGroups: tabGroupStore.groups,
            onRemoveFromGroup: { tabGroupStore.removeTabFromAll($0) },
            onAddToGroup: { tabId, groupId in tabGroupStore.addTab(tabId, to: groupId) },
            // Derived from TabThumbnailStore — TabBar no longer holds the store.
            tabThumbnail: { thumbnailStore.thumbnail(for: $0) },
            onCaptureThumbnail: { thumbnailStore.captureThumbnail(for: $0) },
            onCreateGroup: { index in
                let alert = NSAlert()
                alert.messageText = String(localized: "New Tab Group")
                alert.informativeText = String(localized: "Enter group name")
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
                alert.accessoryView = tf
                alert.addButton(withTitle: String(localized: "Create"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        let group = tabGroupStore.create(name: name)
                        let tabId = tabManager.tabs[index].id
                        tabGroupStore.addTab(tabId, to: group.id)
                    }
                }
            },
            onDuplicateTab: { index in
                tabManager.duplicateTab(at: index, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy)
            }
        )
    }
}
