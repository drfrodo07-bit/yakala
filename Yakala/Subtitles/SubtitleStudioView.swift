import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Fotoğraflar'dan seçilen videoyu uygulamanın klasörüne kopyalar
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileStore.uniqueURL(in: FileStore.downloads,
                                                  baseName: source.deletingPathExtension().lastPathComponent,
                                                  ext: ext)
            try FileManager.default.copyItem(at: source, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

struct SubtitleStudioView: View {
    @EnvironmentObject private var job: SubtitleJob
    @Environment(\.dismiss) private var dismiss
    var showsCloseButton = false

    @State private var showLibraryPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?
    @State private var editingCue: SubtitleCue?
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                settingsSection
                actionSection
                if !job.cues.isEmpty {
                    cuesSection
                }
            }
            .navigationTitle("Altyazı")
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Kapat") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showLibraryPicker) {
                LibraryVideoPicker { url in
                    job.select(video: url)
                }
            }
            .sheet(item: $editingCue) { cue in
                CueEditor(cue: cue) { updated in
                    job.updateCue(updated)
                }
            }
            .fullScreenCover(item: $playing) { item in
                PlayerView(url: item.url)
            }
            .onChange(of: photoItem) {
                importPickedVideo()
            }
        }
    }

    // MARK: Video seçimi

    private var videoSection: some View {
        Section {
            if let url = job.videoURL {
                HStack(spacing: 12) {
                    Image(systemName: "film")
                        .foregroundStyle(.tint)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        playing = PlayItem(url: url)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Altyazı eklenecek videoyu seç.")
                    .foregroundStyle(.secondary)
            }

            Button {
                showLibraryPicker = true
            } label: {
                Label("İndirilenlerden seç", systemImage: "arrow.down.circle")
            }
            .disabled(job.isBusy)

            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label(importing ? "Video aktarılıyor…" : "Fotoğraflar'dan seç", systemImage: "photo.on.rectangle")
            }
            .disabled(job.isBusy || importing)

            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
        } header: {
            Text("Video")
        }
    }

    // MARK: Ayarlar

    private var settingsSection: some View {
        Section {
            Picker("Konuşulan dil", selection: $job.sourceLanguage) {
                Text("Otomatik algıla").tag("auto")
                ForEach(Languages.common) { language in
                    Text(language.name).tag(language.code)
                }
            }

            Picker("Altyazı dili", selection: $job.targetLanguage) {
                Text("Çevirme (konuşulan dilde)").tag("none")
                ForEach(Languages.common) { language in
                    Text(language.name).tag(language.code)
                }
            }

            Picker("Tanıma modeli", selection: $job.modelID) {
                ForEach(WhisperModels.options) { option in
                    Text(option.title).tag(option.id)
                }
            }

            Picker("Yazı boyutu", selection: $job.fontScale) {
                Text("Küçük").tag(0.8)
                Text("Orta").tag(1.0)
                Text("Büyük").tag(1.25)
            }
            .pickerStyle(.segmented)

            Toggle("Yazının arkasında koyu kutu", isOn: $job.boxed)
        } header: {
            Text("Ayarlar")
        } footer: {
            Text(WhisperModels.option(for: job.modelID).detail + " Tanıma ve çeviri tamamen telefonda yapılır.")
        }
        .disabled(job.isBusy)
    }

    // MARK: İşlem

    private var actionSection: some View {
        Section {
            if job.isBusy {
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.statusText)
                        .font(.subheadline)
                    if let value = job.progress {
                        ProgressView(value: min(max(value, 0), 1))
                        Text("%\(Int(min(max(value, 0), 1) * 100))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text("İşlem bitene kadar uygulamayı açık tut. Bu sırada ekran kendiliğinden kilitlenmez.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button("İptal et", role: .destructive) {
                    job.cancel()
                }
            } else {
                Button {
                    job.start()
                } label: {
                    Label(job.cues.isEmpty ? "Altyazı oluştur" : "Baştan oluştur", systemImage: "waveform")
                }
                .disabled(job.videoURL == nil)

                if !job.cues.isEmpty {
                    Button {
                        job.burn()
                    } label: {
                        Label("Altyazıyı videoya göm", systemImage: "film.stack")
                    }
                }

                if !job.statusText.isEmpty {
                    Text(job.statusText)
                        .font(.footnote)
                        .foregroundStyle(job.phase == .failed ? Color.red : Color.secondary)
                }

                if let output = job.outputVideo {
                    Button {
                        playing = PlayItem(url: output)
                    } label: {
                        Label("Altyazılı videoyu izle", systemImage: "play.rectangle")
                    }
                    ShareLink(item: output) {
                        Label("Altyazılı videoyu paylaş / kaydet", systemImage: "square.and.arrow.up")
                    }
                }

                if let srt = job.outputSRT {
                    ShareLink(item: srt) {
                        Label("SRT dosyasını paylaş", systemImage: "doc.text")
                    }
                }
            }
        }
    }

    // MARK: Altyazı listesi

    private var cuesSection: some View {
        Section {
            ForEach(job.cues) { cue in
                Button {
                    editingCue = cue
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(PlayerView.timeString(cue.start)) → \(PlayerView.timeString(cue.end))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(cue.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .disabled(job.isBusy)
            }
        } header: {
            Text("Altyazılar (\(job.cues.count))")
        } footer: {
            Text("Düzeltmek istediğin satıra dokun. Değişiklikler SRT dosyasına hemen kaydedilir; videoya yansıması için yeniden göm.")
        }
    }

    // MARK: Yardımcılar

    private func importPickedVideo() {
        guard let item = photoItem else { return }
        importing = true
        importError = nil
        Task { @MainActor in
            defer {
                importing = false
                photoItem = nil
            }
            do {
                if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                    job.select(video: movie.url)
                    DownloadManager.shared.notifyLibraryChanged()
                } else {
                    importError = "Video alınamadı."
                }
            } catch {
                importError = "Video alınamadı: \(error.localizedDescription)"
            }
        }
    }
}

struct LibraryVideoPicker: View {
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var videos: [URL] = []

    var body: some View {
        NavigationStack {
            List(videos, id: \.self) { url in
                Button {
                    onPick(url)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "film")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(FileStore.formattedSize(FileStore.fileSize(url)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if videos.isEmpty {
                    ContentUnavailableView("Video yok",
                                           systemImage: "film",
                                           description: Text("Önce tarayıcıdan bir video indir ya da Fotoğraflar'dan seç."))
                }
            }
            .navigationTitle("Video seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
            .onAppear {
                videos = (FileStore.list(FileStore.downloads) + FileStore.list(FileStore.subtitled))
                    .filter { FileStore.isVideo($0) }
            }
        }
    }
}

struct CueEditor: View {
    @State var cue: SubtitleCue
    var onSave: (SubtitleCue) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $cue.text)
                        .frame(minHeight: 120)
                } header: {
                    Text("\(PlayerView.timeString(cue.start)) → \(PlayerView.timeString(cue.end))")
                }
            }
            .navigationTitle("Altyazıyı düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        onSave(cue)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
