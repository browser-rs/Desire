import Combine
import WebKit

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

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                guard let self else { return }
                self.compiling.remove(kind)
                guard let ruleList else {
                    print("ContentBlockerStore[\(kind)] compile error: \(error?.localizedDescription ?? "unknown")")
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

private extension ContentBlockerStore {
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
    {"trigger":{"url-filter":".*\\\\.tiktok\\\\.com/i18n/pixel.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*instagram\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.instagram\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pinterest\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.pinterest\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*reddit\\\\.com/static.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.reddit\\\\.com/static.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*youtube\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.youtube\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pixel\\\\.wp\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*stats\\\\.wp\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*c\\\\.wt\\\\.weather\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*pixel\\\\.weather\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*analytics\\\\.yahoo\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.yahoo\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ads\\\\.yahoo\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*beacon\\\\.qq\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*tajs\\\\.qq\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*hm\\\\.baidu\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*c\\\\.pro\\\\.cn.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*fingerprintjs\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*fp\\\\.collect\\\\.js.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*fingerprint2\\\\.min\\\\.js.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*clientjs\\\\.org.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*browserleaks\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*deviceatlas\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ioam\\\\.de.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*infonline\\\\.de.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ivw\\\\.de.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*szo\\\\.mmstat\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*m\\\\.mmstat\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*track\\\\.uc\\\\.cn.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*optimizely\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.optimizely\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*krxd\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*krux\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*clicktale\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.clicktale\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*userreport\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.userreport\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*newrelic\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*bam\\\\.nr-data\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*js\\\\.agent\\\\.newrelic\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*rum\\\\.newrelic\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*conviva\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cws\\\\.conviva\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*livepass\\\\.conviva\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*cdn\\\\.livepass\\\\.conviva\\\\.com.*"},"action":{"type":"block"}}]
    """
}
