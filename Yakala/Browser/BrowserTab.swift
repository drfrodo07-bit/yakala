import Foundation
import Combine
import UIKit
import WebKit

struct DetectedMedia: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var pageURL: URL?
    var pageTitle: String
    var duration: Double?
    var isPlaying = false
    var detectedAt = Date()

    var isHLS: Bool {
        url.absoluteString.lowercased().contains(".m3u8")
    }

    var displayName: String {
        let last = url.lastPathComponent
        return last.isEmpty ? (url.host ?? url.absoluteString) : last
    }

    var kindLabel: String {
        if isHLS { return "Akış (HLS)" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "Video" : ext
    }

    var dedupeKey: String {
        (url.host ?? "") + url.path
    }

    /// 1 dakikadan kısa videolar genellikle reklamdır
    var isLikelyAd: Bool {
        guard let duration, duration > 0 else { return false }
        return duration < 60
    }
}

struct TakeoverRequest: Identifiable {
    let id = UUID()
    let url: URL
    let pageURL: URL?
    let title: String
    let startTime: Double
    let headers: [String: String]
}

struct ReaderContent: Identifiable {
    struct Item: Hashable {
        let tag: String
        let text: String
    }

    let id = UUID()
    let title: String
    let items: [Item]
}

/// Tek bir tarayıcı sekmesi: kendi web görünümü, durumu ve yakalanan videoları
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    let webView: WKWebView
    weak var manager: TabManager?

    @Published var title: String = ""
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var detected: [DetectedMedia] = []
    @Published var snapshot: UIImage?
    @Published var desktopMode = false
    @Published var darkPage: Bool
    @Published var pageZoom: CGFloat = 1
    @Published var barsCollapsed = false
    @Published var takeoverRequest: TakeoverRequest?
    @Published var bannerMessage: String?

    /// Sekme henüz yüklenmediyse (uygulama yeniden açıldığında) açılacak adres
    private var pendingURL: URL?
    private var userAgent: String?
    private var lastScrollOffset: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    var showsStartPage: Bool {
        url == nil && pendingURL == nil && !isLoading
    }

    var displayURL: URL? {
        url ?? pendingURL
    }

    var host: String? {
        displayURL?.host
    }

    init(id: UUID = UUID(), isPrivate: Bool, dataStore: WKWebsiteDataStore, initialURL: URL?, loadImmediately: Bool = true) {
        self.id = id
        self.isPrivate = isPrivate
        self.darkPage = BrowserSettings.shared.webDarkMode

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = dataStore
        configuration.userContentController = WKUserContentController()
        configuration.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        let controller = configuration.userContentController
        controller.add(WeakScriptMessageHandler(target: self), name: VideoSniffer.handlerName)
        installScripts()
        AdBlocker.shared.register(controller)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        bindWebView()

        NotificationCenter.default.publisher(for: .yakalaScriptsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.installScripts() }
            }
            .store(in: &cancellables)

        if let initialURL {
            if loadImmediately {
                webView.load(URLRequest(url: initialURL))
            } else {
                pendingURL = initialURL
                title = initialURL.host ?? ""
            }
        }
    }

    private func bindWebView() {
        webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.estimatedProgress).receive(on: DispatchQueue.main).assign(to: &$progress)

        webView.publisher(for: \.title)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, let value, !value.isEmpty else { return }
                    self.title = value
                    if !self.isPrivate, let url = self.url {
                        BrowserStore.shared.updateTitle(value, for: url)
                    }
                }
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, let value else { return }
                    if value.absoluteString == "about:blank" {
                        self.url = nil
                        return
                    }
                    self.url = value
                    self.pendingURL = nil
                    self.manager?.tabDidChange()
                }
            }
            .store(in: &cancellables)

        // Aşağı kaydırınca çubukları küçült, yukarı kaydırınca geri getir (Safari gibi)
        webView.scrollView.publisher(for: \.contentOffset)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offset in
                MainActor.assumeIsolated { self?.handleScroll(offset.y) }
            }
            .store(in: &cancellables)
    }

    private func handleScroll(_ y: CGFloat) {
        let scrollView = webView.scrollView
        guard scrollView.isDragging || scrollView.isDecelerating else {
            lastScrollOffset = y
            return
        }
        let delta = y - lastScrollOffset
        lastScrollOffset = y
        if y <= 10 {
            if barsCollapsed { barsCollapsed = false }
        } else if delta > 6, !barsCollapsed {
            barsCollapsed = true
        } else if delta < -10, barsCollapsed {
            barsCollapsed = false
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        webView.reload()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            sender.endRefreshing()
        }
    }

    private func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: VideoSniffer.script(takeover: BrowserSettings.shared.takeoverPlayer),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        if darkPage {
            controller.addUserScript(WKUserScript(source: VideoSniffer.darkModeScript(enabled: true),
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        webView.evaluateJavaScript("window.__yakalaTakeover = \(BrowserSettings.shared.takeoverPlayer ? "true" : "false");",
                                   completionHandler: nil)
    }

    // MARK: - Gezinme

    /// Sekme seçildiğinde bekleyen sayfayı yükler
    func activate() {
        if let pendingURL, webView.url == nil {
            webView.load(URLRequest(url: pendingURL))
        }
    }

    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = Self.url(from: text) {
            load(url)
        } else if let url = BrowserSettings.shared.searchEngine.searchURL(for: text) {
            load(url)
        }
    }

    func load(_ url: URL) {
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    static func url(from text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        if lower.hasPrefix("about:") { return URL(string: text) }
        guard !text.contains(" "), text.contains("."), !text.hasSuffix(".") else { return nil }
        if let url = URL(string: "https://" + text), let host = url.host, host.contains(".") {
            return url
        }
        return nil
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url == nil, let pendingURL {
            webView.load(URLRequest(url: pendingURL))
        } else {
            webView.reload()
        }
    }

    func goHome() {
        webView.stopLoading()
        if webView.url != nil {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        url = nil
        pendingURL = nil
        title = ""
        detected.removeAll()
        manager?.tabDidChange()
    }

    func takeSnapshot() {
        guard webView.window != nil, url != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 320
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                if let image { self?.snapshot = image }
            }
        }
    }

    // MARK: - Sayfa araçları

    func toggleDesktopMode() {
        desktopMode.toggle()
        webView.reload()
    }

    func toggleDarkPage() {
        darkPage.toggle()
        installScripts()
        webView.evaluateJavaScript(VideoSniffer.darkModeScript(enabled: darkPage), completionHandler: nil)
    }

    func changeZoom(by delta: CGFloat) {
        pageZoom = min(max(pageZoom + delta, 0.5), 3)
        webView.pageZoom = pageZoom
    }

    func resetZoom() {
        pageZoom = 1
        webView.pageZoom = 1
    }

    func translatePage() {
        guard let current = url, var components = URLComponents(string: "https://translate.google.com/translate") else { return }
        components.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "tr"),
            URLQueryItem(name: "hl", value: "tr"),
            URLQueryItem(name: "u", value: current.absoluteString)
        ]
        if let translated = components.url {
            load(translated)
        }
    }

    func findInPage() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func readerContent() async -> ReaderContent? {
        guard let result = try? await webView.evaluateJavaScript(VideoSniffer.readerScript),
              let json = result as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = object["title"] as? String ?? ""
        let rawItems = object["items"] as? [[String: String]] ?? []
        let items = rawItems.compactMap { item -> ReaderContent.Item? in
            guard let text = item["text"] else { return nil }
            return ReaderContent.Item(tag: item["tag"] ?? "p", text: text)
        }
        guard !items.isEmpty else { return nil }
        return ReaderContent(title: title, items: items)
    }

    // MARK: - Video yakalama

    func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == VideoSniffer.handlerName,
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let mediaURL = URL(string: urlString) else { return }
        let type = body["type"] as? String ?? "media"
        let page = (body["page"] as? String).flatMap { URL(string: $0) }
        let frameTitle = body["title"] as? String ?? ""
        let duration = (body["duration"] as? Double).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        switch type {
        case "fullscreen":
            let start = body["time"] as? Double ?? 0
            addDetected(url: mediaURL, pageURL: page, frameTitle: frameTitle, duration: duration, playing: true)
            Task { @MainActor in
                let headers = await self.requestHeaders(for: mediaURL, referer: page)
                self.takeoverRequest = TakeoverRequest(url: mediaURL,
                                                       pageURL: page,
                                                       title: self.cleanTitle(frameTitle),
                                                       startTime: start,
                                                       headers: headers)
            }
        case "playing":
            addDetected(url: mediaURL, pageURL: page, frameTitle: frameTitle, duration: duration, playing: true)
        default:
            addDetected(url: mediaURL, pageURL: page, frameTitle: frameTitle, duration: duration, playing: false)
        }
    }

    static let ignoredExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "avif",
                                                  "css", "js", "json", "html", "htm", "vtt", "srt", "ts", "m4s", "key"]

    func cleanTitle(_ frameTitle: String) -> String {
        var value = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = frameTitle }
        for separator in [" - ", " | ", " – "] {
            if let range = value.range(of: separator, options: .backwards),
               value.distance(from: value.startIndex, to: range.lowerBound) > 8 {
                value = String(value[..<range.lowerBound])
            }
        }
        return value
    }

    func addDetected(url mediaURL: URL, pageURL: URL?, frameTitle: String, duration: Double?, playing: Bool, fromMimeType: Bool = false) {
        guard let scheme = mediaURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if !fromMimeType, Self.ignoredExtensions.contains(mediaURL.pathExtension.lowercased()) { return }

        let item = DetectedMedia(url: mediaURL,
                                 pageURL: pageURL ?? webView.url,
                                 pageTitle: cleanTitle(frameTitle),
                                 duration: duration,
                                 isPlaying: playing)

        if let index = detected.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
            if let duration { detected[index].duration = duration }
            if playing {
                for i in detected.indices { detected[i].isPlaying = false }
                detected[index].isPlaying = true
            }
            return
        }

        if playing {
            for i in detected.indices { detected[i].isPlaying = false }
        }
        detected.append(item)

        // Akışların süresini öğren (reklam mı, asıl video mu?)
        if item.isHLS && duration == nil {
            let id = item.id
            Task { @MainActor in
                let headers = await self.requestHeaders(for: mediaURL, referer: item.pageURL)
                if let total = await DownloadJobStore.hlsDuration(of: mediaURL, headers: headers),
                   let index = self.detected.firstIndex(where: { $0.id == id }) {
                    self.detected[index].duration = total
                }
            }
        }
    }

    /// Yakalanan videoları önem sırasına göre döner: oynatılan ve uzun olanlar önce
    var sortedDetected: [DetectedMedia] {
        detected.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            if a.isLikelyAd != b.isLikelyAd { return !a.isLikelyAd }
            let da = a.duration ?? (a.isHLS ? 1_000 : 0)
            let db = b.duration ?? (b.isHLS ? 1_000 : 0)
            if da != db { return da > db }
            return a.detectedAt > b.detectedAt
        }
    }

    var mainVideoCount: Int {
        detected.filter { !$0.isLikelyAd }.count
    }

    func requestHeaders(for mediaURL: URL, referer: URL?) async -> [String: String] {
        var headers: [String: String] = [:]
        if let referer = referer ?? webView.url {
            headers["Referer"] = referer.absoluteString
        }
        if userAgent == nil {
            userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        }
        if let userAgent { headers["User-Agent"] = userAgent }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter { DownloadManager.cookie($0, matches: mediaURL) }
        headers.merge(HTTPCookie.requestHeaderFields(with: relevant)) { $1 }
        return headers
    }

    func download(_ media: DetectedMedia) {
        let name = media.pageTitle.isEmpty ? media.url.deletingPathExtension().lastPathComponent : media.pageTitle
        startDownload(url: media.url, name: name, referer: media.pageURL)
    }

    func startDownload(url downloadURL: URL, name: String, referer: URL?) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        bannerMessage = "İndirme başladı: \(name)"
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            if self.userAgent == nil {
                self.userAgent = (try? await self.webView.evaluateJavaScript("navigator.userAgent")) as? String
            }
            DownloadManager.shared.start(url: downloadURL,
                                         suggestedName: name,
                                         referer: referer ?? self.webView.url,
                                         userAgent: self.userAgent,
                                         cookies: cookies)
        }
    }
}

// MARK: - Komut mesajları (zayıf referans ile)

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserTab?

    init(target: BrowserTab) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.handleScriptMessage(message)
        }
    }
}

// MARK: - Gezinme olayları

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        detected.removeAll()
        barsCollapsed = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let url = webView.url, url.scheme?.hasPrefix("http") == true {
            BrowserStore.shared.recordVisit(title: webView.title ?? "", url: url)
        }
        if pageZoom != 1 {
            webView.pageZoom = pageZoom
        }
        manager?.tabDidChange()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile

        guard let target = navigationAction.request.url, let scheme = target.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }

        let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]
        guard webSchemes.contains(scheme) else {
            // Reklamların başka uygulama açtırmasını engelle; kullanıcı dokunduysa (tel:, mailto:) izin ver
            if navigationAction.navigationType == .linkActivated, ["tel", "mailto", "sms", "maps"].contains(scheme) {
                UIApplication.shared.open(target)
            }
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.shouldPerformDownload {
            if scheme == "http" || scheme == "https" {
                decisionHandler(.cancel, preferences)
                startDownload(url: target, name: target.deletingPathExtension().lastPathComponent, referer: webView.url)
            } else {
                decisionHandler(.download, preferences)
            }
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let responseURL = navigationResponse.response.url

        if let responseURL, mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl") {
            addDetected(url: responseURL, pageURL: webView.url, frameTitle: webView.title ?? "",
                        duration: nil, playing: false, fromMimeType: true)
        }

        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
            return
        }

        if let responseURL, let scheme = responseURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            decisionHandler(.cancel)
            let suggested = navigationResponse.response.suggestedFilename ?? responseURL.lastPathComponent
            startDownload(url: responseURL, name: (suggested as NSString).deletingPathExtension, referer: webView.url)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        bannerMessage = "Sayfa açılamadı: \(error.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Yeni pencereler, bağlantı menüsü

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let target = navigationAction.request.url,
              target.absoluteString != "about:blank" else { return nil }
        let userInitiated = navigationAction.navigationType == .linkActivated
        if userInitiated || !BrowserSettings.shared.popupBlockEnabled {
            // Safari gibi: yeni sekmede aç
            manager?.openTab(target, isPrivate: isPrivate, select: true)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let privateTab = isPrivate
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard self != nil else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: "Yeni sekmede aç", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.manager?.openTab(link, isPrivate: self.isPrivate, select: false)
                        self.bannerMessage = "Yeni sekmede açıldı"
                    }
                },
                UIAction(title: "Gizli sekmede aç", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.manager?.openTab(link, isPrivate: true, select: true)
                    }
                },
                UIAction(title: "Bağlantıyı indir", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.startDownload(url: link, name: link.deletingPathExtension().lastPathComponent, referer: self?.webView.url)
                    }
                },
                UIAction(title: "Bağlantıyı kopyala", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = link
                }
            ]
            if !privateTab {
                actions.append(UIAction(title: "Yer imlerine ekle", image: UIImage(systemName: "book")) { _ in
                    MainActor.assumeIsolated {
                        BrowserStore.shared.addBookmark(title: link.host ?? link.absoluteString, url: link)
                    }
                })
            }
            return UIMenu(title: link.absoluteString, children: actions)
        }
        completionHandler(configuration)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        bannerMessage = message
        completionHandler()
    }
}

// MARK: - blob / data indirmeleri

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        let destination = FileStore.uniqueURL(in: FileStore.downloads, baseName: name, ext: ext)
        bannerMessage = "İndiriliyor: \(destination.lastPathComponent)"
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        bannerMessage = "İndirme tamamlandı"
        DownloadManager.shared.notifyLibraryChanged()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        bannerMessage = "İndirme başarısız: \(error.localizedDescription)"
    }
}
