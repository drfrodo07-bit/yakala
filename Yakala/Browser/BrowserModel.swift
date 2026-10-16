import Foundation
import Combine
import UIKit
import WebKit

struct DetectedMedia: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let pageURL: URL?
    let pageTitle: String

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
}

@MainActor
final class BrowserModel: NSObject, ObservableObject {
    static let homeURL = URL(string: "https://www.google.com")!

    @Published var addressText: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var pageTitle: String = ""
    @Published var detected: [DetectedMedia] = []
    @Published var bannerMessage: String?

    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .default()

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: VideoSniffer.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        controller.add(WeakScriptMessageHandler(target: self), name: VideoSniffer.handlerName)
        AdBlocker.install(on: controller)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.estimatedProgress).receive(on: DispatchQueue.main).assign(to: &$progress)
        webView.publisher(for: \.title).map { $0 ?? "" }.receive(on: DispatchQueue.main).assign(to: &$pageTitle)
        webView.publisher(for: \.url).compactMap { $0?.absoluteString }.receive(on: DispatchQueue.main).assign(to: &$addressText)

        webView.load(URLRequest(url: Self.homeURL))
    }

    // MARK: - Gezinme

    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var target: URL?
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            target = URL(string: text)
        } else if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil {
            target = url
        }
        if target == nil {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            target = components.url
        }
        if let target {
            webView.load(URLRequest(url: target))
        }
    }

    func goHome() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    // MARK: - Video yakalama

    func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == VideoSniffer.handlerName,
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        let page = (body["page"] as? String).flatMap { URL(string: $0) }
        let title = body["title"] as? String ?? ""
        addDetected(url: url, pageURL: page, title: title)
    }

    func addDetected(url: URL, pageURL: URL?, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let resolvedTitle = title.isEmpty ? (webView.title ?? "") : title
        let item = DetectedMedia(url: url, pageURL: pageURL ?? webView.url, pageTitle: resolvedTitle)
        guard !detected.contains(where: { $0.dedupeKey == item.dedupeKey }) else { return }
        if item.isHLS {
            detected.insert(item, at: 0)
        } else {
            detected.append(item)
        }
    }

    func clearDetected() {
        detected.removeAll()
    }

    // MARK: - İndirme

    func download(_ media: DetectedMedia) {
        let name = media.pageTitle.isEmpty ? media.url.deletingPathExtension().lastPathComponent : media.pageTitle
        startDownload(url: media.url, name: name, referer: media.pageURL)
    }

    func startDownload(url: URL, name: String, referer: URL?) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        bannerMessage = "İndirme başladı: \(name)"
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            let userAgent = (try? await self.webView.evaluateJavaScript("navigator.userAgent")) as? String
            DownloadManager.shared.start(url: url,
                                         suggestedName: name,
                                         referer: referer,
                                         userAgent: userAgent,
                                         cookies: cookies)
        }
    }
}

// MARK: - Komut mesajları (zayıf referans ile, döngüsel tutmayı önler)

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserModel?

    init(target: BrowserModel) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.handleScriptMessage(message)
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        detected.removeAll()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // Reklamların uygulama açtırmasını engelle (itms, intent vb.)
        let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]
        guard webSchemes.contains(scheme) else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.shouldPerformDownload {
            if scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                let name = url.deletingPathExtension().lastPathComponent
                startDownload(url: url, name: name, referer: webView.url)
            } else {
                decisionHandler(.download)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let url = navigationResponse.response.url

        if let url, mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl") {
            addDetected(url: url, pageURL: webView.url, title: webView.title ?? "")
        }

        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
            return
        }

        // Gösterilemeyen dosyalar: arka planda devam edebilen indirme yöneticisine gönder
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            decisionHandler(.cancel)
            let suggested = navigationResponse.response.suggestedFilename ?? url.lastPathComponent
            let name = (suggested as NSString).deletingPathExtension
            startDownload(url: url, name: name, referer: webView.url)
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
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // indirmeye dönüşen sayfa
        bannerMessage = "Sayfa açılamadı: \(error.localizedDescription)"
    }
}

// MARK: - WKUIDelegate (açılır pencere engelleme)

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Yalnızca bağlantıya dokunarak açılan yeni sekmeleri aynı pencerede aç; reklam açılır pencerelerini yok say
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - WKDownloadDelegate (blob / data bağlantıları için)

extension BrowserModel: WKDownloadDelegate {
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
