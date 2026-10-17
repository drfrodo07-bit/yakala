import Foundation
import WebKit

/// Normal ve özel sekmeleri yönetir; normal sekmeler uygulama kapanınca da hatırlanır
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var privateTabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var isPrivateMode = false

    private let privateDataStore = WKWebsiteDataStore.nonPersistent()
    private var saveScheduled = false
    private let savedTabsKey = "b.savedTabs"
    private let savedSelectionKey = "b.savedSelection"

    var current: BrowserTab? {
        (tabs + privateTabs).first { $0.id == selectedID }
    }

    var visibleTabs: [BrowserTab] {
        isPrivateMode ? privateTabs : tabs
    }

    init() {
        restore()
        if tabs.isEmpty {
            let tab = makeTab(url: nil, isPrivate: false, loadImmediately: true)
            tabs.append(tab)
            selectedID = tab.id
        }
        current?.activate()
    }

    private func makeTab(url: URL?, isPrivate: Bool, loadImmediately: Bool, id: UUID = UUID()) -> BrowserTab {
        let tab = BrowserTab(id: id,
                             isPrivate: isPrivate,
                             dataStore: isPrivate ? privateDataStore : .default(),
                             initialURL: url,
                             loadImmediately: loadImmediately)
        tab.manager = self
        return tab
    }

    // MARK: - Sekme işlemleri

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool? = nil, select: Bool = true) -> BrowserTab {
        let usePrivate = isPrivate ?? isPrivateMode
        let tab = makeTab(url: url, isPrivate: usePrivate, loadImmediately: true)
        if usePrivate {
            privateTabs.append(tab)
        } else {
            tabs.append(tab)
        }
        if select {
            isPrivateMode = usePrivate
            selectedID = tab.id
        }
        scheduleSave()
        return tab
    }

    func openTab(_ url: URL, isPrivate: Bool, select: Bool) {
        newTab(url: url, isPrivate: isPrivate, select: select)
    }

    func select(_ tab: BrowserTab) {
        current?.takeSnapshot()
        isPrivateMode = tab.isPrivate
        selectedID = tab.id
        tab.activate()
        scheduleSave()
    }

    func close(_ tab: BrowserTab) {
        tab.webView.stopLoading()
        if tab.isPrivate {
            privateTabs.removeAll { $0.id == tab.id }
        } else {
            tabs.removeAll { $0.id == tab.id }
        }
        if selectedID == tab.id {
            let pool = tab.isPrivate ? privateTabs : tabs
            if let next = pool.last {
                selectedID = next.id
                next.activate()
            } else if tab.isPrivate, let fallback = tabs.last {
                isPrivateMode = false
                selectedID = fallback.id
                fallback.activate()
            } else {
                let fresh = makeTab(url: nil, isPrivate: false, loadImmediately: true)
                tabs.append(fresh)
                isPrivateMode = false
                selectedID = fresh.id
            }
        }
        scheduleSave()
    }

    func closeAll(isPrivate: Bool) {
        if isPrivate {
            privateTabs.forEach { $0.webView.stopLoading() }
            privateTabs.removeAll()
            privateDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                        modifiedSince: .distantPast) {}
            if current == nil, let fallback = tabs.last {
                isPrivateMode = false
                selectedID = fallback.id
            }
        } else {
            tabs.forEach { $0.webView.stopLoading() }
            tabs.removeAll()
            if !isPrivateMode || current == nil {
                let fresh = makeTab(url: nil, isPrivate: false, loadImmediately: true)
                tabs.append(fresh)
                isPrivateMode = false
                selectedID = fresh.id
            }
        }
        scheduleSave()
    }

    func closeOthers(than keep: BrowserTab) {
        if keep.isPrivate {
            privateTabs.removeAll { $0.id != keep.id }
        } else {
            tabs.removeAll { $0.id != keep.id }
        }
        selectedID = keep.id
        scheduleSave()
    }

    /// Sekme ekranında Özel / Normal arasında geçiş
    func switchMode(toPrivate: Bool) {
        isPrivateMode = toPrivate
        let pool = toPrivate ? privateTabs : tabs
        if let last = pool.last {
            selectedID = last.id
            last.activate()
        }
    }

    /// Seçili modda hiç sekme yoksa yeni bir tane aç
    func ensureSelection() {
        if current == nil {
            newTab(url: nil, isPrivate: isPrivateMode, select: true)
        }
    }

    func tabDidChange() {
        scheduleSave()
    }

    // MARK: - Kalıcılık (yalnızca normal sekmeler)

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    private func save() {
        let entries: [[String: String]] = tabs.map { tab in
            ["id": tab.id.uuidString, "url": tab.displayURL?.absoluteString ?? ""]
        }
        UserDefaults.standard.set(entries, forKey: savedTabsKey)
        if let current, !current.isPrivate {
            UserDefaults.standard.set(current.id.uuidString, forKey: savedSelectionKey)
        }
    }

    private func restore() {
        guard let entries = UserDefaults.standard.array(forKey: savedTabsKey) as? [[String: String]] else { return }
        let selected = UserDefaults.standard.string(forKey: savedSelectionKey)
        for entry in entries.prefix(60) {
            let id = entry["id"].flatMap { UUID(uuidString: $0) } ?? UUID()
            let url = entry["url"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
            tabs.append(makeTab(url: url, isPrivate: false, loadImmediately: false, id: id))
        }
        if let selected, let match = tabs.first(where: { $0.id.uuidString == selected }) {
            selectedID = match.id
        } else {
            selectedID = tabs.last?.id
        }
    }
}
