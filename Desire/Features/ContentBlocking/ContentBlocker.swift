import Combine
import WebKit

@MainActor
class ContentBlocker: ObservableObject {
    @Published var isBlockingEnabled = false {
        didSet {
            UserDefaults.standard.set(isBlockingEnabled, forKey: "contentBlockerEnabled")
            if isBlockingEnabled {
                compileRules()
            }
        }
    }

    private var compiledRules: [WKContentRuleList] = []

    init() {
        isBlockingEnabled = UserDefaults.standard.bool(forKey: "contentBlockerEnabled")
        if isBlockingEnabled {
            compileRules()
        }
    }

    deinit {
        cancellables.forEach { $0.cancel() }
    }

    private var cancellables: [AnyCancellable] = []

    func apply(to config: WKWebViewConfiguration) {
        for rule in compiledRules {
            config.userContentController.add(rule)
        }
    }

    private func compileRules() {
        compiledRules.removeAll()
        let rulesJSON = blockRulesJSON
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "desire-blocker",
            encodedContentRuleList: rulesJSON
        ) { [weak self] ruleList, error in
            guard let ruleList else {
                print("Content blocker compile error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            self?.compiledRules = [ruleList]
        }
    }

    private let blockRulesJSON = {
        let trackers = [
            // Google / Alphabet
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "google-analytics.com", "googletagmanager.com", "googletagservices.com",
            "adservice.google.com", "pagead2.googlesyndication.com", "googleads.g.doubleclick.net",
            "www.googletagmanager.com", "connect.facebook.net", "ad.doubleclick.net",
            "static.doubleclick.net", "td.doubleclick.net", "googleoptimize.com",
            // Meta / Facebook
            "facebook.com/tr", "facebook.net", "fbcdn.net", "connect.facebook.net",
            "pixel.facebook.com", "an.facebook.com", "atdmt.com",
            // Microsoft / LinkedIn
            "bat.bing.com", "c.bing.com", "ads.microsoft.com",
            "linkedin.com/px", "px.ads.linkedin.com",
            // Amazon
            "amazon-adsystem.com", "aax.amazon-adsystem.com", "amazonadsi.com",
            // Twitter / X
            "analytics.twitter.com", "ads-twitter.com", "t.co",
            // TikTok
            "ads.tiktok.com", "analytics.tiktok.com",
            // Major ad networks
            "adsystem.com", "adnxs.com", "criteo.com", "casalemedia.com",
            "rubiconproject.com", "openx.net", "pubmatic.com",
            "thetradedesk.com", "adsrvr.org", "adzerk.net",
            "lijit.com", "sovrn.com", "indexww.com", "quantserve.com",
            "scorecardresearch.com", "comscore.com", "moatads.com",
            // Analytics
            "hotjar.com", "mouseflow.com", "fullstory.com",
            "crazyegg.com", "clicktale.net", "optimizely.com",
            "segment.io", "segment.com", "amplitude.com", "mixpanel.com",
            "heap.com", "branch.io", "adjust.com", "appsflyer.com",
        ]

        let rules = trackers.enumerated().map { i, domain in
            """
            {"trigger":{"url-filter":".*\(domain.replacingOccurrences(of: "/", with: "\\\\/")).*"},"action":{"type":"block"}}
            """
        }
        return "[\(rules.joined(separator: ","))]"
    }()
}
