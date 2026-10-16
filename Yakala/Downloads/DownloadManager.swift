import Foundation
import AVFoundation
import Combine
import UIKit

/// Uygulama arka plana geçtiğinde de çalışmaya devam eden indirme yöneticisi.
/// Normal dosyalar (MP4 vb.) ve HLS akışları (m3u8) için ayrı arka plan oturumları kullanır.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let fileSessionID = "com.yakala.app.files"
    static let hlsSessionID = "com.yakala.app.hls"

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case running
            case converting
            case finished
            case failed(String)
        }

        let id: UUID
        var name: String
        var isHLS: Bool
        var progress: Double = 0
        var bytes: Int64 = 0
        var state: State = .running

        var isActive: Bool {
            state == .running || state == .converting
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var libraryVersion = 0

    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var tasks: [UUID: URLSessionTask] = [:]
    private var hlsLocations: [Int: URL] = [:]
    private var convertingPaths: Set<String> = []
    private var backgroundCompletions: [String: () -> Void] = [:]
    private let pendingKey = "yakala.pendingHLSConversions"

    private override init() {
        super.init()

        let fileConfig = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fileConfig.sessionSendsLaunchEvents = true
        fileConfig.isDiscretionary = false
        fileConfig.allowsCellularAccess = true
        fileSession = URLSession(configuration: fileConfig, delegate: self, delegateQueue: .main)

        let hlsConfig = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hlsConfig.sessionSendsLaunchEvents = true
        hlsConfig.isDiscretionary = false
        hlsConfig.allowsCellularAccess = true
        hlsSession = AVAssetDownloadURLSession(configuration: hlsConfig,
                                               assetDownloadDelegate: self,
                                               delegateQueue: .main)

        restoreRunningTasks()
        DispatchQueue.main.async { [weak self] in
            self?.resumePendingConversions()
        }
    }

    // MARK: - Genel arayüz

    func start(url: URL, suggestedName: String, referer: URL?, userAgent: String?, cookies: [HTTPCookie]) {
        let relevantCookies = cookies.filter { Self.cookie($0, matches: url) }
        var headers: [String: String] = [:]
        if let referer { headers["Referer"] = referer.absoluteString }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }

        let isHLS = url.absoluteString.lowercased().contains(".m3u8")
        let item = Item(id: UUID(), name: FileStore.sanitize(suggestedName), isHLS: isHLS)
        items.insert(item, at: 0)

        if isHLS {
            var assetOptions: [String: Any] = [AVURLAssetHTTPCookiesKey: relevantCookies]
            if !headers.isEmpty {
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            let asset = AVURLAsset(url: url, options: assetOptions)
            let downloadOptions: [String: Any] = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 50_000_000]
            guard let task = hlsSession.makeAssetDownloadTask(asset: asset,
                                                              assetTitle: item.name,
                                                              assetArtworkData: nil,
                                                              options: downloadOptions) else {
                update(item.id) { $0.state = .failed("Akış indirmesi başlatılamadı") }
                return
            }
            task.taskDescription = describe(item)
            tasks[item.id] = task
            task.resume()
        } else {
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            for (key, value) in HTTPCookie.requestHeaderFields(with: relevantCookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let task = fileSession.downloadTask(with: request)
            task.taskDescription = describe(item)
            tasks[item.id] = task
            task.resume()
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    func notifyLibraryChanged() {
        libraryVersion += 1
    }

    func storeBackgroundCompletion(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletions[identifier] = handler
    }

    // MARK: - Yardımcılar

    private func describe(_ item: Item) -> String {
        "\(item.id.uuidString)|\(item.name)"
    }

    /// Görev açıklamasından öğeyi bulur; uygulama yeniden açıldıysa öğeyi yeniden oluşturur
    @discardableResult
    private func itemID(for task: URLSessionTask, isHLS: Bool) -> UUID {
        let parts = (task.taskDescription ?? "").split(separator: "|", maxSplits: 1).map(String.init)
        let id = parts.first.flatMap { UUID(uuidString: $0) } ?? UUID()
        if !items.contains(where: { $0.id == id }) {
            let name = parts.count > 1 ? parts[1] : "video"
            items.insert(Item(id: id, name: name, isHLS: isHLS), at: 0)
        }
        tasks[id] = task
        return id
    }

    private func name(for id: UUID) -> String {
        items.first(where: { $0.id == id })?.name ?? "video"
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func restoreRunningTasks() {
        fileSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                tasks.forEach { self?.itemID(for: $0, isHLS: false) }
            }
        }
        hlsSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                tasks.forEach { self?.itemID(for: $0, isHLS: true) }
            }
        }
    }

    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func fileExtension(for response: URLResponse?, url: URL?) -> String {
        if let mime = response?.mimeType?.lowercased() {
            if mime.contains("mp4") { return "mp4" }
            if mime.contains("quicktime") { return "mov" }
            if mime.contains("webm") { return "webm" }
            if mime == "audio/mpeg" { return "mp3" }
            if mime.contains("x-m4a") || mime == "audio/mp4" { return "m4a" }
        }
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 5 {
            return ext
        }
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 5 { return ext }
        }
        return "mp4"
    }

    // MARK: - HLS dönüştürme (arka planda yarım kalırsa bir sonraki açılışta tamamlanır)

    private func pendingConversions() -> [[String: String]] {
        UserDefaults.standard.array(forKey: pendingKey) as? [[String: String]] ?? []
    }

    private func setPendingConversions(_ list: [[String: String]]) {
        UserDefaults.standard.set(list, forKey: pendingKey)
    }

    private func addPending(path: String, name: String) {
        var list = pendingConversions().filter { $0["path"] != path }
        list.append(["path": path, "name": name])
        setPendingConversions(list)
    }

    private func removePending(path: String) {
        setPendingConversions(pendingConversions().filter { $0["path"] != path })
    }

    private func resumePendingConversions() {
        for entry in pendingConversions() {
            guard let path = entry["path"] else { continue }
            let location = FileStore.fromHomeRelative(path)
            guard FileManager.default.fileExists(atPath: location.path) else {
                removePending(path: path)
                continue
            }
            guard !convertingPaths.contains(path) else { continue }
            let item = Item(id: UUID(), name: entry["name"] ?? "video", isHLS: true, progress: 1, state: .converting)
            items.insert(item, at: 0)
            convert(location: location, itemID: item.id, name: item.name)
        }
    }

    private func convert(location: URL, itemID: UUID, name: String) {
        let path = FileStore.relativeToHome(location)
        guard !convertingPaths.contains(path) else { return }
        convertingPaths.insert(path)
        addPending(path: path, name: name)
        update(itemID) { $0.state = .converting }

        let activity = BackgroundActivity(name: "yakala-donustur")
        let destination = FileStore.uniqueURL(in: FileStore.downloads, baseName: name, ext: "mp4")

        Task {
            do {
                _ = try await MediaExporter.exportToMP4(source: location, destination: destination)
                try? FileManager.default.removeItem(at: location)
                DispatchQueue.main.async {
                    self.convertingPaths.remove(path)
                    self.removePending(path: path)
                    self.update(itemID) {
                        $0.state = .finished
                        $0.progress = 1
                    }
                    self.libraryVersion += 1
                    activity.end()
                }
            } catch {
                DispatchQueue.main.async {
                    self.convertingPaths.remove(path)
                    self.update(itemID) { $0.state = .failed("Dönüştürme hatası: \(error.localizedDescription)") }
                    activity.end()
                }
            }
        }
    }
}

// MARK: - Normal dosya indirmeleri

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = itemID(for: downloadTask, isHLS: false)
        update(id) {
            $0.bytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                $0.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = itemID(for: downloadTask, isHLS: false)

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            update(id) { $0.state = .failed("Sunucu indirmeye izin vermedi (\(http.statusCode))") }
            return
        }

        let ext = Self.fileExtension(for: downloadTask.response, url: downloadTask.originalRequest?.url)
        let destination = FileStore.uniqueURL(in: FileStore.downloads, baseName: name(for: id), ext: ext)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            update(id) {
                $0.state = .finished
                $0.progress = 1
            }
            libraryVersion += 1
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let isHLS = session === hlsSession
        let id = itemID(for: task, isHLS: isHLS)
        tasks[id] = nil

        if isHLS {
            let location = hlsLocations.removeValue(forKey: task.taskIdentifier)
            if let error {
                if let location { try? FileManager.default.removeItem(at: location) }
                update(id) { $0.state = .failed(Self.message(for: error)) }
                return
            }
            guard let location else {
                update(id) { $0.state = .failed("İndirilen akış bulunamadı") }
                return
            }
            convert(location: location, itemID: id, name: name(for: id))
            return
        }

        if let error {
            update(id) { $0.state = .failed(Self.message(for: error)) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let handler = backgroundCompletions.removeValue(forKey: identifier) else { return }
        handler()
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return "İptal edildi"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return "İnternet bağlantısı yok"
        }
        return error.localizedDescription
    }
}

// MARK: - HLS akış indirmeleri

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        hlsLocations[assetDownloadTask.taskIdentifier] = location
    }

    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        let id = itemID(for: assetDownloadTask, isHLS: true)
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) }
        let expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expected > 0, expected.isFinite else { return }
        update(id) { $0.progress = min(1, loaded / expected) }
    }
}

/// Uygulama arka plana geçince dönüştürmenin bitmesi için iOS'tan ek süre ister
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
