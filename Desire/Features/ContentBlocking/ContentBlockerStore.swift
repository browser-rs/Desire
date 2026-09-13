import Combine
import WebKit
import os

@MainActor
class ContentBlockerStore: ObservableObject {
    @Published var isBlockingEnabled = false {
        didSet {
            guard oldValue != isBlockingEnabled else { return }
            UserDefaults.standard.set(isBlockingEnabled, forKey: "contentBlockerEnabled")
            if isBlockingEnabled {
                ensureCompiled(kind: .ads)
            }
            reapplyAll()
        }
    }

    @Published var isTrackingEnabled = false {
        didSet {
            guard oldValue != isTrackingEnabled else { return }
            UserDefaults.standard.set(isTrackingEnabled, forKey: "trackingProtectionEnabled")
            if isTrackingEnabled {
                ensureCompiled(kind: .tracking)
            }
            reapplyAll()
        }
    }

    private enum Kind { case ads, tracking }

    private var adRuleList: WKContentRuleList?
    private var trackingRuleList: WKContentRuleList?
    private var compiling: Set<Kind> = []
    private var registered: [WeakBox] = []

    init() {
        isBlockingEnabled = UserDefaults.standard.bool(forKey: "contentBlockerEnabled")
        isTrackingEnabled = UserDefaults.standard.bool(forKey: "trackingProtectionEnabled")
        if isBlockingEnabled { ensureCompiled(kind: .ads) }
        if isTrackingEnabled { ensureCompiled(kind: .tracking) }
    }

    func register(_ controller: WKUserContentController) {
        registered.removeAll { $0.controller == nil }
        if !registered.contains(where: { $0.controller === controller }) {
            registered.append(WeakBox(controller: controller))
        }
        apply(to: controller)
    }

    func apply(to config: WKWebViewConfiguration) {
        register(config.userContentController)
    }

    private func ensureCompiled(kind: Kind) {
        switch kind {
        case .ads where adRuleList != nil: return
        case .tracking where trackingRuleList != nil: return
        default: break
        }
        guard !compiling.contains(kind) else { return }
        compiling.insert(kind)

        let identifier = kind == .ads ? "desire-blocker" : "desire-tracking"
        let json = kind == .ads ? adsRulesJSON : trackingRulesJSON

        // The rule-list store caches compiled lists by identifier and may
        // hand back the STALE list when we ship changed rules under the same
        // id — remove the cached entry before compiling so rule edits
        // actually take effect on the next launch.
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { [weak self] _ in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { [weak self] ruleList, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.compiling.remove(kind)
                    guard let ruleList else {
                        Log.contentBlocking.error("rule list \(kind == .ads ? "ads" : "tracking", privacy: .public) failed to compile: \(error?.localizedDescription ?? "unknown")")
                        return
                    }
                    switch kind {
                    case .ads: self.adRuleList = ruleList
                    case .tracking: self.trackingRuleList = ruleList
                    }
                    self.reapplyAll()
                }
            }
        }
    }

    private func apply(to controller: WKUserContentController) {
        if isBlockingEnabled, let ad = adRuleList { controller.add(ad) }
        if isTrackingEnabled, let tr = trackingRuleList { controller.add(tr) }
    }

    private func reapplyAll() {
        for box in registered {
            guard let c = box.controller else { continue }
            c.removeAllContentRuleLists()
            apply(to: c)
        }
    }
}

private final class WeakBox {
    weak var controller: WKUserContentController?
    init(controller: WKUserContentController) { self.controller = controller }
}

private extension ContentBlockerStore {
    var adsRulesJSON: String { Self.rulesJSON(resource: "ContentBlockerAds") }

    var trackingRulesJSON: String { Self.rulesJSON(resource: "ContentBlockerTracking") }

    /// Rules live in bundled JSON resources (`ContentBlockerAds.json` /
    /// `ContentBlockerTracking.json`, auto-included by the file-synced
    /// group) so the filter lists can be edited without touching Swift.
    /// A missing resource is a packaging bug — degrade to an empty list and
    /// log loudly rather than crash.
    static func rulesJSON(resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            Log.contentBlocking.error("resource not found: \(resource, privacy: .public).json")
            return "[]"
        }
        do {
            // Validate before handing to WKContentRuleList's compiler so a
            // malformed file fails with a precise message.
            let data = try Data(contentsOf: url)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil,
                  let string = String(data: data, encoding: .utf8) else {
                Log.contentBlocking.error("invalid JSON in \(resource, privacy: .public).json")
                return "[]"
            }
            return string
        } catch {
            Log.contentBlocking.error("failed to read \(resource, privacy: .public).json: \(error.localizedDescription)")
            return "[]"
        }
    }
}

