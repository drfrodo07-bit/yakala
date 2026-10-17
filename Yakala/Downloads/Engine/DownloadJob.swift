import Foundation

/// İndirilecek tek bir parça (akış parçası, dosya aralığı, başlangıç parçası veya şifre anahtarı)
struct HLSPart: Codable, Equatable {
    var url: URL
    var fileName: String
    var byteRange: HLSByteRange?
    var keyIndex: Int?
    var iv: Data?
    var discontinuity: Bool = false
    /// Tahmini boyut (bayt) — hız ve ilerleme hesabı için
    var expectedBytes: Int64?
}

/// Diske kaydedilen indirme işi. Uygulama kapanıp açılsa da kaldığı yerden devam eder.
/// Normal dosyalar parçalara bölünerek, akışlar (HLS) parça parça paralel indirilir.
struct DownloadJob: Codable {
    enum Kind: String, Codable {
        case hls
        case file
    }

    enum State: String, Codable {
        case downloading
        case assembling
        case failed
    }

    var id: UUID
    var kind: Kind
    var name: String
    var fileExtension: String
    var headers: [String: String]
    var videoParts: [HLSPart]
    var audioParts: [HLSPart]
    var videoInit: HLSPart?
    var audioInit: HLSPart?
    var keys: [HLSPart]
    var audioIsPacked: Bool
    var totalBytes: Int64?
    var state: State
    var failureMessage: String?
    var created: Date

    var allDownloadParts: [HLSPart] {
        var parts = videoParts + audioParts
        if let videoInit { parts.append(videoInit) }
        if let audioInit { parts.append(audioInit) }
        return parts
    }
}

enum DownloadJobStore {
    static let chunkSize: Int64 = 4 * 1024 * 1024

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileStore.ensure(base.appendingPathComponent("DownloadJobs", isDirectory: true))
    }

    static func folder(for id: UUID) -> URL {
        FileStore.ensure(root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func fileURL(_ part: HLSPart, job id: UUID) -> URL {
        folder(for: id).appendingPathComponent(part.fileName)
    }

    static func save(_ job: DownloadJob) {
        let url = folder(for: job.id).appendingPathComponent("job.json")
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load(_ id: UUID) -> DownloadJob? {
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DownloadJob.self, from: data)
    }

    static func all() -> [DownloadJob] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            UUID(uuidString: folder.lastPathComponent).flatMap { load($0) }
        }
        .sorted { $0.created < $1.created }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }

    static func isDownloaded(_ part: HLSPart, job id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(part, job: id).path)
    }

    static func missingParts(of job: DownloadJob) -> [HLSPart] {
        job.allDownloadParts.filter { !isDownloaded($0, job: job.id) }
    }

    static func downloadedBytes(of job: DownloadJob) -> Int64 {
        job.allDownloadParts.reduce(0) { total, part in
            total + (isDownloaded(part, job: job.id) ? FileStore.fileSize(fileURL(part, job: job.id)) : 0)
        }
    }

    // MARK: - Normal dosya: aralıklara bölerek paralel indirme

    /// Sunucu aralıklı indirmeyi destekliyorsa dosyayı 4 MB'lık parçalara böler
    static func createFile(id: UUID, from url: URL, name: String, headers: [String: String]) async throws -> DownloadJob {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        var totalBytes: Int64?
        var supportsRanges = false
        var mimeType: String?
        var suggestedName: String?

        if let result = try? await URLSession.shared.data(for: request), let http = result.1 as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) {
                throw HLSPlaylistError.http(http.statusCode)
            }
            mimeType = http.mimeType
            suggestedName = http.suggestedFilename
            if http.statusCode == 206,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let totalText = range.split(separator: "/").last,
               let total = Int64(totalText.trimmingCharacters(in: .whitespaces)) {
                totalBytes = total
                supportsRanges = true
            } else if http.expectedContentLength > 0 {
                totalBytes = http.expectedContentLength
            }
        }

        let ext = DownloadManager.fileExtension(mimeType: mimeType, url: url, suggestedName: suggestedName)
        var parts: [HLSPart] = []
        if supportsRanges, let total = totalBytes, total > chunkSize {
            var offset: Int64 = 0
            var index = 0
            while offset < total {
                let length = min(chunkSize, total - offset)
                parts.append(HLSPart(url: url,
                                     fileName: String(format: "c_%05d.part", index),
                                     byteRange: HLSByteRange(length: Int(length), offset: Int(offset)),
                                     expectedBytes: length))
                offset += length
                index += 1
            }
        } else {
            parts = [HLSPart(url: url, fileName: "c_00000.part", expectedBytes: totalBytes)]
        }

        let job = DownloadJob(id: id,
                              kind: .file,
                              name: name,
                              fileExtension: ext,
                              headers: headers,
                              videoParts: parts,
                              audioParts: [],
                              videoInit: nil,
                              audioInit: nil,
                              keys: [],
                              audioIsPacked: false,
                              totalBytes: totalBytes,
                              state: .downloading,
                              failureMessage: nil,
                              created: Date())
        save(job)
        return job
    }

    /// Dosya parçalarını sırayla birleştirir
    static func assembleFile(_ job: DownloadJob, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        if job.videoParts.count == 1, let only = job.videoParts.first {
            try FileManager.default.moveItem(at: fileURL(only, job: job.id), to: output)
            return
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for part in job.videoParts {
            try autoreleasepool {
                let data = try Data(contentsOf: fileURL(part, job: job.id), options: .mappedIfSafe)
                try handle.write(contentsOf: data)
            }
        }
    }

    // MARK: - HLS akışı

    /// Akış adresinden indirme işini hazırlar: listeleri okur, en yüksek kaliteyi seçer, anahtarları indirir
    static func createHLS(id: UUID, from url: URL, name: String, headers: [String: String]) async throws -> DownloadJob {
        var playlistURL = url
        var text = try await fetchText(url, headers: headers)
        var audioPlaylistURL: URL?

        if let master = HLSPlaylistParser.parseMaster(text, base: url) {
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSPlaylistError.noSegments
            }
            playlistURL = best.url
            if let group = best.audioGroup {
                let candidates = master.audio.filter { $0.groupID == group && $0.url != nil }
                audioPlaylistURL = (candidates.first(where: { $0.isDefault }) ?? candidates.first)?.url
            }
            text = try await fetchText(playlistURL, headers: headers)
        }

        let video = try HLSPlaylistParser.parseMedia(text, base: playlistURL)
        if video.isLive { throw HLSPlaylistError.live }

        var audio: HLSMediaPlaylist?
        if let audioPlaylistURL {
            let audioText = try await fetchText(audioPlaylistURL, headers: headers)
            audio = try HLSPlaylistParser.parseMedia(audioText, base: audioPlaylistURL)
        }

        var keyURLs: [URL] = []
        func keyIndex(for key: HLSKeyInfo?) throws -> Int? {
            guard let key else { return nil }
            guard key.method == "AES-128" else { throw HLSPlaylistError.unsupportedEncryption(key.method) }
            guard let keyURL = key.url else { return nil }
            if let existing = keyURLs.firstIndex(of: keyURL) { return existing }
            keyURLs.append(keyURL)
            return keyURLs.count - 1
        }

        func makeParts(_ playlist: HLSMediaPlaylist, prefix: String) throws -> [HLSPart] {
            var parts: [HLSPart] = []
            for (index, segment) in playlist.segments.enumerated() {
                let iv = segment.key?.iv ?? (segment.key != nil ? sequenceIV(segment.sequence) : nil)
                parts.append(HLSPart(url: segment.url,
                                     fileName: String(format: "%@_%05d.seg", prefix, index),
                                     byteRange: segment.byteRange,
                                     keyIndex: try keyIndex(for: segment.key),
                                     iv: iv,
                                     discontinuity: segment.discontinuity))
            }
            return parts
        }

        func makeInit(_ playlist: HLSMediaPlaylist?, prefix: String) throws -> HLSPart? {
            guard let playlist, let initURL = playlist.initSegment else { return nil }
            return HLSPart(url: initURL,
                           fileName: "\(prefix)_init.seg",
                           byteRange: playlist.initByteRange,
                           keyIndex: try keyIndex(for: playlist.initKey),
                           iv: playlist.initKey?.iv ?? (playlist.initKey != nil ? sequenceIV(0) : nil))
        }

        let videoParts = try makeParts(video, prefix: "v")
        let audioParts = try audio.map { try makeParts($0, prefix: "a") } ?? []
        let videoInit = try makeInit(video, prefix: "v")
        let audioInit = try makeInit(audio, prefix: "a")

        let audioIsPacked: Bool
        if let audio {
            let ext = audio.segments.first?.url.pathExtension.lowercased() ?? ""
            audioIsPacked = ["aac", "adts"].contains(ext)
        } else {
            audioIsPacked = false
        }

        let keys = keyURLs.enumerated().map { index, keyURL in
            HLSPart(url: keyURL, fileName: "key_\(index).bin")
        }

        let job = DownloadJob(id: id,
                              kind: .hls,
                              name: name,
                              fileExtension: "mp4",
                              headers: headers,
                              videoParts: videoParts,
                              audioParts: audioParts,
                              videoInit: videoInit,
                              audioInit: audioInit,
                              keys: keys,
                              audioIsPacked: audioIsPacked,
                              totalBytes: nil,
                              state: .downloading,
                              failureMessage: nil,
                              created: Date())

        // Anahtarlar küçüktür; hemen indir
        for key in keys {
            var request = URLRequest(url: key.url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HLSPlaylistError.http(http.statusCode)
            }
            try data.write(to: fileURL(key, job: id))
        }

        save(job)
        return job
    }

    static func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HLSPlaylistError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF") else {
            throw HLSPlaylistError.notPlaylist
        }
        return text
    }

    /// Akışın toplam süresini (saniye) hesaplar — yakalanan videoların reklam olup olmadığını anlamak için
    static func hlsDuration(of url: URL, headers: [String: String]) async -> Double? {
        guard var text = try? await fetchText(url, headers: headers) else { return nil }
        var base = url
        if let master = HLSPlaylistParser.parseMaster(text, base: url),
           let variant = master.variants.max(by: { $0.bandwidth < $1.bandwidth }) {
            base = variant.url
            guard let mediaText = try? await fetchText(variant.url, headers: headers) else { return nil }
            text = mediaText
        }
        guard let playlist = try? HLSPlaylistParser.parseMedia(text, base: base), !playlist.isLive else { return nil }
        return playlist.segments.reduce(0) { $0 + $1.duration }
    }

    /// IV belirtilmemişse parça sıra numarası kullanılır (HLS standardı)
    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        let value = UInt64(max(sequence, 0))
        for i in 0..<8 {
            iv[15 - i] = UInt8((value >> (UInt64(i) * 8)) & 0xFF)
        }
        return iv
    }
}
