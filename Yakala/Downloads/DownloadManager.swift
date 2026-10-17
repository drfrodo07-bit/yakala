import Foundation
import Combine
import UIKit

/// Hızlı ve arka planda devam eden indirme yöneticisi.
/// - Dosyalar 4 MB'lık parçalara bölünür, akışlar (HLS) parça parça indirilir; hepsi aynı anda çok bağlantıyla.
/// - Uygulama öndeyken hızlı oturum, arka plana geçince iOS'un arka plan indiricisi kullanılır.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let backgroundSessionID = "com.yakala.app.parts"
    static let connectionsKey = "yakala.connections"

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case preparing
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
        var speed: Double = 0
        var state: State = .preparing

        var isActive: Bool {
            switch state {
            case .preparing, .running, .converting: return true
            default: return false
            }
        }

        var isFailed: Bool {
            if case .failed = state { return true }
            return false
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var libraryVersion = 0

    var activeCount: Int {
        items.filter { $0.isActive }.count
    }

    static var connections: Int {
        let value = UserDefaults.standard.integer(forKey: connectionsKey)
        return value > 0 ? value : 8
    }

    private var foregroundSession: URLSession!
    private var backgroundSession: URLSession!
    private var jobs: [UUID: DownloadJob] = [:]
    private var doneCounts: [UUID: Int] = [:]
    private var completedBytes: [UUID: Int64] = [:]
    private var inflightBytes: [String: Int64] = [:]
    private var attempts: [String: Int] = [:]
    private var tasksByKey: [String: URLSessionTask] = [:]
    private var backgroundKeys: Set<String> = []
    private var badResponseKeys: Set<String> = []
    private var assembling: Set<UUID> = []
    private var lastSpeedBytes: [UUID: Int64] = [:]
    private var backgroundCompletions: [String: () -> Void] = [:]
    private var isInBackground = false
    private var speedTimer: Timer?

    private override init() {
        super.init()
        foregroundSession = Self.makeForegroundSession(delegate: self)

        let background = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        background.sessionSendsLaunchEvents = true
        background.isDiscretionary = false
        background.allowsCellularAccess = true
        background.httpMaximumConnectionsPerHost = Self.connections
        backgroundSession = URLSession(configuration: background, delegate: self, delegateQueue: .main)

        isInBackground = UIApplication.shared.applicationState == .background

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        restoreJobs()

        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateSpeeds()
        }
    }

    private static func makeForegroundSession(delegate: URLSessionDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = connections
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
    }

    // MARK: - Genel arayüz

    func start(url: URL, suggestedName: String, referer: URL?, userAgent: String?, cookies: [HTTPCookie]) {
        let lower = url.absoluteString.lowercased()
        let isHLS = lower.contains(".m3u8") || lower.contains("m3u8?")

        var headers: [String: String] = [:]
        if let referer {
            headers["Referer"] = referer.absoluteString
            if isHLS, let scheme = referer.scheme, let host = referer.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        let relevantCookies = cookies.filter { Self.cookie($0, matches: url) }
        headers.merge(HTTPCookie.requestHeaderFields(with: relevantCookies)) { $1 }

        let id = UUID()
        let name = FileStore.sanitize(suggestedName)
        items.insert(Item(id: id, name: name, isHLS: isHLS, state: .preparing), at: 0)

        Task {
            do {
                let job: DownloadJob
                if isHLS {
                    job = try await DownloadJobStore.createHLS(id: id, from: url, name: name, headers: headers)
                } else {
                    job = try await DownloadJobStore.createFile(id: id, from: url, name: name, headers: headers)
                }
                await MainActor.run { self.register(job) }
            } catch {
                await MainActor.run {
                    DownloadJobStore.delete(id)
                    self.update(id) { $0.state = .failed(Self.message(for: error)) }
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        cancelTasks(of: id)
        jobs[id] = nil
        DownloadJobStore.delete(id)
        update(id) { $0.state = .failed("İptal edildi") }
    }

    func retry(_ id: UUID) {
        guard var job = jobs[id] ?? DownloadJobStore.load(id) else { return }
        job.state = .downloading
        job.failureMessage = nil
        DownloadJobStore.save(job)
        for part in job.allDownloadParts {
            attempts[key(job.id, part)] = nil
        }
        register(job)
    }

    func canRetry(_ id: UUID) -> Bool {
        jobs[id] != nil || DownloadJobStore.load(id) != nil
    }

    func remove(_ id: UUID) {
        cancelTasks(of: id)
        jobs[id] = nil
        DownloadJobStore.delete(id)
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        for item in items where !item.isActive {
            if item.isFailed {
                jobs[item.id] = nil
                DownloadJobStore.delete(item.id)
            }
        }
        items.removeAll { !$0.isActive }
    }

    func notifyLibraryChanged() {
        libraryVersion += 1
    }

    func storeBackgroundCompletion(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletions[identifier] = handler
    }

    /// Ayarlarda bağlantı sayısı değişince yeni hızlı oturum aç (süren indirmeler eskisinde biter)
    func connectionsDidChange() {
        foregroundSession.finishTasksAndInvalidate()
        foregroundSession = Self.makeForegroundSession(delegate: self)
    }

    // MARK: - İş yönetimi

    private func key(_ jobID: UUID, _ part: HLSPart) -> String {
        "\(jobID.uuidString)|\(part.fileName)"
    }

    private func parse(_ key: String?) -> (jobID: UUID, fileName: String)? {
        guard let key else { return nil }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
        return (id, parts[1])
    }

    private func register(_ job: DownloadJob) {
        jobs[job.id] = job
        let total = job.allDownloadParts.count
        let missing = DownloadJobStore.missingParts(of: job)
        doneCounts[job.id] = total - missing.count
        completedBytes[job.id] = DownloadJobStore.downloadedBytes(of: job)

        if !items.contains(where: { $0.id == job.id }) {
            items.insert(Item(id: job.id, name: job.name, isHLS: job.kind == .hls), at: 0)
        }
        update(job.id) {
            $0.isHLS = job.kind == .hls
            $0.state = .running
        }
        refreshProgress(job.id)
        schedule(job)
    }

    private func schedule(_ job: DownloadJob) {
        guard job.state == .downloading else { return }
        let missing = DownloadJobStore.missingParts(of: job)
        if missing.isEmpty {
            assemble(job)
            return
        }
        let session: URLSession = isInBackground ? backgroundSession : foregroundSession
        for part in missing {
            let partKey = key(job.id, part)
            guard tasksByKey[partKey] == nil else { continue }
            startTask(for: part, job: job, key: partKey, session: session)
        }
    }

    private func startTask(for part: HLSPart, job: DownloadJob, key partKey: String, session: URLSession) {
        var request = URLRequest(url: part.url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        job.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let range = part.byteRange {
            request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = partKey
        tasksByKey[partKey] = task
        if session === backgroundSession {
            backgroundKeys.insert(partKey)
        } else {
            backgroundKeys.remove(partKey)
        }
        task.resume()
    }

    private func cancelTasks(of jobID: UUID) {
        let prefix = jobID.uuidString + "|"
        for (partKey, task) in tasksByKey where partKey.hasPrefix(prefix) {
            tasksByKey[partKey] = nil
            inflightBytes[partKey] = nil
            task.cancel()
        }
    }

    private func part(named fileName: String, in job: DownloadJob) -> HLSPart? {
        job.allDownloadParts.first { $0.fileName == fileName }
    }

    private func handlePartFailure(key partKey: String, message: String) {
        guard let parsed = parse(partKey), let job = jobs[parsed.jobID], job.state == .downloading,
              let part = part(named: parsed.fileName, in: job) else { return }
        let count = (attempts[partKey] ?? 0) + 1
        attempts[partKey] = count
        if count <= 5 {
            let delay = Double(count) * 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let current = self.jobs[job.id], current.state == .downloading,
                      self.tasksByKey[partKey] == nil,
                      !DownloadJobStore.isDownloaded(part, job: job.id) else { return }
                let session: URLSession = self.isInBackground ? self.backgroundSession : self.foregroundSession
                self.startTask(for: part, job: current, key: partKey, session: session)
            }
        } else {
            fail(job.id, message: "Bazı parçalar indirilemedi (\(message)). Tekrar denemek için sola kaydır.")
        }
    }

    private func fail(_ id: UUID, message: String) {
        cancelTasks(of: id)
        if var job = jobs[id] {
            job.state = .failed
            job.failureMessage = message
            jobs[id] = job
            DownloadJobStore.save(job)
        }
        update(id) { $0.state = .failed(message) }
    }

    private func assemble(_ job: DownloadJob) {
        guard !assembling.contains(job.id) else { return }
        assembling.insert(job.id)

        var job = job
        job.state = .assembling
        jobs[job.id] = job
        DownloadJobStore.save(job)
        update(job.id) {
            $0.state = .converting
            $0.progress = 0
            $0.speed = 0
        }

        let activity = BackgroundActivity(name: "yakala-birlestir")
        let id = job.id
        let snapshot = job

        Task.detached(priority: .userInitiated) {
            defer { activity.end() }
            do {
                let output = FileStore.uniqueURL(in: FileStore.downloads, baseName: snapshot.name, ext: snapshot.fileExtension)
                if snapshot.kind == .hls {
                    _ = try await HLSRemuxer(job: snapshot).run(output: output) { value in
                        DispatchQueue.main.async {
                            self.update(id) { $0.progress = value }
                        }
                    }
                } else {
                    try DownloadJobStore.assembleFile(snapshot, to: output)
                }
                DownloadJobStore.delete(id)
                await MainActor.run {
                    self.assembling.remove(id)
                    self.jobs[id] = nil
                    self.update(id) {
                        $0.state = .finished
                        $0.progress = 1
                        $0.speed = 0
                    }
                    self.libraryVersion += 1
                }
            } catch {
                await MainActor.run {
                    self.assembling.remove(id)
                    if var failed = self.jobs[id] {
                        failed.state = .failed
                        failed.failureMessage = error.localizedDescription
                        self.jobs[id] = failed
                        DownloadJobStore.save(failed)
                    }
                    self.update(id) { $0.state = .failed(error.localizedDescription) }
                }
            }
        }
    }

    private func restoreJobs() {
        for job in DownloadJobStore.all() {
            var item = Item(id: job.id, name: job.name, isHLS: job.kind == .hls)
            switch job.state {
            case .failed:
                item.state = .failed(job.failureMessage ?? "İndirme tamamlanamadı")
                jobs[job.id] = job
            case .assembling, .downloading:
                item.state = .running
                jobs[job.id] = job
                doneCounts[job.id] = job.allDownloadParts.count - DownloadJobStore.missingParts(of: job).count
                completedBytes[job.id] = DownloadJobStore.downloadedBytes(of: job)
            }
            items.append(item)
        }

        backgroundSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in tasks {
                    if let description = task.taskDescription, self.parse(description) != nil {
                        self.tasksByKey[description] = task
                        self.backgroundKeys.insert(description)
                    }
                }
                for job in self.jobs.values {
                    switch job.state {
                    case .assembling:
                        var resumed = job
                        resumed.state = .downloading
                        self.jobs[job.id] = resumed
                        self.assemble(resumed)
                    case .downloading:
                        self.refreshProgress(job.id)
                        self.schedule(job)
                    case .failed:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Ön plan / arka plan geçişi

    @objc private func appDidEnterBackground() {
        isInBackground = true
        let activity = BackgroundActivity(name: "yakala-arka-plana-aktar")
        moveTasks(to: backgroundSession, from: foregroundSession)
        activity.end()
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        moveTasks(to: foregroundSession, from: backgroundSession)
    }

    /// Henüz bitmemiş parçaları diğer oturuma taşır
    private func moveTasks(to target: URLSession, from source: URLSession) {
        let movingToBackground = target === backgroundSession
        let moving = tasksByKey.filter { partKey, task in
            let isInBackgroundSession = backgroundKeys.contains(partKey)
            return isInBackgroundSession != movingToBackground && task.state != .completed
        }
        for (partKey, task) in moving {
            guard let parsed = parse(partKey), let job = jobs[parsed.jobID], job.state == .downloading,
                  let part = part(named: parsed.fileName, in: job) else { continue }
            tasksByKey[partKey] = nil
            inflightBytes[partKey] = nil
            task.cancel()
            startTask(for: part, job: job, key: partKey, session: target)
        }
    }

    // MARK: - İlerleme ve hız

    private func refreshProgress(_ id: UUID) {
        guard let job = jobs[id] else { return }
        let inflight = inflightBytes.filter { $0.key.hasPrefix(id.uuidString) }.values.reduce(0, +)
        let bytes = (completedBytes[id] ?? 0) + inflight
        let progress: Double
        if job.kind == .file, let total = job.totalBytes, total > 0 {
            progress = Double(bytes) / Double(total)
        } else {
            let total = max(job.allDownloadParts.count, 1)
            progress = Double(doneCounts[id] ?? 0) / Double(total)
        }
        update(id) {
            $0.bytes = bytes
            if $0.state == .running {
                $0.progress = min(progress, 1)
            }
        }
    }

    private func updateSpeeds() {
        for item in items where item.state == .running {
            refreshProgress(item.id)
            guard let current = items.first(where: { $0.id == item.id }) else { continue }
            let previous = lastSpeedBytes[item.id] ?? current.bytes
            let delta = max(current.bytes - previous, 0)
            lastSpeedBytes[item.id] = current.bytes
            update(item.id) {
                // Yumuşatılmış hız
                $0.speed = $0.speed == 0 ? Double(delta) : $0.speed * 0.6 + Double(delta) * 0.4
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: - Yardımcılar

    static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func fileExtension(mimeType: String?, url: URL?, suggestedName: String?) -> String {
        if let mime = mimeType?.lowercased() {
            if mime.contains("mp4") { return "mp4" }
            if mime.contains("quicktime") { return "mov" }
            if mime.contains("webm") { return "webm" }
            if mime == "audio/mpeg" { return "mp3" }
            if mime.contains("x-m4a") || mime == "audio/mp4" { return "m4a" }
            if mime.contains("zip") { return "zip" }
            if mime.contains("pdf") { return "pdf" }
        }
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty, ext.count <= 5 {
            return ext
        }
        if let suggestedName {
            let ext = (suggestedName as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 5 { return ext }
        }
        return "mp4"
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled: return "İptal edildi"
            case NSURLErrorNotConnectedToInternet: return "İnternet bağlantısı yok"
            case NSURLErrorTimedOut: return "Sunucu yanıt vermedi"
            default: break
            }
        }
        return error.localizedDescription
    }

    static func formattedSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/sn"
    }
}

// MARK: - URLSession olayları

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let partKey = downloadTask.taskDescription, tasksByKey[partKey] === downloadTask else { return }
        inflightBytes[partKey] = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let partKey = downloadTask.taskDescription,
              let parsed = parse(partKey),
              let job = jobs[parsed.jobID] ?? DownloadJobStore.load(parsed.jobID),
              let part = part(named: parsed.fileName, in: job) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            badResponseKeys.insert(partKey)
            return
        }

        let size = FileStore.fileSize(location)
        if let range = part.byteRange, size != Int64(range.length) {
            // Sunucu aralığı dikkate almadıysa veriyi kullanma
            badResponseKeys.insert(partKey)
            return
        }

        let destination = DownloadJobStore.fileURL(part, job: job.id)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            badResponseKeys.insert(partKey)
            return
        }

        if jobs[job.id] == nil {
            jobs[job.id] = job
        }
        inflightBytes[partKey] = nil
        completedBytes[job.id, default: 0] += size
        doneCounts[job.id, default: 0] += 1
        attempts[partKey] = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let partKey = task.taskDescription, let parsed = parse(partKey) else { return }
        // Eski (taşınmış veya iptal edilmiş) görevlerin olaylarını yok say
        if let current = tasksByKey[partKey], current !== task { return }
        tasksByKey[partKey] = nil
        inflightBytes[partKey] = nil
        backgroundKeys.remove(partKey)

        let wasBad = badResponseKeys.remove(partKey) != nil
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            handlePartFailure(key: partKey, message: Self.message(for: error))
            return
        }
        if wasBad {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            handlePartFailure(key: partKey, message: status > 0 ? "sunucu \(status)" : "eksik veri")
            return
        }

        guard let job = jobs[parsed.jobID], job.state == .downloading else { return }
        refreshProgress(job.id)
        if (doneCounts[job.id] ?? 0) >= job.allDownloadParts.count,
           DownloadJobStore.missingParts(of: job).isEmpty {
            assemble(job)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier,
              let handler = backgroundCompletions.removeValue(forKey: identifier) else { return }
        handler()
    }
}

/// Uygulama arka plana geçince işlemin bitmesi için iOS'tan ek süre ister
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
