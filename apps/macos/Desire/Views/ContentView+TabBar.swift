import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension ContentView {
    /// 其他用户窗口（标签"移动到窗口"的目标；v0.8.52 批 2）。
    var otherWindowTargets: [OtherWindowTarget] {
        TabSessionCoordinator.shared.liveManagers().compactMap { manager in
            guard manager !== tabManager,
                  let key = manager.sessionKey,
                  WindowRoleRegistry.shared.role(for: key) == .user,
                  let id = TabSessionCoordinator.shared.sessionID(forKey: key) else { return nil }
            let window = WindowSurfaceRegistry.shared.window(for: key)
            guard window?.isVisible != false else { return nil }
            let title = window?.title.isEmpty == false
                ? window?.title ?? ""
                : (manager.selectedTab?.displayTitle ?? "\(manager.tabs.count) tabs")
            return OtherWindowTarget(id: id, title: title)
        }
    }

    /// 跨窗口标签搜索的数据源（v0.8.52 批 2）。
    var externalTabEntries: [ExternalTabEntry] {
        TabSessionCoordinator.shared.liveManagers().flatMap { manager -> [ExternalTabEntry] in
            guard manager !== tabManager,
                  let key = manager.sessionKey,
                  WindowRoleRegistry.shared.role(for: key) == .user,
                  let sid = TabSessionCoordinator.shared.sessionID(forKey: key) else { return [] }
            let window = WindowSurfaceRegistry.shared.window(for: key)
            guard window?.isVisible != false else { return [] }
            let title = window?.title.isEmpty == false
                ? window?.title ?? ""
                : "\(manager.tabs.count) tabs"
            return manager.tabs.map { ExternalTabEntry(sessionID: sid, windowTitle: title, tab: $0) }
        }
    }

    /// 跨窗搜索命中：激活目标窗口并选中该标签。
    func selectExternalTab(sessionID: UUID, tabID: UUID) {
        guard let manager = TabSessionCoordinator.shared.manager(forSession: sessionID),
              let index = manager.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        WindowSurfaceRegistry.shared.window(for: manager.sessionKey)?.makeKeyAndOrderFront(nil)
        manager.selectTab(at: index)
    }

    /// 把标签移到另一扇窗口（与拖拽同一路径：保 history/挂起状态）。
    func moveTabToOtherWindow(_ index: Int, _ target: UUID) {        guard tabManager.tabs.indices.contains(index),
              let targetManager = TabSessionCoordinator.shared.manager(forSession: target),
              targetManager !== tabManager else { return }
        let tab = tabManager.tabs[index]
        tabGroupStore.removeTabFromAll(tab.id)
        tabManager.moveOut(tab)
        targetManager.absorb(tab)
        WindowSurfaceRegistry.shared.window(for: targetManager.sessionKey)?.makeKeyAndOrderFront(nil)
        if tabManager.tabs.isEmpty {
            (WindowSurfaceRegistry.shared.window(for: tabManager.sessionKey)
                ?? tab.browser.webView.window)?.close()
        }
    }

    /// Tab strip. Extracted from `body` (L1-1) to keep `body` scannable.
    /// Pure view slice — no state or logic moved, closures retained verbatim.
    /// 新建组（顶栏与侧栏共用）：TabGroupPrompts 收名 → store 建组并把该
    /// 标签入组。宿主窗口的后台兜底在 TabGroupPrompts 里（此前
    /// keyWindow/mainWindow 皆 nil 时直接 return，提示在后台静默不出现）。
    func createGroupFromTab(_ index: Int) {
        TabGroupPrompts.presentNameSheet(titleKey: "New Tab Group",
                                         initialName: "",
                                         confirmKey: "Create") { name in
            let group = tabGroupStore.create(name: name)
            guard tabManager.tabs.indices.contains(index) else { return }
            tabGroupStore.addTab(tabManager.tabs[index].id, to: group.id)
        }
    }

    @ViewBuilder
    func tabBarSection(for tab: Tab) -> some View {
        TabBar(
            tabs: tabManager.tabs,
            selectedIndex: tabManager.selectedIndex,
            // 红绿灯在窗口全屏时浮在内容上，标签栏的左边距要跟着收。
            isFullScreen: isWindowFullScreen,
            showSwitcher: $showTabSwitcher,
            onSelectTab: { index in
                isUrlFocused = false
                // Selecting a tab that belongs to a collapsed group expands
                // the group first — otherwise the selection would be invisible.
                if tabManager.tabs.indices.contains(index) {
                    let tab = tabManager.tabs[index]
                    if let group = tabGroupStore.group(for: tab.id), group.isCollapsed {
                        tabGroupStore.setCollapsed(group.id, false)
                    }
                }
                tabManager.selectTab(at: index)
                showTabSwitcher = false
                // R2-14：切标签**不再拍快照**——takeSnapshot(afterScreenUpdates:)
                // 是主线程渲染强制 flush，连续切标签 = 连续渲染。预览只在悬停
                // 1s 时需要（TabBar 的 hover 路径会拍），过期缩略图由悬停重拍
                // 自然覆盖。
            },
            onCloseTab: { index in
                // 清除关闭标签页的缩略图缓存
                let tabId = tabManager.tabs[index].id
                thumbnailStore.clearThumbnail(for: tabId)
                tabManager.closeTab(at: index)
            },
            onCloseTabID: { id in
                // Middle-click close: resolve the index live (the monitor's
                // registered closure must not hold stale snapshots). Mirrors
                // the X button's semantics — the last tab stays.
                guard tabManager.tabs.count > 1,
                      let index = tabManager.tabs.firstIndex(where: { $0.id == id }) else { return }
                thumbnailStore.clearThumbnail(for: id)
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
            onCopyPerfSnapshot: { tab in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.perfSnapshotText, forType: .string)
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
            onCloseTabsToLeft: { index in
                // 清除左侧标签页的缩略图缓存
                for i in (0..<index) {
                    thumbnailStore.clearThumbnail(for: tabManager.tabs[i].id)
                }
                tabManager.closeToTheLeft(of: index)
            },
            onCopyAllTabLinks: { markdown in
                // 无痕标签的 URL 不进剪贴板（批量导出不做隐私外泄）。
                let pairs = tabManager.tabs.filter { !$0.isIncognito }.map { tab in
                    (title: tab.displayTitle,
                     url: tab.browser.webView.url?.absoluteString ?? tab.urlString)
                }
                let text = TabLinkList.render(TabLinkList.entries(pairs), markdown: markdown)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onMoveTabToNewWindow: { index in
                guard tabManager.tabs.indices.contains(index) else { return }
                tearOut(tab: tabManager.tabs[index])
            },
            onMoveTabToWindow: { index, target in
                moveTabToOtherWindow(index, target)
            },
            otherWindows: otherWindowTargets,
            externalTabs: externalTabEntries,
            onSelectExternalTab: { sessionID, tabID in
                selectExternalTab(sessionID: sessionID, tabID: tabID)
            },
            onSuspendOtherTabs: {
                tabManager.suspendAllBackgroundTabs()
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
            onToggleGroupCollapse: { tabGroupStore.toggleCollapsed($0) },
            onDeleteGroup: { tabGroupStore.delete($0) },
            onRenameGroup: { id, name in tabGroupStore.rename(id, to: name) },
            groupStore: tabGroupStore,
            onRemoveFromGroup: { tabGroupStore.removeTabFromAll($0) },
            onAddToGroup: { tabId, groupId in tabGroupStore.addTab(tabId, to: groupId) },
            windowSessionID: sessionID?.uuidString ?? "pending-session",
            // Derived from TabThumbnailStore — TabBar no longer holds the store.
            tabThumbnail: { thumbnailStore.thumbnail(for: $0) },
            onCaptureThumbnail: { tab, completion in
                thumbnailStore.captureThumbnail(for: tab, completion: completion)
            },
            onCreateGroup: { index in createGroupFromTab(index) },
            onDuplicateTab: { index in
                tabManager.duplicateTab(at: index, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy)
            },
            splitPartnerIndex: tabManager.splitPartnerIndex,
            onToggleSplit: { index in
                tabManager.toggleSplitPartner(at: index)
            },
            isTabOverviewActive: showTabOverview,
            onToggleTabOverview: {
                showTabOverview.toggle()
            },
            onShowRecentlyClosed: {
                showRecentlyClosed = true
            },
            onDragStarted: { tab in beginTearOutWatch(for: tab) },
            onTransferIn: { sourceSession, tabID, index in
                transferIn(fromSession: sourceSession, tabID: tabID, index: index)
            }
        )
    }
}
