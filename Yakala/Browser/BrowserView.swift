import SwiftUI
import UIKit
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView {
            attach(to: uiView)
        }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// Tarayıcının ana ekranı
struct BrowserView: View {
    @StateObject private var manager = TabManager()

    var body: some View {
        Group {
            if let tab = manager.current {
                ActiveTabView(tab: tab, manager: manager)
                    .id(tab.id)
            } else {
                Color(.systemBackground)
                    .onAppear { manager.ensureSelection() }
            }
        }
    }
}

enum BrowserSheet: String, Identifiable {
    case menu
    case siteOptions
    case capture
    case bookmarks
    case history
    case downloads
    case settings
    case studio

    var id: String { rawValue }
}

enum BrowserCover: Identifiable {
    case tabs
    case takeover(TakeoverRequest)
    case reader(ReaderContent)

    var id: String {
        switch self {
        case .tabs: return "tabs"
        case .takeover(let request): return "takeover-\(request.id)"
        case .reader(let content): return "reader-\(content.id)"
        }
    }
}

struct ActiveTabView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var manager: TabManager
    @ObservedObject private var settings = BrowserSettings.shared
    @EnvironmentObject private var downloads: DownloadManager

    @State private var sheet: BrowserSheet?
    @State private var pendingSheet: BrowserSheet?
    @State private var cover: BrowserCover?
    @State private var editingAddress = false

    private var collapsed: Bool { tab.barsCollapsed && !tab.showsStartPage }

    var body: some View {
        VStack(spacing: 0) {
            if settings.addressBarPosition == .top {
                VStack(spacing: 0) {
                    addressBar
                    progressBar
                }
                .background(.bar)
            }

            ZStack(alignment: .bottom) {
                if tab.showsStartPage {
                    StartPageView(tab: tab, onEditFavorites: { sheet = .bookmarks })
                } else {
                    WebViewContainer(webView: tab.webView)
                }

                VStack(spacing: 8) {
                    if let message = tab.bannerMessage {
                        BannerView(text: message)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !tab.detected.isEmpty && (tab.mainVideoCount > 0 || !settings.hideShortVideos) {
                        CapturePill(tab: tab) { sheet = .capture }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.bottom, 10)
                .animation(.spring(duration: 0.3), value: tab.detected.count)
                .animation(.easeInOut(duration: 0.2), value: tab.bannerMessage)
            }

            VStack(spacing: 0) {
                if settings.addressBarPosition == .bottom {
                    progressBar
                    addressBar
                }
                if !collapsed {
                    toolbar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(.bar)
        }
        .animation(.easeInOut(duration: 0.22), value: collapsed)
        .overlay {
            if editingAddress {
                AddressEntryView(tab: tab, position: settings.addressBarPosition) {
                    editingAddress = false
                }
                .transition(.opacity)
            }
        }
        .onChange(of: tab.bannerMessage) {
            guard let shown = tab.bannerMessage else { return }
            let current = tab
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if current.bannerMessage == shown { current.bannerMessage = nil }
            }
        }
        .onChange(of: tab.takeoverRequest?.id) {
            if let request = tab.takeoverRequest {
                tab.takeoverRequest = nil
                cover = .takeover(request)
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let next = pendingSheet {
                pendingSheet = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    sheet = next
                }
            }
        }) { item in
            sheetContent(item)
        }
        .fullScreenCover(item: $cover) { item in
            coverContent(item)
        }
    }

    // MARK: Çubuklar

    private var progressBar: some View {
        GeometryReader { proxy in
            if tab.isLoading && tab.progress < 1 {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * tab.progress)
                    .animation(.linear(duration: 0.2), value: tab.progress)
            }
        }
        .frame(height: 2)
    }

    private var addressBar: some View {
        AddressBarView(tab: tab,
                       collapsed: collapsed,
                       adBlockActive: settings.isAdBlockActive(for: tab.host),
                       onTapAddress: {
                           if collapsed {
                               tab.barsCollapsed = false
                           } else {
                               editingAddress = true
                           }
                       },
                       onShield: { sheet = .siteOptions })
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: {
                Image(systemName: "chevron.backward")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!tab.canGoBack)

            Button { tab.webView.goForward() } label: {
                Image(systemName: "chevron.forward")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!tab.canGoForward)

            Button { sheet = .menu } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(maxWidth: .infinity)
            }

            Button { sheet = .downloads } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle")
                    if downloads.activeCount > 0 {
                        Text("\(downloads.activeCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 10, y: -7)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Button {
                tab.takeSnapshot()
                cover = .tabs
            } label: {
                ZStack {
                    Image(systemName: "square.on.square")
                    Text("\(min(manager.visibleTabs.count, 99))")
                        .font(.system(size: 9, weight: .bold))
                        .offset(x: 2, y: 2)
                }
                .frame(maxWidth: .infinity)
            }
            .contextMenu {
                Button {
                    manager.newTab(isPrivate: false)
                } label: {
                    Label("Yeni Sekme", systemImage: "plus.square.on.square")
                }
                Button {
                    manager.newTab(isPrivate: true)
                } label: {
                    Label("Yeni Özel Sekme", systemImage: "hand.raised")
                }
                Divider()
                Button(role: .destructive) {
                    manager.close(tab)
                } label: {
                    Label("Bu Sekmeyi Kapat", systemImage: "xmark")
                }
            }
        }
        .font(.title3)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Sayfalar

    @ViewBuilder
    private func sheetContent(_ item: BrowserSheet) -> some View {
        switch item {
        case .menu:
            BrowserMenuView(tab: tab, manager: manager) { action in
                handleMenu(action)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .siteOptions:
            SiteOptionsView(tab: tab)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        case .capture:
            CaptureSheet(tab: tab) { media in
                sheet = nil
                Task { @MainActor in
                    let headers = await tab.requestHeaders(for: media.url, referer: media.pageURL)
                    cover = .takeover(TakeoverRequest(url: media.url,
                                                      pageURL: media.pageURL,
                                                      title: media.pageTitle,
                                                      startTime: 0,
                                                      headers: headers))
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .bookmarks:
            BrowserLibraryView(initial: .bookmarks) { url in
                sheet = nil
                tab.load(url)
            }
        case .history:
            BrowserLibraryView(initial: .history) { url in
                sheet = nil
                tab.load(url)
            }
        case .downloads:
            LibraryView(showsCloseButton: true)
        case .settings:
            SettingsView()
        case .studio:
            SubtitleStudioView(showsCloseButton: true)
        }
    }

    @ViewBuilder
    private func coverContent(_ item: BrowserCover) -> some View {
        switch item {
        case .tabs:
            TabsOverview(manager: manager) { cover = nil }
        case .takeover(let request):
            PlayerView(url: request.url,
                       headers: request.headers,
                       startTime: request.startTime,
                       title: request.title,
                       onDownload: {
                           tab.startDownload(url: request.url, name: request.title, referer: request.pageURL)
                       })
        case .reader(let content):
            ReaderView(content: content)
        }
    }

    private func handleMenu(_ action: BrowserMenuAction) {
        switch action {
        case .open(let next):
            pendingSheet = next
            sheet = nil
        case .reader:
            sheet = nil
            Task { @MainActor in
                if let content = await tab.readerContent() {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    cover = .reader(content)
                } else {
                    tab.bannerMessage = "Bu sayfada okunacak metin bulunamadı"
                }
            }
        case .findInPage:
            sheet = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                tab.findInPage()
            }
        case .close:
            sheet = nil
        }
    }
}

// MARK: - Adres çubuğu

struct AddressBarView: View {
    @ObservedObject var tab: BrowserTab
    var collapsed: Bool
    var adBlockActive: Bool
    var onTapAddress: () -> Void
    var onShield: () -> Void

    private var hostText: String {
        guard let host = tab.displayURL?.host else { return "Ara veya adres yaz" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        if collapsed {
            Button(action: onTapAddress) {
                HStack(spacing: 4) {
                    if tab.isPrivate {
                        Image(systemName: "hand.raised.fill").font(.caption2)
                    }
                    Text(hostText)
                        .font(.footnote)
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Button(action: onShield) {
                    Image(systemName: adBlockActive ? "shield.lefthalf.filled" : "shield.slash")
                        .foregroundStyle(adBlockActive ? Color.green : Color.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)

                Button(action: onTapAddress) {
                    HStack(spacing: 6) {
                        if tab.isPrivate {
                            Image(systemName: "hand.raised.fill")
                                .font(.footnote)
                                .foregroundStyle(.purple)
                        } else if tab.displayURL == nil {
                            Image(systemName: "magnifyingglass")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(hostText)
                            .font(.callout)
                            .foregroundStyle(tab.displayURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    tab.reloadOrStop()
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .opacity(tab.displayURL == nil ? 0 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground).opacity(tab.isPrivate ? 0.6 : 1),
                        in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tab.isPrivate ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Adres yazma ekranı

struct AddressEntryView: View {
    @ObservedObject var tab: BrowserTab
    var position: AddressBarPosition
    var onClose: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var settings = BrowserSettings.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if position == .top { field }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty || text == tab.displayURL?.absoluteString {
                        FavoritesGrid(favorites: store.favorites) { url in
                            go(url)
                        }
                        .padding(.top, 16)
                    } else {
                        ForEach(store.suggestions(for: text, engine: settings.searchEngine)) { suggestion in
                            Button {
                                if let url = suggestion.url {
                                    go(url)
                                } else if let query = suggestion.query {
                                    submit(query)
                                }
                            } label: {
                                SuggestionRow(suggestion: suggestion, engine: settings.searchEngine)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            if position == .bottom { field }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            text = tab.displayURL?.absoluteString ?? ""
            focused = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ara veya adres yaz", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { submit(text) }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule(style: .continuous))

            Button("Vazgeç") {
                focused = false
                onClose()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func submit(_ value: String) {
        focused = false
        tab.load(value)
        onClose()
    }

    private func go(_ url: URL) {
        focused = false
        tab.load(url)
        onClose()
    }
}

struct SuggestionRow: View {
    let suggestion: AddressSuggestion
    let engine: SearchEngine

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.kind == .search ? "\(engine.title)'da ara: \(suggestion.title)" : suggestion.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let url = suggestion.url {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch suggestion.kind {
        case .search: return "magnifyingglass"
        case .bookmark: return "book"
        case .history: return "clock"
        }
    }
}

// MARK: - Başlangıç sayfası

struct StartPageView: View {
    @ObservedObject var tab: BrowserTab
    var onEditFavorites: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image("BrandIcon")
                        .resizable()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("iCatch")
                        .font(.title2.weight(.heavy))
                    Spacer()
                }
                .padding(.top, 4)

                if tab.isPrivate {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title)
                            .foregroundStyle(.purple)
                        Text("Özel Dolaşma")
                            .font(.title2.bold())
                        Text("iCatch, özel sekmelerde gittiğin sayfaları, arama geçmişini ve çerezleri sekmeleri kapattığında unutur. İndirdiğin dosyalar ise İndirilenler'de kalır.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Favoriler")
                            .font(.title3.bold())
                        Spacer()
                        Button("Düzenle", action: onEditFavorites)
                            .font(.subheadline)
                    }
                    FavoritesGrid(favorites: store.favorites) { url in
                        tab.load(url)
                    }
                }

                if !tab.isPrivate {
                    let frequent = store.frequentlyVisited()
                    if !frequent.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sık Ziyaret Edilenler")
                                .font(.title3.bold())
                            SiteGrid(items: frequent.map { ($0.title, $0.url) }) { url in
                                tab.load(url)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Gizlilik")
                        .font(.title3.bold())
                    HStack(spacing: 14) {
                        Image(systemName: settings.adBlockEnabled ? "shield.lefthalf.filled" : "shield.slash")
                            .font(.title2)
                            .foregroundStyle(settings.adBlockEnabled ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reklam engelleyici")
                                .font(.subheadline.weight(.semibold))
                            Text(settings.adBlockEnabled ? "Reklamlar ve izleyiciler engelleniyor" : "Kapalı")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.adBlockEnabled)
                            .labelsHidden()
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(.systemBackground))
    }
}

struct FavoritesGrid: View {
    let favorites: [Bookmark]
    var onOpen: (URL) -> Void

    var body: some View {
        SiteGrid(items: favorites.map { ($0.title, $0.url) }, onOpen: onOpen)
    }
}

struct SiteGrid: View {
    let items: [(String, URL)]
    var onOpen: (URL) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    onOpen(item.1)
                } label: {
                    VStack(spacing: 6) {
                        SiteIcon(url: item.1, title: item.0)
                            .frame(width: 64, height: 64)
                        Text(item.0)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SiteIcon: View {
    let url: URL
    let title: String

    private var iconURL: URL? {
        guard let host = url.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        Text(String(title.prefix(1)).uppercased())
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
}

// MARK: - Küçük parçalar

struct BannerView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 20)
    }
}

/// Video yakalanınca beliren küçük düğme (Aloha gibi)
struct CapturePill: View {
    @ObservedObject var tab: BrowserTab
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.detected.contains(where: \.isPlaying) ? "Oynatılan videoyu indir" : "Video yakalandı")
                        .font(.subheadline.weight(.semibold))
                    if let first = tab.sortedDetected.first, let duration = first.duration {
                        Text(PlayerView.timeString(duration))
                            .font(.caption2)
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                }
                if tab.mainVideoCount > 1 {
                    Text("\(tab.mainVideoCount)")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.25)))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(Color.accentColor))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }
}
