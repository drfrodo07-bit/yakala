import Foundation

/// HLS (m3u8) oynatma listelerini ayrıştırır
enum HLSPlaylistError: LocalizedError {
    case notPlaylist
    case live
    case noSegments
    case unsupportedEncryption(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notPlaylist: return "Akış listesi okunamadı."
        case .live: return "Canlı yayınlar indirilemez."
        case .noSegments: return "Akışta video parçası bulunamadı."
        case .unsupportedEncryption(let method): return "Bu akış desteklenmeyen bir şifreleme kullanıyor (\(method))."
        case .http(let code): return "Sunucu akışı vermedi (\(code))."
        }
    }
}

struct HLSByteRange: Codable, Equatable {
    var length: Int
    var offset: Int

    var headerValue: String {
        "bytes=\(offset)-\(offset + length - 1)"
    }
}

struct HLSKeyInfo: Equatable {
    var method: String
    var url: URL?
    var iv: Data?
}

struct HLSParsedSegment {
    var url: URL
    var duration: Double
    var sequence: Int
    var byteRange: HLSByteRange?
    var key: HLSKeyInfo?
    var discontinuity: Bool
}

struct HLSVariantInfo {
    var url: URL
    var bandwidth: Int
    var audioGroup: String?
}

struct HLSAudioRendition {
    var groupID: String
    var url: URL?
    var isDefault: Bool
}

struct HLSMediaPlaylist {
    var segments: [HLSParsedSegment]
    var initSegment: URL?
    var initByteRange: HLSByteRange?
    var initKey: HLSKeyInfo?
    var isLive: Bool
}

enum HLSPlaylistParser {
    /// Bir master listedeki varyantları ve ses seçeneklerini ayrıştırır; liste master değilse nil döner
    static func parseMaster(_ text: String, base: URL) -> (variants: [HLSVariantInfo], audio: [HLSAudioRendition])? {
        guard text.contains("#EXT-X-STREAM-INF") else { return nil }
        var variants: [HLSVariantInfo] = []
        var audio: [HLSAudioRendition] = []
        var pendingAttributes: [String: String]?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingAttributes = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if attrs["TYPE"]?.uppercased() == "AUDIO", let group = attrs["GROUP-ID"] {
                    let url = attrs["URI"].flatMap { resolve($0, base: base) }
                    audio.append(HLSAudioRendition(groupID: group, url: url, isDefault: attrs["DEFAULT"]?.uppercased() == "YES"))
                }
            } else if !line.hasPrefix("#"), let attrs = pendingAttributes {
                if let url = resolve(line, base: base) {
                    let bandwidth = Int(attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"] ?? "0") ?? 0
                    variants.append(HLSVariantInfo(url: url, bandwidth: bandwidth, audioGroup: attrs["AUDIO"]))
                }
                pendingAttributes = nil
            }
        }
        return (variants, audio)
    }

    static func parseMedia(_ text: String, base: URL) throws -> HLSMediaPlaylist {
        guard text.contains("#EXTINF") else { throw HLSPlaylistError.notPlaylist }

        var segments: [HLSParsedSegment] = []
        var sequence = 0
        var currentKey: HLSKeyInfo?
        var pendingDuration: Double?
        var pendingRange: HLSByteRange?
        var pendingDiscontinuity = false
        var lastRangeEnd: [URL: Int] = [:]
        var initSegment: URL?
        var initRange: HLSByteRange?
        var initKey: HLSKeyInfo?
        var hasEndList = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = (attrs["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    currentKey = nil
                } else {
                    currentKey = HLSKeyInfo(method: method,
                                            url: attrs["URI"].flatMap { resolve($0, base: base) },
                                            iv: attrs["IV"].flatMap { hexData($0) })
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if initSegment == nil, let uri = attrs["URI"] {
                    initSegment = resolve(uri, base: base)
                    initRange = attrs["BYTERANGE"].flatMap { parseRange($0, previousEnd: 0) }
                    initKey = currentKey
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), previousEnd: nil)
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                guard let duration = pendingDuration, let url = resolve(line, base: base) else { continue }
                var range = pendingRange
                if var r = range, r.offset < 0 {
                    r.offset = lastRangeEnd[url] ?? 0
                    range = r
                }
                if let r = range {
                    lastRangeEnd[url] = r.offset + r.length
                }
                segments.append(HLSParsedSegment(url: url,
                                                 duration: duration,
                                                 sequence: sequence,
                                                 byteRange: range,
                                                 key: currentKey,
                                                 discontinuity: pendingDiscontinuity))
                sequence += 1
                pendingDuration = nil
                pendingRange = nil
                pendingDiscontinuity = false
            }
        }

        if segments.isEmpty { throw HLSPlaylistError.noSegments }
        return HLSMediaPlaylist(segments: segments,
                                initSegment: initSegment,
                                initByteRange: initRange,
                                initKey: initKey,
                                isLive: !hasEndList)
    }

    // MARK: Yardımcılar

    static func resolve(_ uri: String, base: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let relative = URL(string: trimmed, relativeTo: base) {
            return relative.absoluteURL
        }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: encoded, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    /// "length@offset" biçimini ayrıştırır; offset yoksa -1 (bir önceki parçanın sonundan devam)
    static func parseRange(_ value: String, previousEnd: Int?) -> HLSByteRange? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let length = parts.first.flatMap({ Int($0) }) else { return nil }
        let offset = parts.count > 1 ? (Int(parts[1]) ?? 0) : (previousEnd ?? -1)
        return HLSByteRange(length: length, offset: offset)
    }

    static func hexData(_ value: String) -> Data? {
        var hex = value.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if hex.count % 2 == 1 { hex = "0" + hex }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        // IV 16 bayt olmalı; kısaysa başını sıfırla doldur
        if data.count < 16 {
            data = Data(repeating: 0, count: 16 - data.count) + data
        }
        return data.suffix(16)
    }

    /// Tırnak içindeki virgülleri dikkate alarak KEY=VALUE listesini ayrıştırır
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        func commit() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty {
                result[k] = value.trimmingCharacters(in: .whitespaces)
            }
            key = ""
            value = ""
            readingKey = true
        }

        for character in text {
            if readingKey {
                if character == "=" {
                    readingKey = false
                } else if character == "," {
                    commit()
                } else {
                    key.append(character)
                }
            } else {
                if character == "\"" {
                    inQuotes.toggle()
                } else if character == "," && !inQuotes {
                    commit()
                } else {
                    value.append(character)
                }
            }
        }
        commit()
        return result
    }
}
