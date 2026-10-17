import Foundation
import WebKit

/// Reklam ve izleyici engelleyici. Ayarlardan tamamen ya da site site kapatılabilir.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    private var ruleList: WKContentRuleList?
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var compileGeneration = 0

    static let blockedDomains: [String] = [
        // Google reklam / izleme
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com",
        // Reklam ağları
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "adform.net", "yieldmo.com", "media.net", "teads.tv", "sharethrough.com",
        "33across.com", "indexww.com", "lijit.com", "sovrn.com", "contextweb.com", "bidswitch.net",
        "mgid.com", "revcontent.com", "zedo.com", "adcolony.com", "applovin.com", "inmobi.com",
        "smaato.net", "spotxchange.com", "springserve.com", "adsafeprotected.com", "moatads.com",
        "admatic.com.tr", "reklamstore.com", "adhood.com", "an.yandex.ru", "adfox.ru", "yandexadexchange.net",
        // Açılır pencere / yönlendirme ağları
        "propellerads.com", "popads.net", "popcash.net", "exoclick.com", "exosrv.com", "juicyads.com",
        "trafficjunky.net", "adsterra.com", "hilltopads.net", "onclickads.net", "onclickalgo.com",
        "clickadu.com", "adcash.com", "a-ads.com", "galaksion.com", "richpush.co", "pushame.com",
        "realsrv.com", "tsyndicate.com", "adspyglass.com", "highperformanceformat.com", "profitablecpmrate.com",
        "profitablegatecpm.com", "displayvertising.com", "adskeeper.com", "acint.net", "bidgear.com",
        // İzleyiciler
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "mc.yandex.ru", "chartbeat.com"
    ]

    static let hiddenSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='div-gpt-ad']", "[id^='google_ads_iframe']",
        "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
        ".ad-banner", ".ad-container", ".advertisement", "[class*='taboola']", "[id*='taboola']",
        "[class*='outbrain']"
    ].joined(separator: ", ")

    private init() {
        compile()
    }

    /// Bir sekmenin içerik denetleyicisini kaydeder ve geçerli kuralları uygular
    func register(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    func settingsChanged() {
        compile()
    }

    private func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if BrowserSettings.shared.adBlockEnabled, let ruleList {
            controller.add(ruleList)
        }
    }

    private func applyAll() {
        for controller in controllers.allObjects {
            apply(to: controller)
        }
    }

    private func compile() {
        compileGeneration += 1
        let generation = compileGeneration
        let exceptions = Array(BrowserSettings.shared.adBlockExceptions)
        let json = Self.ruleListJSON(exceptions: exceptions)
        let defaultStore: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store = defaultStore else { return }
        store.compileContentRuleList(forIdentifier: "yakala-reklam-engelleyici", encodedContentRuleList: json) { [weak self] list, error in
            Task { @MainActor in
                guard let self, generation == self.compileGeneration else { return }
                if let list {
                    self.ruleList = list
                } else if let error {
                    print("Reklam engelleyici derlenemedi: \(error)")
                }
                self.applyAll()
            }
        }
    }

    static func ruleListJSON(exceptions: [String]) -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]",
                    "load-type": ["third-party"]
                ],
                "action": ["type": "block"]
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors]
        ])
        if !exceptions.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": exceptions.map { "*" + $0 }],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
