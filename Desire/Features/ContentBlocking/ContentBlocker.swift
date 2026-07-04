import Combine
import WebKit

@MainActor
class ContentBlocker: ObservableObject {
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

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                guard let self else { return }
                self.compiling.remove(kind)
                guard let ruleList else {
                    print("ContentBlocker[\(kind)] compile error: \(error?.localizedDescription ?? "unknown")")
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

private extension ContentBlocker {
    var adsRulesJSON: String { ContentRules.ads }

    var trackingRulesJSON: String { ContentRules.tracking }
}

private enum ContentRules {
    static let ads = """
    [{"trigger":{"url-filter":".*doubleclick\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googlesyndication\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googleadservices\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*google-analytics\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googletagmanager\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googletagservices\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adservice\\\\.google\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pagead2\\\\.googlesyndication\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adsystem\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adnxs\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*criteo\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*casalemedia\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*rubiconproject\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*openx\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pubmatic\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*taboola\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*outbrain\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adsafeprotected\\\\.com.*"},"action":{"type":"block"}}]
    """

    static let tracking = """
    [{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}},
    {"trigger":{"url-filter":".*connect\\\\.facebook\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.facebook\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.facebook\\\\.com/tr.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*analytics\\\\.twitter\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ads-twitter\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.linkedin\\\\.com/px.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*snap\\\\.licdn\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*api\\\\.segment\\\\.io.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.segment\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*api\\\\.mixpanel\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.mxpnl\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*api\\\\.amplitude\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*static\\\\.hotjar\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*script\\\\.hotjar\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*rs\\\\.fullstory\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.mouseflow\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*static\\\\.chartbeat\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pingdom\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*clarity\\\\.ms.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*bat\\\\.bing\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*tagmanager\\\\.google\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*scorecardresearch\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*quantserve\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.tiktok\\\\.com/i18n/pixel.*"},"action":{"type":"block"}}]
    """
}
