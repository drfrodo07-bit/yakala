import SwiftUI
import Photos

struct PlayItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct LibraryView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var subtitleJob: SubtitleJob
    @Environment(\.dismiss) private var dismiss
    var showsCloseButton = false

    @State private var showStudio = false

    @State private var downloaded: [URL] = []
    @State private var subtitled: [URL] = []
    @State private var playing: PlayItem?
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !downloads.items.isEmpty {
                    transfersSection
                }
                fileSection(title: "İndirilenler",
                            urls: downloaded,
                            emptyText: "Henüz indirme yok. Tarayıcıda videoyu oynat, alttaki indirme simgesine dokun.")
                if !subtitled.isEmpty {
                    fileSection(title: "Altyazılı videolar", urls: subtitled, emptyText: "")
                }
            }
            .navigationTitle("İndirilenler")
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Kapat") { dismiss() }
                    }
                }
                if downloads.items.contains(where: { !$0.isActive }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Listeyi temizle") { downloads.clearFinished() }
                    }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: downloads.libraryVersion) { reload() }
            .fullScreenCover(item: $playing) { item in
                PlayerView(url: item.url)
            }
            .sheet(isPresented: $showStudio) {
                SubtitleStudioView(showsCloseButton: true)
            }
            .alert("Yeniden adlandır", isPresented: renamingBinding) {
                TextField("Yeni ad", text: $newName)
                Button("Kaydet") { rename() }
                Button("Vazgeç", role: .cancel) { renaming = nil }
            }
            .alert(alertMessage ?? "", isPresented: alertBinding) {
                Button("Tamam", role: .cancel) { alertMessage = nil }
            }
        }
    }

    // MARK: Bölümler

    private var transfersSection: some View {
        Section("Aktarımlar") {
            ForEach(downloads.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: item.isHLS ? "dot.radiowaves.left.and.right" : "arrow.down.doc")
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        status(for: item)
                    }
                    switch item.state {
                    case .running:
                        ProgressView(value: item.progress)
                        HStack {
                            Text(FileStore.formattedSize(item.bytes))
                            Spacer()
                            Text(DownloadManager.formattedSpeed(item.speed))
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    case .converting:
                        ProgressView(value: item.progress)
                            .tint(.orange)
                    case .preparing:
                        ProgressView()
                            .progressViewStyle(.linear)
                    default:
                        EmptyView()
                    }
                }
                .swipeActions(edge: .trailing) {
                    if item.isActive {
                        Button("İptal", role: .destructive) { downloads.cancel(item.id) }
                    } else {
                        Button("Kaldır", role: .destructive) { downloads.remove(item.id) }
                    }
                }
                .swipeActions(edge: .leading) {
                    if item.isFailed, downloads.canRetry(item.id) {
                        Button {
                            downloads.retry(item.id)
                        } label: {
                            Label("Tekrar dene", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func status(for item: DownloadManager.Item) -> some View {
        switch item.state {
        case .preparing:
            Text("Hazırlanıyor")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            Text("%\(Int(item.progress * 100))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .converting:
            Text(item.isHLS ? "MP4 oluşturuluyor %\(Int(item.progress * 100))" : "Birleştiriliyor")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .multilineTextAlignment(.trailing)
        }
    }

    private func fileSection(title: String, urls: [URL], emptyText: String) -> some View {
        Section {
            if urls.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(urls, id: \.self) { url in
                    fileRow(url)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if !urls.isEmpty {
                Text("Seçenekler için dosyaya basılı tut. Sola kaydırarak altyazı ekleyebilirsin. Dosyalar, Dosyalar uygulamasında “iCatch” klasöründe de görünür.")
            }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        Button {
            if FileStore.isPlayable(url) {
                playing = PlayItem(url: url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: FileStore.isVideo(url) ? "film" : (FileStore.isPlayable(url) ? "music.note" : "doc"))
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(FileStore.formattedSize(FileStore.fileSize(url))) · \(FileStore.modificationDate(url).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if FileStore.isVideo(url) {
                Button {
                    addSubtitles(url)
                } label: {
                    Label("Altyazı", systemImage: "captions.bubble")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(url)
            } label: {
                Label("Sil", systemImage: "trash")
            }
        }
        .contextMenu {
            if FileStore.isVideo(url) {
                Button {
                    addSubtitles(url)
                } label: {
                    Label("Altyazı ekle", systemImage: "captions.bubble")
                }
            }
            ShareLink(item: url) {
                Label("Paylaş", systemImage: "square.and.arrow.up")
            }
            if FileStore.isVideo(url) {
                Button {
                    saveToPhotos(url)
                } label: {
                    Label("Fotoğraflar'a kaydet", systemImage: "photo.on.rectangle")
                }
            }
            Button {
                newName = url.deletingPathExtension().lastPathComponent
                renaming = url
            } label: {
                Label("Yeniden adlandır", systemImage: "pencil")
            }
            Button(role: .destructive) {
                delete(url)
            } label: {
                Label("Sil", systemImage: "trash")
            }
        }
    }

    // MARK: İşlemler

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    private func addSubtitles(_ url: URL) {
        subtitleJob.select(video: url)
        showStudio = true
    }

    private func reload() {
        downloaded = FileStore.list(FileStore.downloads)
        subtitled = FileStore.list(FileStore.subtitled)
    }

    private func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            // Varsa aynı adlı altyazı dosyasını da sil
            let srt = url.deletingPathExtension().appendingPathExtension("srt")
            try? FileManager.default.removeItem(at: srt)
        } catch {
            alertMessage = "Silinemedi: \(error.localizedDescription)"
        }
        reload()
    }

    private func rename() {
        guard let url = renaming else { return }
        renaming = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.deletingPathExtension().lastPathComponent else { return }
        let destination = FileStore.uniqueURL(in: url.deletingLastPathComponent(), baseName: trimmed, ext: url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            alertMessage = "Ad değiştirilemedi: \(error.localizedDescription)"
        }
        reload()
    }

    private func saveToPhotos(_ url: URL) {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                alertMessage = "Fotoğraflar'a kaydetme izni verilmedi. Ayarlar > iCatch bölümünden izin verebilirsin."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                alertMessage = "Video Fotoğraflar'a kaydedildi."
            } catch {
                alertMessage = "Kaydedilemedi: \(error.localizedDescription)"
            }
        }
    }
}
