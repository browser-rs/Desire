import Combine
import Foundation
import WebKit

/// 一次"需要用户看一眼/动一下"的请求（v0.8.23）。
nonisolated struct PeekRequest: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case pending, visible, resolved, dismissed
    }

    var id: UUID
    var reason: String
    var needsPage: Bool
    var createdAt: Date
    var status: Status
}

/// 接管锁（v0.8.23）：用户在用某个浏览面（专注模式的面板）时，Agent 的
/// 工具必须让路——目标解析命中锁就返回明确的 `Error:`，不静默失败。
@MainActor
final class SurfaceLock: ObservableObject {
    static let shared = SurfaceLock()

    @Published private(set) var locked: Set<ObjectIdentifier> = []
    private var reasons: [ObjectIdentifier: String] = [:]
    /// 标签级锁（v0.8.25）：用户接管某一页时，同窗其他标签仍可被 Agent 操作。
    private var lockedTabs: [ObjectIdentifier: String] = [:]
    var tabLockCount: Int { lockedTabs.count }

    private init() {}

    func lock(_ manager: TabManager, reason: String) {
        locked.insert(ObjectIdentifier(manager))
        reasons[ObjectIdentifier(manager)] = reason
    }

    func unlock(_ manager: TabManager) {
        locked.remove(ObjectIdentifier(manager))
        reasons[ObjectIdentifier(manager)] = nil
    }

    func reason(for manager: TabManager) -> String? {
        reasons[ObjectIdentifier(manager)]
    }

    func isLocked(_ manager: TabManager) -> Bool {
        locked.contains(ObjectIdentifier(manager))
    }

    func lock(tab: Tab, reason: String) {
        lockedTabs[ObjectIdentifier(tab)] = reason
    }

    func unlock(tab: Tab) {
        lockedTabs[ObjectIdentifier(tab)] = nil
    }

    func reason(for tab: Tab) -> String? {
        lockedTabs[ObjectIdentifier(tab)]
    }
}

/// Peek 协议（v0.8.23）：Agent 请求用户处理（登录/验证码/看一眼），
/// 用户完成后把"页面是否变化"写成系统备注交还给 Agent。
///
/// 呈现按模式分：专注模式 = 工作台面板就地展开（并加接管锁）；
/// 混合/浏览器模式 = 系统通知 + 面板徽标，点开才展开。
@MainActor
final class PeekCenter: ObservableObject {
    static let shared = PeekCenter()

    @Published private(set) var active: PeekRequest?
    @Published private(set) var lastResolution: String?
    /// Peek 的目标浏览面（展开时锁定；完成时对比前后状态）。
    private(set) var targetManager: TabManager?
    /// Peek 接管的具体标签（标签级锁）。
    private var targetTab: Tab?
    /// 用户开始处理前的页面快照（URL）。
    private var beforeSnapshot: String?

    private init() {}

    @discardableResult
    func request(reason: String, needsPage: Bool = true) -> PeekRequest {
        let request = PeekRequest(id: UUID(), reason: reason, needsPage: needsPage,
                                  createdAt: Date(), status: .pending)
        active = request
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Agent needs you"),
            body: reason,
            tier: .urgent)
        return request
    }

    /// 审批"看现场"（v0.8.23）：只把页面亮出来，不额外发通知（审批本身
    /// 已经是用户在场的动作）。
    func showForApproval(reason: String) {
        if active == nil {
            active = PeekRequest(id: UUID(), reason: reason, needsPage: true,
                                 createdAt: Date(), status: .pending)
        }
        present()
    }

    /// 展开：锁定目标浏览面（用户接管期间 Agent 工具让路）；混合模式弹
    /// 非激活浮层（不抢用户焦点）。
    func present() {
        guard var request = active else { return }
        request.status = .visible
        active = request
        let manager = Self.surfaceManager()
        targetManager = manager
        if let manager {
            beforeSnapshot = Self.snapshot(manager)
            // 标签级锁：用户接管这一页，同窗其他标签仍可被 Agent 使用。
            targetTab = manager.selectedTab
            if let tab = targetTab {
                SurfaceLock.shared.lock(tab: tab, reason: request.reason)
                tab.browser.webView.evaluateJavaScript(Self.replayJS, completionHandler: nil)
            } else {
                SurfaceLock.shared.lock(manager, reason: request.reason)
            }
        }
        if AppModeStore.shared.mode == .hybrid {
            PeekOverlayController.shared.show()
        }
    }

    /// 当前模式对应的"Agent 正在操作的面"。
    private static func surfaceManager() -> TabManager? {
        switch AppModeStore.shared.mode {
        case .agentFocus:
            return AgentPaneManager.shared.ensure()
        case .hybrid:
            return WindowTargetResolver.agentManager()
        case .browser:
            return TabSessionCoordinator.shared.activeTabManager
        }
    }

    /// 完成/关闭：解锁、对比页面前后状态、写系统备注告知模型。
    func resolve(completed: Bool) {
        guard let request = active else { return }
        let manager = targetManager
        let before = beforeSnapshot
        let replayTab = targetTab
        if let tab = targetTab {
            SurfaceLock.shared.unlock(tab: tab)
        }
        if let manager { SurfaceLock.shared.unlock(manager) }
        targetTab = nil
        let after = manager.map { Self.snapshot($0) }
        PeekOverlayController.shared.hide()
        targetManager = nil
        beforeSnapshot = nil
        active = nil

        let note: String
        if let before, let after {
            let page = before == after ? "page unchanged" : "page changed"
            note = "Peek \(completed ? "completed" : "dismissed") — \(page) (\(before.isEmpty ? "no page" : before) → \(after.isEmpty ? "no page" : after)). Reason: \(request.reason)"
        } else {
            note = "Peek \(completed ? "completed" : "dismissed"). Reason: \(request.reason)"
        }
        lastResolution = note
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(note)
        // 接管回放（v0.8.25）：读记录器 → 去敏摘要 → 作为第二条备注交还。
        if let replayTab {
            Task { @MainActor in
                let raw = (try? await replayTab.browser.webView.evaluateJavaScript(
                    "(function(){var p=window.__desirePeek;if(!p)return '[]';clearInterval(p.timer);return JSON.stringify(p.log||[]);})()")) as? String
                guard let raw, let data = raw.data(using: .utf8),
                      let entries = try? JSONDecoder().decode([PeekReplayEntry].self, from: data),
                      !entries.isEmpty else { return }
                let summary = PeekReplayCore.format(entries)
                guard !summary.isEmpty else { return }
                AgentScheduler.shared.deliveryTarget?
                    .appendExternalNote("Peek actions observed: \(summary)")
            }
        }
    }

    func payload() -> [String: Any] {
        var result: [String: Any] = [
            "locked": SurfaceLock.shared.locked.count + SurfaceLock.shared.tabLockCount,
        ]
        if let active {
            result["active"] = [
                "id": active.id.uuidString,
                "reason": active.reason,
                "needsPage": active.needsPage,
                "status": active.status.rawValue,
            ]
        }
        if let lastResolution { result["lastResolution"] = lastResolution }
        return result
    }

    /// 接管期间的轻量记录器（v0.8.25）：只记点击文字/字段名/跳转标题，
    /// **不记输入值**；最多 60 条，Peek 结束时读取并清理定时器。
    private static let replayJS = """
    (function(){
      if (window.__desirePeek) return;
      window.__desirePeek = { log: [] };
      function label(el){
        if(!el) return '';
        var t=(el.innerText||'').trim().replace(/\\s+/g,' ').slice(0,40);
        return t || el.getAttribute('name') || el.id || el.tagName.toLowerCase();
      }
      document.addEventListener('click', function(e){
        var el = e.target && e.target.closest ? e.target.closest('a,button,input,[role=button]') : e.target;
        if(!el) return;
        window.__desirePeek.log.push({kind:'click', label:label(el)});
      }, true);
      document.addEventListener('input', function(e){
        var el = e.target; if(!el) return;
        var name = el.getAttribute('name') || el.id || el.getAttribute('type') || 'field';
        window.__desirePeek.log.push({kind:'input', label:name});
      }, true);
      var lastURL = location.href;
      window.__desirePeek.timer = setInterval(function(){
        if(location.href !== lastURL){
          lastURL = location.href;
          window.__desirePeek.log.push({kind:'navigate', label:document.title || lastURL});
        }
        if(window.__desirePeek.log.length > 60) window.__desirePeek.log.splice(0, window.__desirePeek.log.length - 60);
      }, 800);
    })();
    """

    private static func snapshot(_ manager: TabManager) -> String {
        let tab = manager.selectedTab
        return tab?.browser.webView.url?.absoluteString ?? tab?.urlString ?? ""
    }
}
