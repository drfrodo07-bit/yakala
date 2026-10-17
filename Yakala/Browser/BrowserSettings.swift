import Foundation
import SwiftUI

enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case yandex
    case bing
    case duckduckgo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .yandex: return "Yandex"
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com")!
        case .yandex: return URL(string: "https://yandex.com.tr")!
        case .bing: return URL(string: "https://www.bing.com")!
        case .duckduckgo: return URL(string: "https://duckduckgo.com")!
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        var parameter = "q"
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .yandex:
            components = URLComponents(string: "https://yandex.com.tr/search/")
            parameter = "text"
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        case .duckduckgo: components = URLComponents(string: "https://duckduckgo.com/")
        }
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        return components?.url
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AddressBarPosition: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Altta"
        case .top: return "Üstte"
        }
    }
}

/// Tarayıcı ayarları (kalıcı)
@MainActor
final class BrowserSettings: ObservableObject {
    static let shared = BrowserSettings()

    private let defaults = UserDefaults.standard

    @Published var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: "b.searchEngine") }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "b.appearance") }
    }
    @Published var addressBarPosition: AddressBarPosition {
        didSet { defaults.set(addressBarPosition.rawValue, forKey: "b.addressBar") }
    }
    @Published var adBlockEnabled: Bool {
        didSet {
            defaults.set(adBlockEnabled, forKey: "b.adBlock")
            AdBlocker.shared.settingsChanged()
        }
    }
    @Published var adBlockExceptions: Set<String> {
        didSet {
            defaults.set(Array(adBlockExceptions), forKey: "b.adBlockExceptions")
            AdBlocker.shared.settingsChanged()
        }
    }
    @Published var popupBlockEnabled: Bool {
        didSet { defaults.set(popupBlockEnabled, forKey: "b.popupBlock") }
    }
    @Published var webDarkMode: Bool {
        didSet { defaults.set(webDarkMode, forKey: "b.webDark") }
    }
    @Published var takeoverPlayer: Bool {
        didSet {
            defaults.set(takeoverPlayer, forKey: "b.takeover")
            NotificationCenter.default.post(name: .yakalaScriptsChanged, object: nil)
        }
    }
    @Published var hideShortVideos: Bool {
        didSet { defaults.set(hideShortVideos, forKey: "b.hideShort") }
    }
    @Published var connections: Int {
        didSet {
            defaults.set(connections, forKey: DownloadManager.connectionsKey)
            DownloadManager.shared.connectionsDidChange()
        }
    }

    private init() {
        let d = UserDefaults.standard
        searchEngine = SearchEngine(rawValue: d.string(forKey: "b.searchEngine") ?? "") ?? .google
        appearance = AppAppearance(rawValue: d.string(forKey: "b.appearance") ?? "") ?? .system
        addressBarPosition = AddressBarPosition(rawValue: d.string(forKey: "b.addressBar") ?? "") ?? .bottom
        adBlockEnabled = d.object(forKey: "b.adBlock") as? Bool ?? true
        adBlockExceptions = Set(d.stringArray(forKey: "b.adBlockExceptions") ?? [])
        popupBlockEnabled = d.object(forKey: "b.popupBlock") as? Bool ?? true
        webDarkMode = d.object(forKey: "b.webDark") as? Bool ?? false
        takeoverPlayer = d.object(forKey: "b.takeover") as? Bool ?? true
        hideShortVideos = d.object(forKey: "b.hideShort") as? Bool ?? true
        let savedConnections = d.integer(forKey: DownloadManager.connectionsKey)
        connections = savedConnections > 0 ? savedConnections : 8
    }

    func isAdBlockActive(for host: String?) -> Bool {
        guard adBlockEnabled else { return false }
        guard let host = Self.baseHost(host) else { return true }
        return !adBlockExceptions.contains(host)
    }

    func setAdBlock(_ enabled: Bool, for host: String?) {
        guard let host = Self.baseHost(host) else { return }
        if enabled {
            adBlockExceptions.remove(host)
        } else {
            adBlockExceptions.insert(host)
        }
    }

    static func baseHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        return host
    }
}

extension Notification.Name {
    static let yakalaScriptsChanged = Notification.Name("yakalaScriptsChanged")
}
