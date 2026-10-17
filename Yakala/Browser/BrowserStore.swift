import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var isFavorite: Bool
    var created = Date()
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var date: Date
}

struct AddressSuggestion: Identifiable, Hashable {
    enum Kind {
        case bookmark
        case history
        case search
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let url: URL?
    let query: String?
}

/// Yer imleri, favoriler ve geçmiş (özel sekmeler kaydedilmez)
@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [HistoryEntry] = []

    private let folder: URL
    private let maxHistory = 3000

    var favorites: [Bookmark] {
        bookmarks.filter(\.isFavorite)
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = FileStore.ensure(base.appendingPathComponent("Browser", isDirectory: true))

        if let data = try? Data(contentsOf: folder.appendingPathComponent("bookmarks.json")),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        } else {
            bookmarks = [
                Bookmark(title: "Google", url: URL(string: "https://www.google.com")!, isFavorite: true),
                Bookmark(title: "YouTube", url: URL(string: "https://m.youtube.com")!, isFavorite: true),
                Bookmark(title: "Vikipedi", url: URL(string: "https://tr.wikipedia.org")!, isFavorite: true),
                Bookmark(title: "Yandex", url: URL(string: "https://yandex.com.tr")!, isFavorite: true)
            ]
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("history.json")),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved
        }
    }

    // MARK: Yer imleri

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { Self.same($0.url, url) }
    }

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { Self.same($0.url, url) && $0.isFavorite }
    }

    func addBookmark(title: String, url: URL, favorite: Bool = false) {
        if let index = bookmarks.firstIndex(where: { Self.same($0.url, url) }) {
            if favorite { bookmarks[index].isFavorite = true }
        } else {
            bookmarks.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title,
                                      url: url,
                                      isFavorite: favorite))
        }
        saveBookmarks()
    }

    func removeBookmark(for url: URL) {
        bookmarks.removeAll { Self.same($0.url, url) }
        saveBookmarks()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }

    func toggleFavorite(_ bookmark: Bookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].isFavorite.toggle()
        saveBookmarks()
    }

    func rename(_ bookmark: Bookmark, to title: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].title = title
        saveBookmarks()
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        saveBookmarks()
    }

    // MARK: Geçmiş

    func recordVisit(title: String, url: URL) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        if let last = history.first, Self.same(last.url, url) {
            history[0].title = title.isEmpty ? last.title : title
            history[0].date = Date()
        } else {
            history.insert(HistoryEntry(title: title, url: url, date: Date()), at: 0)
            if history.count > maxHistory {
                history.removeLast(history.count - maxHistory)
            }
        }
        saveHistory()
    }

    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let index = history.firstIndex(where: { Self.same($0.url, url) }), index < 5 else { return }
        if history[index].title != title {
            history[index].title = title
            saveHistory()
        }
    }

    func remove(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    /// En çok ziyaret edilen siteler (başlangıç sayfası için)
    func frequentlyVisited(limit: Int = 8) -> [HistoryEntry] {
        var counts: [String: (count: Int, entry: HistoryEntry)] = [:]
        for entry in history.prefix(1500) {
            guard let host = entry.url.host else { continue }
            if let existing = counts[host] {
                counts[host] = (existing.count + 1, existing.entry)
            } else {
                let root = URL(string: "\(entry.url.scheme ?? "https")://\(host)") ?? entry.url
                counts[host] = (1, HistoryEntry(title: Self.siteName(host), url: root, date: entry.date))
            }
        }
        let favoriteHosts = Set(favorites.compactMap { $0.url.host })
        return counts.values
            .filter { !favoriteHosts.contains($0.entry.url.host ?? "") && $0.count > 1 }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map(\.entry)
    }

    // MARK: Öneriler

    func suggestions(for text: String, engine: SearchEngine) -> [AddressSuggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        var result: [AddressSuggestion] = [AddressSuggestion(kind: .search, title: query, url: nil, query: query)]
        var seen = Set<String>()

        for bookmark in bookmarks where matches(bookmark.title, bookmark.url, lower) {
            let key = bookmark.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(AddressSuggestion(kind: .bookmark, title: bookmark.title, url: bookmark.url, query: nil))
            if result.count >= 4 { break }
        }
        for entry in history where matches(entry.title, entry.url, lower) {
            let key = entry.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(AddressSuggestion(kind: .history, title: entry.title.isEmpty ? (entry.url.host ?? key) : entry.title,
                                            url: entry.url, query: nil))
            if result.count >= 10 { break }
        }
        return result
    }

    private func matches(_ title: String, _ url: URL, _ query: String) -> Bool {
        title.lowercased().contains(query) || url.absoluteString.lowercased().contains(query)
    }

    // MARK: Kayıt

    private func saveBookmarks() {
        let snapshot = bookmarks
        let url = folder.appendingPathComponent("bookmarks.json")
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private var historySaveScheduled = false

    private func saveHistory() {
        guard !historySaveScheduled else { return }
        historySaveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.historySaveScheduled = false
            let snapshot = self.history
            let url = self.folder.appendingPathComponent("history.json")
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    // MARK: Yardımcılar

    static func same(_ a: URL, _ b: URL) -> Bool {
        normalized(a) == normalized(b)
    }

    static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func siteName(_ host: String) -> String {
        var name = host.lowercased()
        for prefix in ["www.", "m.", "mobile."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        let first = name.split(separator: ".").first.map(String.init) ?? name
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}
