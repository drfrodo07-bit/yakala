import Foundation

/// MPEG-TS içinden çıkarılan tek bir video karesi veya ses çerçevesi
struct MediaSample {
    enum Kind {
        case video
        case audio
    }

    var kind: Kind
    var data: Data
    /// 90 kHz zaman birimiyle
    var pts: Int64
    var dts: Int64
    var keyframe: Bool
}

enum VideoCodec {
    case h264
    case hevc
}

struct AACConfig: Equatable {
    var objectType: Int
    var sampleRateIndex: Int
    var channelConfig: Int

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    var sampleRate: Int {
        sampleRateIndex < Self.sampleRates.count ? Self.sampleRates[sampleRateIndex] : 44100
    }

    var channels: Int {
        channelConfig == 7 ? 8 : max(channelConfig, 1)
    }

    /// AudioSpecificConfig (2 bayt)
    var audioSpecificConfig: Data {
        let value = (objectType << 11) | (sampleRateIndex << 7) | (channelConfig << 3)
        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

/// Basit MPEG-TS ayrıştırıcı: H.264/H.265 video ve AAC (ADTS) ses
final class TSDemuxer {
    private(set) var videoCodec: VideoCodec?
    private(set) var parameterSets: [Data] = []   // H.264: [SPS, PPS]  HEVC: [VPS, SPS, PPS]
    private(set) var aacConfig: AACConfig?
    private(set) var hasAudioStream = false
    private(set) var hasVideoStream = false

    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var videoPES = Data()
    private var audioPES = Data()

    private var sps: Data?
    private var pps: Data?
    private var vps: Data?

    // MARK: - Sahte başlık (resim kılığındaki parçalar) temizleme

    /// TS paketlerinin gerçekten başladığı konumu bulur (bazı siteler parçaların başına sahte PNG ekler)
    static func transportStreamOffset(in data: Data) -> Int? {
        let count = data.count
        guard count >= 188 * 3 else { return data.first == 0x47 ? 0 : nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let limit = min(count - 188 * 2 - 1, 4_000_000)
            var index = 0
            while index <= limit {
                if bytes[index] == 0x47 && bytes[index + 188] == 0x47 && bytes[index + 376] == 0x47 {
                    return index
                }
                index += 1
            }
            return nil
        }
    }

    // MARK: - Besleme

    func feed(_ data: Data, emit: (MediaSample) -> Void) {
        guard let start = Self.transportStreamOffset(in: data) else { return }
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = start
            let count = bytes.count
            while index + 188 <= count {
                guard bytes[index] == 0x47 else {
                    // Senkronu kaybettik: bir sonraki geçerli paketi ara
                    index += 1
                    while index + 188 <= count && bytes[index] != 0x47 { index += 1 }
                    continue
                }
                processPacket(bytes, at: index, emit: emit)
                index += 188
            }
        }
    }

    /// Akışın sonunda yarım kalan son kareyi gönderir
    func flush(emit: (MediaSample) -> Void) {
        if !videoPES.isEmpty {
            finishVideoPES(emit: emit)
        }
        if !audioPES.isEmpty {
            finishAudioPES(emit: emit)
        }
    }

    private func processPacket(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, emit: (MediaSample) -> Void) {
        let payloadUnitStart = (bytes[offset + 1] & 0x40) != 0
        let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
        let adaptationControl = (bytes[offset + 3] >> 4) & 0x3

        var payloadStart = offset + 4
        if adaptationControl == 2 || adaptationControl == 3 {
            payloadStart += 1 + Int(bytes[offset + 4])
        }
        guard adaptationControl == 1 || adaptationControl == 3 else { return }
        let packetEnd = offset + 188
        guard payloadStart < packetEnd else { return }
        let payload = UnsafeBufferPointer(rebasing: bytes[payloadStart..<packetEnd])

        if pid == 0 {
            if payloadUnitStart { parsePAT(payload) }
        } else if let pmtPID, pid == pmtPID {
            if payloadUnitStart { parsePMT(payload) }
        } else if let videoPID, pid == videoPID {
            if payloadUnitStart && !videoPES.isEmpty {
                finishVideoPES(emit: emit)
            }
            if payloadUnitStart || !videoPES.isEmpty {
                videoPES.append(contentsOf: payload)
            }
        } else if let audioPID, pid == audioPID {
            if payloadUnitStart && !audioPES.isEmpty {
                finishAudioPES(emit: emit)
            }
            if payloadUnitStart || !audioPES.isEmpty {
                audioPES.append(contentsOf: payload)
            }
        }
    }

    // MARK: - Program tabloları

    private func parsePAT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard payload.count > 1 else { return }
        let pointer = Int(payload[0])
        let tableStart = 1 + pointer
        guard payload.count >= tableStart + 8 else { return }
        let sectionLength = (Int(payload[tableStart + 1] & 0x0F) << 8) | Int(payload[tableStart + 2])
        let entriesEnd = min(tableStart + 3 + sectionLength - 4, payload.count)
        var index = tableStart + 8
        while index + 4 <= entriesEnd {
            let program = (Int(payload[index]) << 8) | Int(payload[index + 1])
            let pid = (Int(payload[index + 2] & 0x1F) << 8) | Int(payload[index + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            index += 4
        }
    }

    private func parsePMT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard payload.count > 1 else { return }
        let pointer = Int(payload[0])
        let t = 1 + pointer
        guard payload.count >= t + 12 else { return }
        let sectionLength = (Int(payload[t + 1] & 0x0F) << 8) | Int(payload[t + 2])
        let programInfoLength = (Int(payload[t + 10] & 0x0F) << 8) | Int(payload[t + 11])
        var index = t + 12 + programInfoLength
        let end = min(t + 3 + sectionLength - 4, payload.count)
        while index + 5 <= end {
            let streamType = payload[index]
            let pid = (Int(payload[index + 1] & 0x1F) << 8) | Int(payload[index + 2])
            let infoLength = (Int(payload[index + 3] & 0x0F) << 8) | Int(payload[index + 4])
            switch streamType {
            case 0x1B:
                if videoPID == nil { videoPID = pid; videoCodec = .h264; hasVideoStream = true }
            case 0x24:
                if videoPID == nil { videoPID = pid; videoCodec = .hevc; hasVideoStream = true }
            case 0x0F:
                if audioPID == nil { audioPID = pid; hasAudioStream = true }
            default:
                break
            }
            index += 5 + infoLength
        }
    }

    // MARK: - PES

    private static func readTimestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        let part1 = Int64((b[i] >> 1) & 0x07) << 30
        let part2 = Int64(b[i + 1]) << 22
        let part3 = Int64(b[i + 2] >> 1) << 15
        let part4 = Int64(b[i + 3]) << 7
        let part5 = Int64(b[i + 4] >> 1)
        return part1 | part2 | part3 | part4 | part5
    }

    /// PES başlığını ayrıştırır: (veri başlangıcı, PTS, DTS)
    private static func parsePESHeader(_ b: [UInt8]) -> (start: Int, pts: Int64?, dts: Int64?)? {
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
        let flags = b[7] >> 6
        let headerLength = Int(b[8])
        let start = 9 + headerLength
        guard b.count >= start else { return nil }
        var pts: Int64?
        var dts: Int64?
        if flags & 0x2 != 0, b.count >= 14 {
            pts = readTimestamp(b, 9)
        }
        if flags == 0x3, b.count >= 19 {
            dts = readTimestamp(b, 14)
        }
        return (start, pts, dts)
    }

    private func finishVideoPES(emit: (MediaSample) -> Void) {
        let bytes = [UInt8](videoPES)
        videoPES.removeAll(keepingCapacity: true)
        guard let header = Self.parsePESHeader(bytes), let pts = header.pts, let codec = videoCodec else { return }
        let dts = header.dts ?? pts

        var sample = Data()
        var keyframe = false

        for nal in Self.splitNALUnits(bytes, from: header.start) {
            guard let first = nal.first else { continue }
            switch codec {
            case .h264:
                let type = Int(first & 0x1F)
                switch type {
                case 7: sps = Data(nal); continue
                case 8: pps = Data(nal); continue
                case 9, 12: continue // AUD, dolgu
                case 5: keyframe = true
                default: break
                }
            case .hevc:
                let type = Int((first >> 1) & 0x3F)
                switch type {
                case 32: vps = Data(nal); continue
                case 33: sps = Data(nal); continue
                case 34: pps = Data(nal); continue
                case 35, 38: continue // AUD, dolgu
                case 16...21: keyframe = true
                default: break
                }
            }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample.append(contentsOf: nal)
        }

        updateParameterSets()
        guard !sample.isEmpty else { return }
        emit(MediaSample(kind: .video, data: sample, pts: pts, dts: dts, keyframe: keyframe))
    }

    private func updateParameterSets() {
        guard let codec = videoCodec, parameterSets.isEmpty else { return }
        switch codec {
        case .h264:
            if let sps, let pps { parameterSets = [sps, pps] }
        case .hevc:
            if let vps, let sps, let pps { parameterSets = [vps, sps, pps] }
        }
    }

    /// Annex B bayt akışını NAL birimlerine böler
    private static func splitNALUnits(_ b: [UInt8], from start: Int) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var index = start
        var unitStart: Int?
        let count = b.count

        while index + 2 < count {
            if b[index] == 0 && b[index + 1] == 0 && b[index + 2] == 1 {
                if let s = unitStart {
                    var end = index
                    while end > s && b[end - 1] == 0 { end -= 1 }
                    if end > s { units.append(b[s..<end]) }
                }
                index += 3
                unitStart = index
            } else {
                index += 1
            }
        }
        if let s = unitStart, s < count {
            var end = count
            while end > s && b[end - 1] == 0 { end -= 1 }
            if end > s { units.append(b[s..<end]) }
        }
        return units
    }

    private func finishAudioPES(emit: (MediaSample) -> Void) {
        let bytes = [UInt8](audioPES)
        audioPES.removeAll(keepingCapacity: true)
        guard let header = Self.parsePESHeader(bytes), let pts = header.pts else { return }
        parseADTS(bytes, from: header.start, basePTS: pts, emit: emit)
    }

    /// ADTS çerçevelerini ham AAC örneklerine ayırır
    func parseADTS(_ b: [UInt8], from start: Int, basePTS: Int64, emit: (MediaSample) -> Void) {
        var index = start
        var frameNumber: Int64 = 0
        while index + 7 <= b.count {
            guard b[index] == 0xFF, (b[index + 1] & 0xF0) == 0xF0 else {
                index += 1
                continue
            }
            let protectionAbsent = (b[index + 1] & 0x01) == 1
            let profile = Int((b[index + 2] >> 6) & 0x03)
            let sampleRateIndex = Int((b[index + 2] >> 2) & 0x0F)
            let channelConfig = (Int(b[index + 2] & 0x01) << 2) | Int((b[index + 3] >> 6) & 0x03)
            let frameLength = (Int(b[index + 3] & 0x03) << 11) | (Int(b[index + 4]) << 3) | Int((b[index + 5] >> 5) & 0x07)
            let headerLength = protectionAbsent ? 7 : 9
            guard frameLength > headerLength, index + frameLength <= b.count else { break }

            let config = AACConfig(objectType: profile + 1, sampleRateIndex: sampleRateIndex, channelConfig: channelConfig)
            if aacConfig == nil { aacConfig = config }
            hasAudioStream = true

            let rate = Int64(config.sampleRate)
            let pts = basePTS + (frameNumber * 1024 * 90_000 + rate / 2) / rate
            let raw = Data(b[(index + headerLength)..<(index + frameLength)])
            emit(MediaSample(kind: .audio, data: raw, pts: pts, dts: pts, keyframe: true))

            frameNumber += 1
            index += frameLength
        }
    }

    // MARK: - Paketlenmiş ses (ID3 + ADTS, ayrı ses listeleri için)

    func feedPackedAudio(_ data: Data, fallbackPTS: Int64, emit: (MediaSample) -> Void) -> Int64 {
        let bytes = [UInt8](data)
        var start = 0
        var basePTS = fallbackPTS

        // ID3 etiketi: com.apple.streaming.transportStreamTimestamp
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14) | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
            let tagEnd = min(10 + size, bytes.count)
            let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8)
            if let range = Self.find(owner, in: bytes, upTo: tagEnd) {
                let tsStart = range + owner.count + 1
                if tsStart + 8 <= tagEnd {
                    var value: Int64 = 0
                    for i in 0..<8 { value = (value << 8) | Int64(bytes[tsStart + i]) }
                    basePTS = value & 0x1_FFFF_FFFF
                }
            }
            start = tagEnd
        }

        var lastPTS = basePTS
        parseADTS(bytes, from: start, basePTS: basePTS) { sample in
            lastPTS = sample.pts
            emit(sample)
        }
        let rate = Int64(aacConfig?.sampleRate ?? 44100)
        return lastPTS + (1024 * 90_000) / rate
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], upTo end: Int) -> Int? {
        guard needle.count <= end else { return nil }
        var index = 0
        while index + needle.count <= end {
            if haystack[index] == needle[0] && Array(haystack[index..<(index + needle.count)]) == needle {
                return index
            }
            index += 1
        }
        return nil
    }
}
