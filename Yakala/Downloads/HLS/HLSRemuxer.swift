import Foundation
import AVFoundation
import CoreMedia
import CommonCrypto

enum HLSRemuxError: LocalizedError {
    case missingFile(String)
    case decryptFailed
    case noVideo
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "Video parçası eksik (\(name)). Tekrar dene."
        case .decryptFailed: return "Şifreli parça çözülemedi."
        case .noVideo: return "Akışta okunabilir video bulunamadı."
        case .writer(let message): return "MP4 oluşturulamadı: \(message)"
        }
    }
}

/// İndirilmiş HLS parçalarını tek bir MP4 dosyasında birleştirir (yeniden kodlamadan, hızlı)
final class HLSRemuxer {
    private let job: DownloadJob
    private var keys: [Int: Data] = [:]

    init(job: DownloadJob) {
        self.job = job
    }

    func run(output: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        for (index, key) in job.keys.enumerated() {
            let url = DownloadJobStore.fileURL(key, job: job.id)
            guard let data = try? Data(contentsOf: url) else { throw HLSRemuxError.missingFile(key.fileName) }
            keys[index] = data
        }

        if job.videoInit != nil {
            return try await remuxFragmentedMP4(output: output, progress: progress)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.remuxTransportStream(output: output, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Parça verisi (şifre çözme dahil)

    private func data(for part: HLSPart) throws -> Data {
        let url = DownloadJobStore.fileURL(part, job: job.id)
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw HLSRemuxError.missingFile(part.fileName)
        }
        guard let keyIndex = part.keyIndex, let key = keys[keyIndex] else { return raw }
        let iv = part.iv ?? Data(repeating: 0, count: 16)
        if let plain = Self.decrypt(raw, key: key, iv: iv, padding: true) { return plain }
        if let plain = Self.decrypt(raw, key: key, iv: iv, padding: false) { return plain }
        throw HLSRemuxError.decryptFailed
    }

    static func decrypt(_ data: Data, key: Data, iv: Data, padding: Bool) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let options = padding ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0)
        let status = output.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                options,
                                keyRaw.baseAddress, kCCKeySizeAES128,
                                ivRaw.baseAddress,
                                inRaw.baseAddress, data.count,
                                outRaw.baseAddress, outRaw.count,
                                &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - fMP4 (EXT-X-MAP) akışları

    private func remuxFragmentedMP4(output: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let videoInit = job.videoInit else { throw HLSRemuxError.noVideo }
        let folder = DownloadJobStore.folder(for: job.id)
        let videoFile = folder.appendingPathComponent("video_joined.mp4")
        try concatenate(initPart: videoInit, parts: job.videoParts, to: videoFile)
        progress(0.4)

        var audioFile: URL?
        if let audioInit = job.audioInit, !job.audioParts.isEmpty {
            let file = folder.appendingPathComponent("audio_joined.mp4")
            try concatenate(initPart: audioInit, parts: job.audioParts, to: file)
            audioFile = file
        }

        let videoAsset = AVURLAsset(url: videoFile)
        if let audioFile {
            let audioAsset = AVURLAsset(url: audioFile)
            let composition = AVMutableComposition()
            let duration = try await videoAsset.load(.duration)
            if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
               let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            }
            let audioDuration = try await audioAsset.load(.duration)
            if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: track, at: .zero)
            }
            return try await MediaExporter.export(asset: composition,
                                                  preset: AVAssetExportPresetPassthrough,
                                                  to: output,
                                                  fileType: .mp4) { value in progress(0.4 + value * 0.6) }
        }

        do {
            return try await MediaExporter.export(asset: videoAsset,
                                                  preset: AVAssetExportPresetPassthrough,
                                                  to: output,
                                                  fileType: .mp4) { value in progress(0.4 + value * 0.6) }
        } catch {
            // Dönüştürme olmazsa birleştirilmiş dosyayı olduğu gibi kullan (oynatılabilir)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: videoFile, to: output)
            return output
        }
    }

    private func concatenate(initPart: HLSPart, parts: [HLSPart], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: try data(for: initPart))
        for part in parts {
            try autoreleasepool {
                try handle.write(contentsOf: try data(for: part))
            }
        }
    }

    // MARK: - MPEG-TS akışları

    private struct TimelineFixer {
        var last: Int64?
        var offset: Int64 = 0
        var step: Int64 = 3000

        /// 33 bitlik taşmaları ve parça arası zaman sıçramalarını düzeltir; uygulanacak kaymayı döner
        mutating func adjust(dts raw: Int64) -> Int64 {
            var value = raw + offset
            if let last {
                if value < last - 90_000 || value > last + 90_000 * 30 {
                    offset += (last + step) - value
                    value = last + step
                } else if value > last {
                    step = min(max(value - last, 1), 90_000)
                }
            }
            last = value
            return offset
        }
    }

    private final class Feeder {
        let parts: [HLSPart]
        let packed: Bool
        let demuxer = TSDemuxer()
        var index = 0
        var packedPTS: Int64 = 0
        let provider: (HLSPart) throws -> Data

        init(parts: [HLSPart], packed: Bool, provider: @escaping (HLSPart) throws -> Data) {
            self.parts = parts
            self.packed = packed
            self.provider = provider
        }

        var hasMore: Bool { index < parts.count }

        func feedNext(_ emit: (MediaSample) -> Void) throws {
            let part = parts[index]
            index += 1
            try autoreleasepool {
                let data = try provider(part)
                if packed {
                    packedPTS = demuxer.feedPackedAudio(data, fallbackPTS: packedPTS, emit: emit)
                } else {
                    demuxer.feed(data, emit: emit)
                }
            }
            if !hasMore {
                demuxer.flush(emit: emit)
            }
        }
    }

    private func remuxTransportStream(output: URL, progress: @escaping (Double) -> Void) throws -> URL {
        let provider: (HLSPart) throws -> Data = { [unowned self] part in try self.data(for: part) }
        let videoFeeder = Feeder(parts: job.videoParts, packed: false, provider: provider)
        let audioFeeder: Feeder? = job.audioParts.isEmpty ? nil : Feeder(parts: job.audioParts, packed: job.audioIsPacked, provider: provider)

        var videoQueue: [MediaSample] = []
        var audioQueue: [MediaSample] = []
        var videoFixer = TimelineFixer()
        var audioFixer = TimelineFixer()
        var seenKeyframe = false

        func route(_ sample: MediaSample) {
            var adjusted = sample
            switch sample.kind {
            case .video:
                if !seenKeyframe {
                    guard sample.keyframe else { return }
                    seenKeyframe = true
                }
                let offset = videoFixer.adjust(dts: sample.dts)
                adjusted.dts += offset
                adjusted.pts += offset
                videoQueue.append(adjusted)
            case .audio:
                let offset = audioFixer.adjust(dts: sample.pts)
                adjusted.dts += offset
                adjusted.pts += offset
                audioQueue.append(adjusted)
            }
        }

        let expectsSeparateAudio = audioFeeder != nil

        func refill() throws {
            while videoQueue.isEmpty && videoFeeder.hasMore {
                try videoFeeder.feedNext(route)
            }
            if let audioFeeder {
                while audioQueue.isEmpty && audioFeeder.hasMore {
                    try audioFeeder.feedNext(route)
                }
            } else if videoFeeder.demuxer.hasAudioStream {
                // Aynı akışta ses: ses kuyruğu boşsa bir parça daha oku
                while audioQueue.isEmpty && videoFeeder.hasMore {
                    try videoFeeder.feedNext(route)
                }
            }
        }

        // Biçim bilgileri (SPS/PPS, AAC ayarı) gelene kadar oku
        try refill()
        var guardCount = 0
        while (videoFeeder.demuxer.parameterSets.isEmpty || videoQueue.isEmpty) && videoFeeder.hasMore && guardCount < 20 {
            try videoFeeder.feedNext(route)
            guardCount += 1
        }

        guard let codec = videoFeeder.demuxer.videoCodec,
              !videoFeeder.demuxer.parameterSets.isEmpty,
              !videoQueue.isEmpty else {
            throw HLSRemuxError.noVideo
        }

        let videoFormat = try Self.makeVideoFormat(codec: codec, parameterSets: videoFeeder.demuxer.parameterSets)
        let audioDemuxer = expectsSeparateAudio ? audioFeeder?.demuxer : videoFeeder.demuxer
        var audioFormat: CMFormatDescription?
        if let config = audioDemuxer?.aacConfig {
            audioFormat = try? Self.makeAudioFormat(config)
        }
        if audioFormat == nil {
            audioQueue.removeAll()
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw HLSRemuxError.writer("Video izi eklenemedi") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw HLSRemuxError.writer(writer.error?.localizedDescription ?? "başlatılamadı")
        }
        let firstVideo = videoQueue.first?.dts ?? 0
        let firstAudio = audioQueue.first?.pts ?? firstVideo
        let start = min(firstVideo, firstAudio)
        writer.startSession(atSourceTime: CMTime(value: start, timescale: 90_000))

        var pendingVideo: MediaSample?
        var lastVideoDuration: Int64 = 3000
        var audioFinished = audioInput == nil
        let audioDuration = Int64(1024 * 90_000 / max(audioDemuxer?.aacConfig?.sampleRate ?? 44100, 1))
        let totalParts = max(job.videoParts.count, 1)
        var lastReported = -1

        func writeVideo(_ sample: MediaSample, duration: Int64) throws {
            try Self.append(sample, duration: duration, format: videoFormat, input: videoInput, writer: writer)
        }

        while true {
            try refill()

            if !audioFinished, let audioInput, audioQueue.isEmpty {
                let audioExhausted = expectsSeparateAudio ? !(audioFeeder?.hasMore ?? false) : !videoFeeder.hasMore
                if audioExhausted {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
            }

            let nextVideo = videoQueue.first
            let nextAudio = audioFinished ? nil : audioQueue.first
            if nextVideo == nil && nextAudio == nil { break }

            let takeVideo: Bool
            if let nextVideo, let nextAudio {
                takeVideo = nextVideo.dts <= nextAudio.pts
            } else {
                takeVideo = nextVideo != nil
            }

            if takeVideo, let sample = nextVideo {
                videoQueue.removeFirst()
                if let pending = pendingVideo {
                    var duration = sample.dts - pending.dts
                    if duration <= 0 || duration > 90_000 { duration = lastVideoDuration } else { lastVideoDuration = duration }
                    try writeVideo(pending, duration: duration)
                }
                pendingVideo = sample
            } else if let sample = nextAudio, let audioInput, let audioFormat {
                audioQueue.removeFirst()
                try Self.append(sample, duration: audioDuration, format: audioFormat, input: audioInput, writer: writer, isAudio: true)
            }

            let percent = Int(Double(videoFeeder.index) / Double(totalParts) * 100)
            if percent != lastReported {
                lastReported = percent
                progress(Double(percent) / 100)
            }
        }

        if let pending = pendingVideo {
            try writeVideo(pending, duration: lastVideoDuration)
        }
        videoInput.markAsFinished()
        if !audioFinished { audioInput?.markAsFinished() }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        guard writer.status == .completed else {
            throw HLSRemuxError.writer(writer.error?.localizedDescription ?? "bilinmeyen hata")
        }
        progress(1)
        return output
    }

    // MARK: - Örnek tamponları

    private static func append(_ sample: MediaSample,
                               duration: Int64,
                               format: CMFormatDescription,
                               input: AVAssetWriterInput,
                               writer: AVAssetWriter,
                               isAudio: Bool = false) throws {
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: 90_000),
                                        presentationTimeStamp: CMTime(value: sample.pts, timescale: 90_000),
                                        decodeTimeStamp: isAudio ? .invalid : CMTime(value: sample.dts, timescale: 90_000))
        let buffer = try makeSampleBuffer(sample.data, format: format, timing: &timing, keyframe: sample.keyframe || isAudio)

        let deadline = Date().addingTimeInterval(20)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw HLSRemuxError.writer(writer.error?.localizedDescription ?? "yazma hatası")
            }
            if Date() > deadline {
                throw HLSRemuxError.writer("yazıcı yanıt vermiyor")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if !input.append(buffer) {
            throw HLSRemuxError.writer(writer.error?.localizedDescription ?? "örnek eklenemedi")
        }
    }

    private static func makeSampleBuffer(_ data: Data,
                                         format: CMFormatDescription,
                                         timing: inout CMSampleTimingInfo,
                                         keyframe: Bool) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let length = data.count
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: length,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: length,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { throw HLSRemuxError.writer("bellek ayrılamadı") }

        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: length)
        }
        guard status == noErr else { throw HLSRemuxError.writer("veri kopyalanamadı") }

        var sampleBuffer: CMSampleBuffer?
        var size = length
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: format,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size,
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw HLSRemuxError.writer("örnek oluşturulamadı") }

        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    // MARK: - Biçim açıklamaları

    static func makeVideoFormat(codec: VideoCodec, parameterSets: [Data]) throws -> CMFormatDescription {
        let pointers: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers: [UnsafePointer<UInt8>] = pointers.map { UnsafePointer($0) }
        let sizes: [Int] = parameterSets.map { $0.count }

        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                         parameterSetCount: parameterSets.count,
                                                                         parameterSetPointers: constPointers,
                                                                         parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4,
                                                                         formatDescriptionOut: &format)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                                                                         parameterSetCount: parameterSets.count,
                                                                         parameterSetPointers: constPointers,
                                                                         parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4,
                                                                         extensions: nil,
                                                                         formatDescriptionOut: &format)
        }
        guard status == noErr, let format else {
            throw HLSRemuxError.writer("video biçimi okunamadı (\(status))")
        }
        return format
    }

    static func makeAudioFormat(_ config: AACConfig) throws -> CMFormatDescription {
        var description = AudioStreamBasicDescription(mSampleRate: Float64(config.sampleRate),
                                                      mFormatID: kAudioFormatMPEG4AAC,
                                                      mFormatFlags: UInt32(config.objectType),
                                                      mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024,
                                                      mBytesPerFrame: 0,
                                                      mChannelsPerFrame: UInt32(config.channels),
                                                      mBitsPerChannel: 0,
                                                      mReserved: 0)
        let cookie = esdsCookie(audioSpecificConfig: config.audioSpecificConfig)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                           asbd: &description,
                                           layoutSize: 0,
                                           layout: nil,
                                           magicCookieSize: cookie.count,
                                           magicCookie: raw.baseAddress,
                                           extensions: nil,
                                           formatDescriptionOut: &format)
        }
        guard status == noErr, let format else {
            throw HLSRemuxError.writer("ses biçimi okunamadı (\(status))")
        }
        return format
    }

    /// MP4 'esds' kutusundaki ES tanımlayıcısı (Apple'ın AAC "magic cookie" biçimi)
    static func esdsCookie(audioSpecificConfig: Data) -> Data {
        func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
            let length = payload.count
            var result = Data([tag,
                               UInt8(0x80 | ((length >> 21) & 0x7F)),
                               UInt8(0x80 | ((length >> 14) & 0x7F)),
                               UInt8(0x80 | ((length >> 7) & 0x7F)),
                               UInt8(length & 0x7F)])
            result.append(payload)
            return result
        }

        var decoderConfig = Data([0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        decoderConfig.append(descriptor(0x05, audioSpecificConfig))

        var esPayload = Data([0x00, 0x00, 0x00])
        esPayload.append(descriptor(0x04, decoderConfig))
        esPayload.append(descriptor(0x06, Data([0x02])))
        return descriptor(0x03, esPayload)
    }
}
