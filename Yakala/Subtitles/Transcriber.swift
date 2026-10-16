import Foundation
import WhisperKit

struct WhisperModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
}

enum WhisperModels {
    static let options: [WhisperModelOption] = [
        WhisperModelOption(id: "openai_whisper-large-v3-v20240930_turbo_632MB",
                           title: "En doğru (önerilen)",
                           detail: "Whisper large-v3 turbo. İlk kullanımda yaklaşık 630 MB indirir; yeni iPhone'larda hızlıdır."),
        WhisperModelOption(id: "openai_whisper-small",
                           title: "Dengeli",
                           detail: "Whisper small. Daha küçük ve hızlı, doğruluk biraz daha düşük."),
        WhisperModelOption(id: "openai_whisper-base",
                           title: "En hızlı",
                           detail: "Whisper base. Çok hızlı ama hata oranı yüksek; sadece deneme için.")
    ]

    static var defaultID: String {
        // 6 GB ve üzeri belleğe sahip cihazlarda (iPhone 15 Pro ve sonrası) en iyi modeli seç
        ProcessInfo.processInfo.physicalMemory >= 6_000_000_000 ? options[0].id : options[1].id
    }

    static func option(for id: String) -> WhisperModelOption {
        options.first(where: { $0.id == id }) ?? options[0]
    }
}

final class TranscriptionCancelFlag: @unchecked Sendable {
    var cancelled = false
}

enum SubtitleError: LocalizedError {
    case noSpeech
    case translationUnsupported(String, String)

    var errorDescription: String? {
        switch self {
        case .noSpeech:
            return "Videoda konuşma bulunamadı."
        case .translationUnsupported(let source, let target):
            return "\(source) → \(target) çevirisi bu cihazda desteklenmiyor."
        }
    }
}

/// WhisperKit ile cihaz üzerinde konuşma tanıma
final class Transcriber {
    static let shared = Transcriber()

    private var kit: WhisperKit?
    private var loadedModel: String?

    private var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileStore.ensure(base.appendingPathComponent("WhisperModels", isDirectory: true))
    }

    private func folderKey(_ model: String) -> String {
        "yakala.modelFolder." + model
    }

    private func cachedFolder(for model: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: folderKey(model)) else { return nil }
        let url = FileStore.fromHomeRelative(path)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.isEmpty ? nil : url
    }

    func prepare(model: String, status: @escaping (String, Double?) -> Void) async throws -> WhisperKit {
        if let kit, loadedModel == model {
            return kit
        }
        kit = nil
        loadedModel = nil

        var folder = cachedFolder(for: model)
        if folder == nil {
            let message = "Tanıma modeli indiriliyor (yalnızca ilk sefer)"
            status(message, 0)
            let downloaded = try await WhisperKit.download(variant: model,
                                                           downloadBase: modelsFolder,
                                                           progressCallback: { progress in
                status(message, progress.fractionCompleted)
            })
            UserDefaults.standard.set(FileStore.relativeToHome(downloaded), forKey: folderKey(model))
            folder = downloaded
        }

        guard let folder else {
            throw MediaExportError.failed("Model klasörü bulunamadı.")
        }

        status("Model hazırlanıyor (ilk seferde birkaç dakika sürebilir)", nil)
        do {
            let config = WhisperKitConfig(model: model,
                                          modelFolder: folder.path,
                                          tokenizerFolder: modelsFolder,
                                          verbose: false,
                                          prewarm: true,
                                          load: true,
                                          download: false)
            let newKit = try await WhisperKit(config)
            kit = newKit
            loadedModel = model
            return newKit
        } catch {
            // Model bozuk indirildiyse bir sonraki denemede yeniden indir
            UserDefaults.standard.removeObject(forKey: folderKey(model))
            throw error
        }
    }

    func transcribe(kit: WhisperKit,
                    audioURL: URL,
                    language: String?,
                    cancelFlag: TranscriptionCancelFlag,
                    progress: @escaping (Double) -> Void) async throws -> (segments: [SubtitleCue], language: String) {
        let options = DecodingOptions(task: .transcribe,
                                      language: language,
                                      temperatureFallbackCount: 3,
                                      usePrefillPrompt: true,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true,
                                      withoutTimestamps: false,
                                      wordTimestamps: false,
                                      chunkingStrategy: .vad)

        let poller = Task {
            while !Task.isCancelled {
                progress(kit.progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }

        let results = try await kit.transcribe(audioPath: audioURL.path,
                                               decodeOptions: options,
                                               callback: { _ in
            cancelFlag.cancelled ? false : nil
        })

        if cancelFlag.cancelled {
            throw CancellationError()
        }

        // En sık algılanan dili seç
        var counts: [String: Int] = [:]
        for result in results where !result.language.isEmpty {
            counts[result.language, default: 0] += max(result.segments.count, 1)
        }
        let detected = language ?? counts.max(by: { $0.value < $1.value })?.key ?? "en"

        let segments = results
            .flatMap { $0.segments }
            .map { SubtitleCue(start: Double($0.start), end: Double($0.end), text: SubtitleFormatter.clean($0.text)) }
            .filter { !$0.text.isEmpty && $0.end > $0.start }
            .sorted { $0.start < $1.start }

        return (segments, detected)
    }
}
