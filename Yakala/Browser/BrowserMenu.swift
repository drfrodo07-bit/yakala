import SwiftUI
import UIKit
import WebKit

enum BrowserMenuAction {
    case open(BrowserSheet)
    case reader
    case findInPage
    case close
}

/// Aloha tarzı sayfa menüsü
struct BrowserMenuView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var manager: TabManager
    var onAction: (BrowserMenuAction) -> Void

    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var settings = BrowserSettings.shared
    @State private var confirmClear = false

    private var hasPage: Bool { tab.url != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header

                    Button { onAction(.open(.siteOptions)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reklam engelleme ve site seçenekleri")
                                    .font(.subheadline.weight(.semibold))
                                Text(settings.isAdBlockActive(for: tab.host) ? "Bu sitede reklamlar engelleniyor" : "Bu sitede reklam engelleyici kapalı")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        MenuTile(title: "Masaüstü", icon: "desktopcomputer", active: tab.desktopMode, enabled: hasPage) {
                            tab.toggleDesktopMode()
                        }
                        MenuTile(title: "Koyu sayfa", icon: "moon", active: tab.darkPage, enabled: hasPage) {
                            tab.toggleDarkPage()
                        }
                        MenuTile(title: "Çevir", icon: "character.bubble", active: false, enabled: hasPage) {
                            tab.translatePage()
                            onAction(.close)
                        }
                        MenuTile(title: "Okuma modu", icon: "doc.plaintext", active: false, enabled: hasPage) {
                            onAction(.reader)
                        }
                        MenuTile(title: "Yer imleri", icon: "book", active: false, enabled: true) {
                            onAction(.open(.bookmarks))
                        }
                        MenuTile(title: "Geçmiş", icon: "clock", active: false, enabled: true) {
                            onAction(.open(.history))
                        }
                        MenuTile(title: "İndirilenler", icon: "arrow.down.circle", active: false, enabled: true) {
                            onAction(.open(.downloads))
                        }
                        MenuTile(title: "Ayarlar", icon: "gearshape", active: false, enabled: true) {
                            onAction(.open(.settings))
                        }
                    }

                    VStack(spacing: 0) {
                        if !tab.detected.isEmpty {
                            MenuRow(title: "Yakalanan videolar (\(tab.detected.count))", icon: "film.stack") {
                                onAction(.open(.capture))
                            }
                            Divider().padding(.leading, 52)
                        }
                        MenuRow(title: "Altyazı stüdyosu", icon: "captions.bubble") {
                            onAction(.open(.studio))
                        }
                        if hasPage, let url = tab.url, !tab.isPrivate {
                            Divider().padding(.leading, 52)
                            if store.isBookmarked(url) {
                                MenuRow(title: "Yer iminden kaldır", icon: "book.closed.fill") {
                                    store.removeBookmark(for: url)
                                }
                            } else {
                                MenuRow(title: "Yer imlerine ekle", icon: "book") {
                                    store.addBookmark(title: tab.title, url: url)
                                    tab.bannerMessage = "Yer imlerine eklendi"
                                }
                            }
                            Divider().padding(.leading, 52)
                            MenuRow(title: store.isFavorite(url) ? "Favorilerde" : "Favorilere ekle",
                                    icon: store.isFavorite(url) ? "star.fill" : "star") {
                                if !store.isFavorite(url) {
                                    store.addBookmark(title: tab.title, url: url, favorite: true)
                                    tab.bannerMessage = "Başlangıç sayfasına eklendi"
                                }
                            }
                        }
                        if hasPage, let url = tab.url, !tab.isPrivate {
                            Divider().padding(.leading, 52)
                            MenuRow(title: "Gizli sekmede aç", icon: "hand.raised") {
                                manager.openTab(url, isPrivate: true, select: true)
                                onAction(.close)
                            }
                        }
                        if hasPage {
                            Divider().padding(.leading, 52)
                            MenuRow(title: "Sayfada bul", icon: "magnifyingglass") {
                                onAction(.findInPage)
                            }
                            Divider().padding(.leading, 52)
                            HStack(spacing: 14) {
                                Image(systemName: "textformat.size")
                                    .frame(width: 24)
                                    .foregroundStyle(.tint)
                                Text("Yazı boyutu")
                                Spacer()
                                Button { tab.changeZoom(by: -0.1) } label: {
                                    Image(systemName: "textformat.size.smaller")
                                        .frame(width: 34, height: 30)
                                }
                                .buttonStyle(.bordered)
                                Button { tab.resetZoom() } label: {
                                    Text("%\(Int((tab.pageZoom * 100).rounded()))")
                                        .font(.footnote.monospacedDigit())
                                        .frame(minWidth: 44)
                                }
                                .buttonStyle(.plain)
                                Button { tab.changeZoom(by: 0.1) } label: {
                                    Image(systemName: "textformat.size.larger")
                                        .frame(width: 34, height: 30)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            Divider().padding(.leading, 52)
                            MenuRow(title: "Bağlantıyı kopyala", icon: "link") {
                                if let url = tab.url { UIPasteboard.general.url = url }
                                tab.bannerMessage = "Bağlantı kopyalandı"
                                onAction(.close)
                            }
                        }
                        Divider().padding(.leading, 52)
                        MenuRow(title: "Geçmiş bilgilerini sil", icon: "trash", destructive: true) {
                            confirmClear = true
                        }
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(16)
            }
            .navigationBarHidden(true)
            .confirmationDialog("Geçmiş bilgileri silinsin mi?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Yalnızca geçmişi sil", role: .destructive) {
                    store.clearHistory()
                    tab.bannerMessage = "Geçmiş silindi"
                }
                Button("Geçmiş, çerezler ve site verileri", role: .destructive) {
                    store.clearHistory()
                    WebDataCleaner.clearAll()
                    tab.bannerMessage = "Tüm tarama verileri silindi"
                }
                Button("Vazgeç", role: .cancel) {}
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let url = tab.url {
                SiteIcon(url: url, title: tab.title)
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "globe").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "Başlangıç Sayfası" : tab.title)
                    .font(.headline)
                    .lineLimit(1)
                if let host = tab.url?.host {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let url = tab.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                }
            }
        }
        .padding(.top, 8)
    }
}

struct MenuTile: View {
    let title: String
    let icon: String
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 54, height: 50)
                    .background(active ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct MenuRow: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(destructive ? Color.red : Color.accentColor)
                Text(title)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Site seçenekleri: reklam engelleyici, açılır pencereler, masaüstü, koyu sayfa
struct SiteOptionsView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var settings = BrowserSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var siteName: String {
        BrowserSettings.baseHost(tab.host) ?? "Bu site"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Reklam engelleyici (tüm siteler)", isOn: $settings.adBlockEnabled)
                    if settings.adBlockEnabled, tab.host != nil {
                        Toggle("\(siteName) için engelle", isOn: Binding(
                            get: { settings.isAdBlockActive(for: tab.host) },
                            set: { value in
                                settings.setAdBlock(value, for: tab.host)
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    tab.webView.reload()
                                }
                            }
                        ))
                    }
                    Toggle("Açılır pencereleri engelle", isOn: $settings.popupBlockEnabled)
                } header: {
                    Text("Reklam ve gizlilik")
                } footer: {
                    Text("Bir site reklam engelleyiciyle düzgün çalışmazsa yalnızca o site için kapatabilirsin.")
                }

                if tab.url != nil {
                    Section("Bu sekme") {
                        Toggle("Masaüstü sürümü", isOn: Binding(get: { tab.desktopMode }, set: { _ in tab.toggleDesktopMode() }))
                        Toggle("Sayfayı koyu göster", isOn: Binding(get: { tab.darkPage }, set: { _ in tab.toggleDarkPage() }))
                    }
                }
            }
            .navigationTitle(siteName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }
}

enum WebDataCleaner {
    @MainActor
    static func clearAll() {
        let store = WebKit.WKWebsiteDataStore.default()
        store.removeData(ofTypes: WebKit.WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}
