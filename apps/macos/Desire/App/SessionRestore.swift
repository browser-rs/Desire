import AppKit
import Foundation

/// 首窗口的**会话恢复编排**（从 ContentView.onAppear 抽出——组合根只该拼装
/// 视图，不该编排恢复流程；ARCH-8）。
///
/// 流程（与原实现逐语义一致）：
/// 1. 窗口绑定持久会话身份（UUID → sessionKey）；
/// 2. 拖出接纳：本窗口由"标签拖出"创建时直接吸收暂存标签；
/// 3. 本窗口自己的会话文件存在 → 恢复它；
/// 4. 首窗口且尚无恢复：采纳 index 里最近的会话（macOS 26 不写 SwiftUI
///    的 Saved Application State，窗口 UUID 每次启动全新——不采纳则每次
///    启动都白屏）；异常终止后恢复时回调通知 UI 提示"已恢复到最后写入"；
/// 5. 都没有 → 清孤儿会话（归档）、尝试 legacy 一次性接纳、兜底开新标签。
@MainActor
enum SessionRestore {

    struct Result {
        let sessionID: UUID
        let sessionKey: String
    }

    struct Context {
        let tabManager: TabManager
        let appState: AppState
        let settings: Settings
        let contentBlocker: ContentBlockerStore?
        let videoAdBlocker: VideoAdBlocker?
        /// 会话身份绑定（SwiftUI @Binding 的直写由调用方完成，这里传出新 id）。
        let existingSessionID: UUID?
        /// 启动提示（UI 回调——View 层渲染 toast）。文案在此拼好：
        /// 崩溃恢复（带标签数）或"异常退出但按启动设置打开"两种。
        let onStartupNotice: ((String) -> Void)?
        /// 打开新标签（走 BrowsingActions，保持与新标签页语义一致）。
        let openFreshTab: () -> Void
        /// 按启动设置打开一组 URL（主页/指定页集）；多条时都开。
        let openStartupURLs: (([String]) -> Void)?
        /// 崩溃后补开其他窗口（v0.8.0 多窗口恢复）：由 ContentView 的
        /// `openWindow(id:"main", value: UUID())` 提供；nil = 不补开。
        let openWindowForRestore: (() -> Void)?
    }

    /// 执行恢复。返回窗口应绑定的会话 UUID（可能因采纳而改变）。
    @discardableResult
    static func run(for manager: TabManager, context: Context) -> Result? {
        let sessionID = context.existingSessionID ?? UUID()
        let sessionKey = TabSessionCoordinator.shared.sessionKey(for: sessionID)
        manager.sessionKey = sessionKey

        // v0.8.23：建窗时携带的角色（混合模式由模式切换/桥发起）。
        if let role = WindowRoleRegistry.shared.pendingRole {
            WindowRoleRegistry.shared.pendingRole = nil
            if role == .agent {
                let containerID = AppModeStore.shared.agentSharesUserProfile
                    ? nil
                    : WindowRoleRegistry.shared.agentContainerID()
                manager.defaultContainerID = containerID
                let agentKey = WindowRoleRegistry.shared.agentSessionKey() ?? sessionKey
                manager.sessionKey = agentKey
                if let session = TabSessionCoordinator.shared.session(forKey: agentKey),
                   !session.tabs.isEmpty {
                    manager.apply(session: session,
                                  javaScriptEnabled: context.settings.isJavaScriptEnabled,
                                  contentBlocker: context.contentBlocker,
                                  videoAdBlocker: context.videoAdBlocker)
                } else {
                    manager.addTab(javaScriptEnabled: context.settings.isJavaScriptEnabled,
                                   contentBlocker: context.contentBlocker,
                                   videoAdBlocker: context.videoAdBlocker,
                                   makeActive: true)
                }
                WindowRoleRegistry.shared.register(sessionKey: agentKey, role: .agent,
                                                   containerID: containerID)
                return Result(sessionID: sessionID, sessionKey: agentKey)
            }
            WindowRoleRegistry.shared.register(sessionKey: sessionKey, role: .user)
        }

        // 拖出接纳：暂存区的标签直接吸收，不走会话恢复/新建流程。
        if let staged = TabTransfer.take(for: sessionID) {
            manager.absorb(staged)
            return Result(sessionID: sessionID, sessionKey: sessionKey)
        }

        // 崩溃多窗口恢复：首窗在下面把其余 live key 入队，随后补开的每个
        // 新窗口在这里认领自己的那一份，而不是开成空白新标签。
        if let pendingKey = TabSessionCoordinator.shared.takePendingRestoreKey(),
           let session = TabSessionCoordinator.shared.session(forKey: pendingKey),
           !session.tabs.isEmpty {
            manager.sessionKey = pendingKey
            manager.apply(
                session: session,
                javaScriptEnabled: context.settings.isJavaScriptEnabled,
                contentBlocker: context.contentBlocker,
                videoAdBlocker: context.videoAdBlocker
            )
            return Result(sessionID: sessionID, sessionKey: pendingKey)
        }

        if manager.restoreSession(
            forKey: sessionKey,
            javaScriptEnabled: context.settings.isJavaScriptEnabled,
            contentBlocker: context.contentBlocker,
            videoAdBlocker: context.videoAdBlocker
        ) {
            // This window's own tabs are back.
            restoreAdditionalWindows(excluding: sessionKey, context: context)
            return Result(sessionID: sessionID, sessionKey: sessionKey)
        }

        guard !context.appState.hasRestoredSession else {
            context.openFreshTab()
            return Result(sessionID: sessionID, sessionKey: sessionKey)
        }

        // First window with no own session — adopt the most recent session
        // from the termination index (continue where you left off), unless the
        // user chose a different startup behavior (v0.7.19: home / page set).
        context.appState.hasRestoredSession = true
        let crashed = TabSessionCoordinator.shared.launchedAfterCrash
        if context.settings.startupBehavior == .restoreSession,
           let lastKey = TabSessionCoordinator.shared.mostRecentSessionKey(),
           lastKey != sessionKey,
           let session = TabSessionCoordinator.shared.session(forKey: lastKey),
           !session.tabs.isEmpty {
            // 崩溃回收（0.3.8）：上次异常终止——提示已恢复到崩溃前最后写入的
            // 会话（v0.7.19：带标签数，把"恢复了几扇窗"说清）。
            if crashed {
                context.onStartupNotice?(
                    String(localized: "Restored after an unexpected quit — \(session.tabs.count) tab(s) back"))
            }
            // Re-bind the window to the adopted identity so all future persists
            // land on the same session file.
            manager.sessionKey = lastKey
            manager.apply(
                session: session,
                javaScriptEnabled: context.settings.isJavaScriptEnabled,
                contentBlocker: context.contentBlocker,
                videoAdBlocker: context.videoAdBlocker
            )
            // Deliberately NOT pruning here: consuming the index would leave the
            // next launch with nothing to adopt. This window now persists under
            // `lastKey`, and the next clean quit rewrites the index with it.
            restoreAdditionalWindows(excluding: lastKey, context: context)
            return Result(sessionID: sessionID, sessionKey: lastKey)
        }

        TabSessionCoordinator.shared.pruneOrphanSessions(keeping: [sessionKey])
        if let legacy = TabSessionCoordinator.shared.takeLegacySession() {
            manager.apply(
                session: legacy,
                javaScriptEnabled: context.settings.isJavaScriptEnabled,
                contentBlocker: context.contentBlocker,
                videoAdBlocker: context.videoAdBlocker
            )
            return Result(sessionID: sessionID, sessionKey: sessionKey)
        }
        // 按启动设置开页面：主页 / 指定页集（解析失败即退回新标签页）。
        switch context.settings.startupBehavior {
        case .pageSet:
            let urls = StartupPageSet.urls(from: context.settings.startupPageSet)
            if !urls.isEmpty {
                context.openStartupURLs?(urls)
                if crashed {
                    context.onStartupNotice?(
                        String(localized: "Last quit was unexpected — opened your startup pages"))
                }
                return Result(sessionID: sessionID, sessionKey: sessionKey)
            }
            context.openFreshTab()
        case .homePage:
            let home = context.settings.homePage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !home.isEmpty, let url = URL(string: home),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                context.openStartupURLs?([home])
                if crashed {
                    context.onStartupNotice?(
                        String(localized: "Last quit was unexpected — opened your homepage"))
                }
                return Result(sessionID: sessionID, sessionKey: sessionKey)
            }
            context.openFreshTab()
        case .newTabPage, .restoreSession:
            context.openFreshTab()
        }
        if crashed {
            context.onStartupNotice?(
                String(localized: "Last quit was unexpected — started with a fresh tab"))
        }
        return Result(sessionID: sessionID, sessionKey: sessionKey)
    }

    /// 崩溃后补开其他窗口：首窗已认领一个会话，其余 live key 入队；每开一扇
    /// 新窗，它的 `run` 会在顶部 `takePendingRestoreKey()` 认领一份。
    /// 只在崩溃 + "恢复上次会话"启动设置下动作；最多补开 4 扇（防窗口爆炸）。
    private static func restoreAdditionalWindows(excluding key: String?, context: Context) {
        guard TabSessionCoordinator.shared.launchedAfterCrash,
              context.settings.startupBehavior == .restoreSession,
              context.openWindowForRestore != nil else { return }
        let others = TabSessionCoordinator.shared.crashRestoreSessionKeys(excluding: key)
        guard !others.isEmpty else { return }
        TabSessionCoordinator.shared.enqueueRestoreKeys(others)
        for _ in others {
            context.openWindowForRestore?()
        }
    }
}
