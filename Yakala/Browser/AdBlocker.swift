import Foundation
import WebKit

/// Basit reklam ve izleyici engelleyici (Safari içerik engelleme kurallarıyla)
enum AdBlocker {
    static let identifier = "yakala-reklam-engelleyici-v1"

    static let blockedDomains: [String] = [
        // Google reklam / izleme
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "imasdk.googleapis.com",
        // Reklam ağları
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "adform.net", "yieldmo.com", "media.net", "teads.tv", "sharethrough.com",
        "33across.com", "indexww.com", "lijit.com", "sovrn.com", "contextweb.com", "bidswitch.net",
        "mgid.com", "revcontent.com", "zedo.com", "adcolony.com", "applovin.com", "inmobi.com",
        "smaato.net", "spotxchange.com", "springserve.com", "adsafeprotected.com", "moatads.com",
        "admatic.com.tr", "reklamstore.com", "adhood.com", "an.yandex.ru", "adfox.ru",
        // Açılır pencere / yönlendirme ağları
        "propellerads.com", "popads.net", "popcash.net", "exoclick.com", "exosrv.com", "juicyads.com",
        "trafficjunky.net", "adsterra.com", "hilltopads.net", "onclickads.net", "onclickalgo.com",
        "clickadu.com", "adcash.com", "a-ads.com", "galaksion.com", "richpush.co", "pushame.com",
        "realsrv.com", "tsyndicate.com", "adspyglass.com", "bebi.com", "highperformanceformat.com",
        // İzleyiciler
        "scorecardresearch.com", "quantserve.com", "hotjar.com", "mc.yandex.ru", "chartbeat.com"
    ]

    static let hiddenSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='div-gpt-ad']", "[id^='google_ads_iframe']",
        "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
        ".ad-banner", ".ad-container", ".advertisement", "[class*='taboola']", "[id*='taboola']",
        "[class*='outbrain']"
    ].joined(separator: ", ")

    static func ruleListJSON() -> String {
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
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func install(on controller: WKUserContentController) {
        let defaultStore: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store = defaultStore else { return }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: ruleListJSON()) { list, error in
            if let list {
                controller.add(list)
            } else if let error {
                print("Reklam engelleyici derlenemedi: \(error)")
            }
        }
    }
}
