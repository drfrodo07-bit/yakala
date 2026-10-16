import Foundation
import AVFoundation

enum MediaExportError: LocalizedError {
    case cannotCreateSession
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession: return "Video dışa aktarma başlatılamadı."
        case .cancelled: return "İşlem iptal edildi."
        case .failed(let message): return message
        }
    }
}

enum MediaExporter {
    /// İndirilen akışı (.movpkg) normal bir MP4 dosyasına çevirir. Sonuç dosyasının adresini döner.
    static func exportToMP4(source: URL, destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        do {
            return try await export(asset: asset, preset: AVAssetExportPresetPassthrough, to: destination, fileType: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return try await export(asset: asset, preset: AVAssetExportPresetHighestQuality, to: destination, fileType: .mp4)
        }
    }

    /// Videodan yalnızca sesi çıkarır (yazıya dökme için)
    static func extractAudio(from video: URL) async throws -> URL {
        let output = FileStore.work.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let asset = AVURLAsset(url: video)
        return try await export(asset: asset, preset: AVAssetExportPresetAppleM4A, to: output, fileType: .m4a)
    }

    @discardableResult
    static func export(asset: AVAsset,
                       preset: String,
                       to url: URL,
                       fileType: AVFileType,
                       videoComposition: AVVideoComposition? = nil,
                       progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaExportError.cannotCreateSession
        }

        var outputURL = url
        var outputType = fileType
        if !session.supportedFileTypes.contains(fileType) {
            if session.supportedFileTypes.contains(.mov) {
                outputType = .mov
                outputURL = url.deletingPathExtension().appendingPathExtension("mov")
            } else if let first = session.supportedFileTypes.first {
                outputType = first
            }
        }
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = outputType
        session.shouldOptimizeForNetworkUse = true
        if let videoComposition {
            session.videoComposition = videoComposition
        }

        let poller = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        defer { poller.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            session.cancelExport()
        }

        switch session.status {
        case .completed:
            progress?(1)
            return outputURL
        case .cancelled:
            throw MediaExportError.cancelled
        default:
            throw MediaExportError.failed(session.error?.localizedDescription ?? "Video dışa aktarılamadı.")
        }
    }
}
