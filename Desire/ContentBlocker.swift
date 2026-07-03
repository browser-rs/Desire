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

    private let blockRulesJSON = """
    [{
        "trigger": { "url-filter": ".*doubleclick.net/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*googlesyndication.com/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*googleadservices.com/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*google-analytics.com/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*googletagmanager.com/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*googletagservices.com/.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*facebook.com/tr.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*doubleclick.net.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*adservice.google.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*pagead2.googlesyndication.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*adsystem.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*adnxs.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*criteo.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*casalemedia.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*rubiconproject.com.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*openx.net.*" },
        "action": { "type": "block" }
    },{
        "trigger": { "url-filter": ".*pubmatic.com.*" },
        "action": { "type": "block" }
    }]
    """
}
