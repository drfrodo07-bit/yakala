import Foundation
import SwiftUI
import UIKit
import Translation

/// Altyazı üretim sürecini yönetir: dil algılama → yazıya dökme → çeviri → düzenleme → videoya gömme
@MainActor
final class SubtitleJob: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparingModel
        case extractingAudio
        case transcribing
        case translating
        case ready
        case burning
        case finished
        case failed
    }

    @Published var videoURL: URL?
    @Published var phase: Phase = .idle {
        didSet { UIApplication.shared.isIdleTimerDisabled = isBusy }
    }
    @Published var statusText = ""
    @Published var progress: Double?
    @Published var sourceCues: [SubtitleCue] = []
    @Published var cues: [SubtitleCue] = []
    @Published var detectedLanguage: String?
    @Published var outputVideo: URL?
    @Published var outputSRT: URL?
    @Published var translationConfiguration: TranslationSession.Configuration?

    // Ayarlar (hatırlanır)
    @Published var sourceLanguage: String = UserDefaults.standard.string(forKey: "yakala.sourceLanguage") ?? "auto" {
        didSet { UserDefaults.standard.set(sourceLanguage, forKey: "yakala.sourceLanguage") }
    }
    @Published var targetLanguage: String = UserDefaults.standard.string(forKey: "yakala.targetLanguage") ?? "tr" {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: "yakala.targetLanguage") }
    }
    @Published var modelID: String = UserDefaults.standard.string(forKey: "yakala.model") ?? WhisperModels.defaultID {
        didSet { UserDefaults.standard.set(modelID, forKey: "yakala.model") }
    }
    @Published var fontScale: Double = UserDefaults.standard.object(forKey: "yakala.fontScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(fontScale, forKey: "yakala.fontScale") }
    }
    @Published var boxed: Bool = UserDefaults.standard.object(forKey: "yakala.boxed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(boxed, forKey: "yakala.boxed") }
    }

    private var workTask: Task<Void, Never>?
    private var cancelFlag = TranscriptionCancelFlag()

    var isBusy: Bool {
        switch phase {
        case .preparingModel, .extractingAudio, .transcribing, .translating, .burning:
            return true
        default:
            return false
        }
    }

    // MARK: - Seçim

    func select(video: URL) {
        guard !isBusy else { return }
        reset()
        videoURL = video
    }

    private func reset() {
        phase = .idle
        statusText = ""
        progress = nil
        sourceCues = []
        cues = []
        detectedLanguage = nil
        outputVideo = nil
        outputSRT = nil
        translationConfiguration = nil
    }

    // MARK: - Altyazı üretimi

    func start() {
        guard let video = videoURL, !isBusy else { return }
        reset()
        videoURL = video
        cancelFlag = TranscriptionCancelFlag()
        let flag = cancelFlag
        let model = modelID
        let language = sourceLanguage == "auto" ? nil : sourceLanguage
        workTask = Task { [weak self] in
            await self?.run(video: video, model: model, language: language, flag: flag)
        }
    }

    private func run(video: URL, model: String, language: String?, flag: TranscriptionCancelFlag) async {
        var audioURL: URL?
        defer {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        }
        do {
            phase = .preparingModel
            statusText = "Tanıma modeli hazırlanıyor"
            progress = nil
            let kit = try await Transcriber.shared.prepare(model: model) { [weak self] text, value in
                Task { @MainActor in
                    guard let self, self.phase == .preparingModel else { return }
                    self.statusText = text
                    self.progress = value
                }
            }
            try checkCancelled(flag)

            phase = .extractingAudio
            statusText = "Videonun sesi ayrıştırılıyor"
            progress = nil
            let audio = try await MediaExporter.extractAudio(from: video)
            audioURL = audio
            try checkCancelled(flag)

            phase = .transcribing
            statusText = language == nil ? "Dil algılanıyor ve konuşma yazıya dökülüyor" : "Konuşma yazıya dökülüyor"
            progress = 0
            let result = try await Transcriber.shared.transcribe(kit: kit,
                                                                 audioURL: audio,
                                                                 language: language,
                                                                 cancelFlag: flag) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.phase == .transcribing else { return }
                    self.progress = value
                }
            }
            try checkCancelled(flag)

            guard !result.segments.isEmpty else { throw SubtitleError.noSpeech }
            detectedLanguage = result.language
            sourceCues = result.segments

            if targetLanguage == "none" || targetLanguage == result.language {
                finishCues(from: result.segments)
            } else {
                await beginTranslation(from: result.language)
            }
        } catch is CancellationError {
            phase = .idle
            statusText = "İptal edildi"
            progress = nil
        } catch {
            fail(error)
        }
    }

    private func checkCancelled(_ flag: TranscriptionCancelFlag) throws {
        if flag.cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    // MARK: - Çeviri (Apple Çeviri, cihaz üzerinde)

    private func beginTranslation(from language: String) async {
        let source = Languages.appleLanguage(language)
        let target = Languages.appleLanguage(targetLanguage)
        let availability = await LanguageAvailability().status(from: source, to: target)
        if availability == .unsupported {
            fail(SubtitleError.translationUnsupported(Languages.name(for: language), Languages.name(for: targetLanguage)))
            return
        }
        phase = .translating
        statusText = "\(Languages.name(for: language)) → \(Languages.name(for: targetLanguage)) çevriliyor"
        progress = nil
        translationConfiguration = TranslationSession.Configuration(source: source, target: target)
    }

    /// Görünümdeki .translationTask tarafından çağrılır
    func translate(using session: TranslationSession) async {
        guard phase == .translating else { return }
        do {
            try await session.prepareTranslation()
            var translated = sourceCues
            let requests = sourceCues.enumerated().map { index, cue in
                TranslationSession.Request(sourceText: cue.text, clientIdentifier: String(index))
            }
            let batchSize = 50
            var done = 0
            for start in stride(from: 0, to: requests.count, by: batchSize) {
                if cancelFlag.cancelled { throw CancellationError() }
                let batch = Array(requests[start..<min(start + batchSize, requests.count)])
                let responses = try await session.translations(from: batch)
                for response in responses {
                    if let identifier = response.clientIdentifier,
                       let index = Int(identifier),
                       translated.indices.contains(index) {
                        translated[index].text = response.targetText
                    }
                }
                done += batch.count
                progress = Double(done) / Double(max(requests.count, 1))
            }
            translationConfiguration = nil
            finishCues(from: translated)
        } catch is CancellationError {
            translationConfiguration = nil
            phase = .idle
            statusText = "İptal edildi"
        } catch {
            translationConfiguration = nil
            statusText = ""
            fail(MediaExportError.failed("Çeviri yapılamadı: \(error.localizedDescription). Ayarlar > Uygulamalar > Çeviri bölümünden dil paketlerini indirmeyi deneyebilirsin."))
        }
    }

    private func finishCues(from segments: [SubtitleCue]) {
        cues = SubtitleFormatter.split(segments)
        phase = .ready
        progress = nil
        let languageInfo = detectedLanguage.map { "Algılanan dil: \(Languages.name(for: $0)). " } ?? ""
        statusText = "\(languageInfo)\(cues.count) altyazı hazır. Kontrol edip videoya gömebilirsin."
        saveSRT()
    }

    // MARK: - Düzenleme ve kayıt

    func updateCue(_ cue: SubtitleCue) {
        guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        cues[index] = cue
        saveSRT()
    }

    private var outputLanguageCode: String {
        targetLanguage == "none" ? (detectedLanguage ?? "orijinal") : targetLanguage
    }

    func saveSRT() {
        guard let videoURL, !cues.isEmpty else { return }
        let name = FileStore.sanitize(videoURL.deletingPathExtension().lastPathComponent + "." + outputLanguageCode)
        let url = FileStore.subtitled.appendingPathComponent(name).appendingPathExtension("srt")
        do {
            try SRTWriter.make(cues).write(to: url, atomically: true, encoding: .utf8)
            outputSRT = url
            DownloadManager.shared.notifyLibraryChanged()
        } catch {
            statusText = "SRT kaydedilemedi: \(error.localizedDescription)"
        }
    }

    // MARK: - Videoya gömme

    func burn() {
        guard let video = videoURL, !cues.isEmpty, !isBusy else { return }
        phase = .burning
        statusText = "Altyazılar videoya işleniyor"
        progress = 0
        outputVideo = nil

        let cuesToBurn = cues
        let style = SubtitleBurner.Style(fontScale: CGFloat(fontScale), boxed: boxed)
        let baseName = video.deletingPathExtension().lastPathComponent + " [\(outputLanguageCode)]"
        let output = FileStore.uniqueURL(in: FileStore.subtitled, baseName: baseName, ext: "mp4")
        let activity = BackgroundActivity(name: "yakala-altyazi-gomme")

        workTask = Task { [weak self] in
            defer { activity.end() }
            do {
                let result = try await SubtitleBurner.burn(video: video,
                                                           cues: cuesToBurn,
                                                           style: style,
                                                           output: output) { value in
                    Task { @MainActor in
                        guard let self, self.phase == .burning else { return }
                        self.progress = value
                    }
                }
                guard let self else { return }
                self.outputVideo = result
                self.phase = .finished
                self.progress = 1
                self.statusText = "Altyazılı video hazır. İndirilenler > Altyazılı videolar bölümünde de bulabilirsin."
                DownloadManager.shared.notifyLibraryChanged()
            } catch {
                try? FileManager.default.removeItem(at: output)
                guard let self else { return }
                if let exportError = error as? MediaExportError, case .cancelled = exportError {
                    self.phase = .ready
                    self.statusText = "Gömme iptal edildi"
                    self.progress = nil
                } else {
                    self.fail(error)
                }
            }
        }
    }

    // MARK: - İptal ve hata

    func cancel() {
        cancelFlag.cancelled = true
        workTask?.cancel()
        if phase == .translating {
            translationConfiguration = nil
            phase = .idle
            statusText = "İptal edildi"
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        progress = nil
        statusText = error.localizedDescription
    }
}
