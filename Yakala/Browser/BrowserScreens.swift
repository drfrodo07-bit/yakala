import SwiftUI
import UIKit

// MARK: - Yakalanan videolar

struct CaptureSheet: View {
    @ObservedObject var tab: BrowserTab
    var onPlay: (DetectedMedia) -> Void

    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAds = false

    private var mainItems: [DetectedMedia] {
        tab.sortedDetected.filter { !$0.isLikelyAd }
    }

    private var adItems: [DetectedMedia] {
        tab.sortedDetected.filter { $0.isLikelyAd }
    }

    var body: some View {
        NavigationStack {
            List {
                if mainItems.isEmpty && adItems.isEmpty {
                    ContentUnavailableView("Henüz video yakalanmadı",
                                           systemImage: "film",
                                           description: Text("Videoyu oynatmaya başlat; iCatch videoyu otomatik yakalar."))
                }
                if !mainItems.isEmpty {
                    Section {
                        ForEach(mainItems) { item in
                            row(item)
                        }
                    } header: {
                        Text("Videolar")
                    } footer: {
                        Text("İpucu: Reklamları geçip videoyu başlattıktan sonra tam ekran düğmesine basarsan video iCatch oynatıcısında İndir düğmesiyle açılır.")
                    }
                }
                if !adItems.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showAds) {
                            ForEach(adItems) { item in
                                row(item)
                            }
                        } label: {
                            Text("Reklam olabilir (\(adItems.count))")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("1 dakikadan kısa videolar genellikle reklamdır.")
                    }
                }
            }
            .navigationTitle("Yakalanan videolar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Temizle") { tab.detected.removeAll() }
                        .disabled(tab.detected.isEmpty)
                }
            }
        }
    }

    private func row(_ item: DetectedMedia) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isHLS ? "dot.radiowaves.left.and.right" : "film")
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.pageTitle.isEmpty ? item.displayName : item.pageTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if item.isPlaying {
                        Text("Oynatılıyor")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green))
                    }
                    if let duration = item.duration {
                        Text(PlayerView.timeString(duration))
                            .font(.caption.monospacedDigit())
                    }
                    Text("\(item.kindLabel) · \(item.url.host ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                onPlay(item)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            Button {
                tab.download(item)
                dismiss()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.url = item.url
            } label: {
                Label("Video bağlantısını kopyala", systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - Yer imleri ve geçmiş

struct BrowserLibraryView: View {
    enum LibrarySection: String, CaseIterable, Identifiable {
        case bookmarks
        case history
        var id: String { rawValue }
        var title: String { self == .bookmarks ? "Yer İmleri" : "Geçmiş" }
    }

    struct HistoryGroup: Identifiable {
        let id: String
        var entries: [HistoryEntry]
    }

    @State var initial: LibrarySection
    var onOpen: (URL) -> Void

    @ObservedObject private var store = BrowserStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmClear = false
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    init(initial: LibrarySection, onOpen: @escaping (URL) -> Void) {
        _initial = State(initialValue: initial)
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            List {
                if initial == .bookmarks {
                    bookmarksList
                } else {
                    historyList
                }
            }
            .searchable(text: $search, prompt: "Ara")
            .navigationTitle(initial.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Bölüm", selection: $initial) {
                        ForEach(LibrarySection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
                if initial == .history {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Geçmişi temizle", role: .destructive) { confirmClear = true }
                            .disabled(store.history.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .bottomBar) {
                        EditButton()
                    }
                }
            }
            .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Geçmişi temizle", role: .destructive) { store.clearHistory() }
                Button("Vazgeç", role: .cancel) {}
            }
            .alert("Yeniden adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Başlık", text: $newTitle)
                Button("Kaydet") {
                    if let renaming { store.rename(renaming, to: newTitle) }
                    renaming = nil
                }
                Button("Vazgeç", role: .cancel) { renaming = nil }
            }
        }
    }

    private var filteredBookmarks: [Bookmark] {
        guard !search.isEmpty else { return store.bookmarks }
        let query = search.lowercased()
        return store.bookmarks.filter { $0.title.lowercased().contains(query) || $0.url.absoluteString.lowercased().contains(query) }
    }

    @ViewBuilder
    private var bookmarksList: some View {
        if filteredBookmarks.isEmpty {
            Text("Henüz yer imi yok. Sayfa menüsünden ekleyebilirsin.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(filteredBookmarks) { bookmark in
            Button {
                onOpen(bookmark.url)
            } label: {
                HStack(spacing: 12) {
                    SiteIcon(url: bookmark.url, title: bookmark.title)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if bookmark.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { store.remove(bookmark) } label: { Label("Sil", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { store.toggleFavorite(bookmark) } label: {
                    Label(bookmark.isFavorite ? "Favoriden çıkar" : "Favori", systemImage: bookmark.isFavorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
            .contextMenu {
                Button {
                    newTitle = bookmark.title
                    renaming = bookmark
                } label: {
                    Label("Yeniden adlandır", systemImage: "pencil")
                }
                Button {
                    store.toggleFavorite(bookmark)
                } label: {
                    Label(bookmark.isFavorite ? "Favorilerden çıkar" : "Favorilere ekle", systemImage: "star")
                }
                Button {
                    UIPasteboard.general.url = bookmark.url
                } label: {
                    Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) { store.remove(bookmark) } label: { Label("Sil", systemImage: "trash") }
            }
        }
        .onMove { source, destination in
            if search.isEmpty { store.moveBookmarks(from: source, to: destination) }
        }
    }

    private var groupedHistory: [HistoryGroup] {
        let query = search.lowercased()
        let entries = search.isEmpty ? store.history : store.history.filter {
            $0.title.lowercased().contains(query) || $0.url.absoluteString.lowercased().contains(query)
        }
        let calendar = Calendar.current
        var groups: [HistoryGroup] = []
        for entry in entries.prefix(1500) {
            let label: String
            if calendar.isDateInToday(entry.date) {
                label = "Bugün"
            } else if calendar.isDateInYesterday(entry.date) {
                label = "Dün"
            } else {
                label = entry.date.formatted(date: .complete, time: .omitted)
            }
            if let index = groups.firstIndex(where: { $0.id == label }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(HistoryGroup(id: label, entries: [entry]))
            }
        }
        return groups
    }

    @ViewBuilder
    private var historyList: some View {
        if store.history.isEmpty {
            Text("Geçmiş boş.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(groupedHistory) { group in
            Section(group.id) {
                ForEach(group.entries) { entry in
                    Button {
                        onOpen(entry.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? (entry.url.host ?? "") : entry.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack {
                                Text(entry.url.host ?? entry.url.absoluteString)
                                Spacer()
                                Text(entry.date.formatted(date: .omitted, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(entry) } label: { Label("Sil", systemImage: "trash") }
                    }
                }
            }
        }
    }
}

// MARK: - Ayarlar

struct SettingsView: View {
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Görünüm") {
                    Picker("Tema", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Adres çubuğu", selection: $settings.addressBarPosition) {
                        ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Sayfaları koyu göster (yeni sekmeler)", isOn: $settings.webDarkMode)
                }

                Section("Arama") {
                    Picker("Arama motoru", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section {
                    Toggle("Reklam engelleyici", isOn: $settings.adBlockEnabled)
                    Toggle("Açılır pencereleri engelle", isOn: $settings.popupBlockEnabled)
                    if !settings.adBlockExceptions.isEmpty {
                        NavigationLink("Engellenmeyen siteler (\(settings.adBlockExceptions.count))") {
                            ExceptionsView()
                        }
                    }
                } header: {
                    Text("Reklam ve gizlilik")
                }

                Section {
                    Toggle("Tam ekranda iCatch oynatıcısını aç", isOn: $settings.takeoverPlayer)
                    Toggle("Kısa videoları reklam say", isOn: $settings.hideShortVideos)
                    Picker("Aynı anda bağlantı", selection: $settings.connections) {
                        Text("4 (sakin)").tag(4)
                        Text("8 (hızlı)").tag(8)
                        Text("12 (en hızlı)").tag(12)
                    }
                } header: {
                    Text("Video ve indirme")
                } footer: {
                    Text("Tam ekran düğmesine basınca video, üstünde İndir düğmesi olan iCatch oynatıcısında açılır. Bağlantı sayısı arttıkça indirme hızlanır; bazı siteler çok bağlantıyı sınırlayabilir.")
                }

                Section {
                    Button("Çerezleri ve site verilerini sil", role: .destructive) { confirmClear = true }
                }

                Section {
                    HStack {
                        Text("Sürüm")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
            .confirmationDialog("Tüm çerezler ve site verileri silinsin mi? Sitelerden çıkış yapılır.",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Sil", role: .destructive) { WebDataCleaner.clearAll() }
                Button("Vazgeç", role: .cancel) {}
            }
        }
    }
}

struct ExceptionsView: View {
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        List {
            ForEach(settings.adBlockExceptions.sorted(), id: \.self) { host in
                Text(host)
            }
            .onDelete { offsets in
                let sorted = settings.adBlockExceptions.sorted()
                for index in offsets {
                    settings.adBlockExceptions.remove(sorted[index])
                }
            }
        }
        .navigationTitle("Engellenmeyen siteler")
    }
}

// MARK: - Okuma modu

struct ReaderView: View {
    let content: ReaderContent
    @Environment(\.dismiss) private var dismiss
    @AppStorage("yakala.readerFont") private var fontSize: Double = 19

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(content.title)
                        .font(.system(size: fontSize + 8, weight: .bold, design: .serif))
                    ForEach(Array(content.items.enumerated()), id: \.offset) { _, item in
                        switch item.tag {
                        case "h1", "h2":
                            Text(item.text)
                                .font(.system(size: fontSize + 4, weight: .bold, design: .serif))
                                .padding(.top, 8)
                        case "h3":
                            Text(item.text)
                                .font(.system(size: fontSize + 2, weight: .semibold, design: .serif))
                        case "li":
                            Text("•  " + item.text)
                                .font(.system(size: fontSize, design: .serif))
                        case "blockquote":
                            Text(item.text)
                                .font(.system(size: fontSize, design: .serif).italic())
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                                }
                        default:
                            Text(item.text)
                                .font(.system(size: fontSize, design: .serif))
                                .lineSpacing(5)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { fontSize = max(13, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { fontSize = min(34, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                }
            }
        }
    }
}
