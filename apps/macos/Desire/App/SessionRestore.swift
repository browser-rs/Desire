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

    struct Context {
        let tabManager: TabManager
        let appState: AppState
        let settings: Settings
        let contentBlocker: ContentBlockerStore?
        let videoAdBlocker: VideoAdBlocker?
        /// 会话身份绑定（SwiftUI @Binding 的直写由调用方完成，这里传出新 id）。
        let existingSessionID: UUID?
        /// 崩溃恢复提示（UI 回调——View 层渲染 toast）。
        let onCrashRestoreNotice: (() -> Void)?
        /// 打开新标签（走 BrowsingActions，保持与新标签页语义一致）。
        let openFreshTab: () -> Void
    }

    /// 执行恢复。返回窗口应绑定的会话 UUID（可能因采纳而改变）。
    @discardableResult
    static func run(for manager: TabManager, context: Context) -> UUID? {
        let sessionID = context.existingSessionID ?? UUID()
        let sessionKey = TabSessionCoordinator.shared.sessionKey(for: sessionID)
        manager.sessionKey = sessionKey

        // 拖出接纳：暂存区的标签直接吸收，不走会话恢复/新建流程。
        if let staged = TabTransfer.take(for: sessionID) {
            manager.absorb(staged)
            return sessionID
        }

        if manager.restoreSession(
            forKey: sessionKey,
            javaScriptEnabled: context.settings.isJavaScriptEnabled,
            contentBlocker: context.contentBlocker,
            videoAdBlocker: context.videoAdBlocker
        ) {
            // This window's own tabs are back.
            return sessionID
        }

        guard !context.appState.hasRestoredSession else {
            context.openFreshTab()
            return sessionID
        }

        // First window with no own session — adopt the most recent session
        // from the termination index (continue where you left off).
        context.appState.hasRestoredSession = true
        guard context.settings.startupBehavior == .restoreSession,
              let lastKey = TabSessionCoordinator.shared.mostRecentSessionKey(),
              lastKey != sessionKey,
              let session = TabSessionCoordinator.shared.session(forKey: lastKey),
              !session.tabs.isEmpty else {
            TabSessionCoordinator.shared.pruneOrphanSessions(keeping: [sessionKey])
            if let legacy = TabSessionCoordinator.shared.takeLegacySession() {
                manager.apply(
                    session: legacy,
                    javaScriptEnabled: context.settings.isJavaScriptEnabled,
                    contentBlocker: context.contentBlocker,
                    videoAdBlocker: context.videoAdBlocker
                )
            } else {
                context.openFreshTab()
            }
            return sessionID
        }

        // 崩溃回收（0.3.8）：上次异常终止——提示用户已恢复到崩溃前最后
        // 写入的会话（非上次干净退出时的）。
        if TabSessionCoordinator.shared.launchedAfterCrash {
            context.onCrashRestoreNotice?()
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
        return sessionID
    }
}
