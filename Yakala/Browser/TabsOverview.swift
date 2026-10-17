import SwiftUI

/// Safari tarzı sekme ekranı (normal ve özel sekmeler)
struct TabsOverview: View {
    @ObservedObject var manager: TabManager
    var onDone: () -> Void

    @State private var confirmCloseAll = false
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Button {
                        manager.newTab(isPrivate: false)
                        onDone()
                    } label: {
                        Label("Yeni Sekme", systemImage: "plus.square.on.square")
                    }
                    Button {
                        manager.newTab(isPrivate: true)
                        onDone()
                    } label: {
                        Label("Yeni Özel Sekme", systemImage: "hand.raised")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmCloseAll = true
                    } label: {
                        Label(manager.isPrivateMode ? "Tüm özel sekmeleri kapat" : "Tüm sekmeleri kapat", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                Spacer()
                Text(manager.isPrivateMode ? "Özel Sekmeler" : "\(manager.tabs.count) Sekme")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                if manager.visibleTabs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: manager.isPrivateMode ? "hand.raised.fill" : "square.on.square")
                            .font(.largeTitle)
                            .foregroundStyle(manager.isPrivateMode ? Color.purple : Color.secondary)
                        Text(manager.isPrivateMode ? "Özel Dolaşma" : "Açık sekme yok")
                            .font(.title3.bold())
                        if manager.isPrivateMode {
                            Text("Özel sekmelerde gezinme geçmişi ve çerezler saklanmaz. Yeni özel sekme açmak için + düğmesine dokun.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }
                    .padding(.top, 120)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(manager.visibleTabs) { tab in
                            TabCard(tab: tab, isSelected: tab.id == manager.selectedID) {
                                manager.select(tab)
                                onDone()
                            } onClose: {
                                withAnimation { manager.close(tab) }
                            } onCloseOthers: {
                                manager.closeOthers(than: tab)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            HStack(spacing: 16) {
                Button {
                    manager.newTab(isPrivate: manager.isPrivateMode)
                    onDone()
                } label: {
                    Image(systemName: "plus")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)

                Picker("Mod", selection: Binding(get: { manager.isPrivateMode },
                                                set: { manager.switchMode(toPrivate: $0) })) {
                    Text("Özel").tag(true)
                    Text("\(manager.tabs.count) Sekme").tag(false)
                }
                .pickerStyle(.segmented)

                Button {
                    manager.ensureSelection()
                    onDone()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .confirmationDialog("Sekmeler kapatılsın mı?", isPresented: $confirmCloseAll, titleVisibility: .visible) {
            Button("Tümünü kapat", role: .destructive) {
                manager.closeAll(isPrivate: manager.isPrivateMode)
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onCloseOthers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let snapshot = tab.snapshot, tab.url != nil {
                        Image(uiImage: snapshot)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(systemName: tab.displayURL == nil ? "star" : "globe")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }

            HStack(spacing: 6) {
                if let url = tab.displayURL {
                    SiteIcon(url: url, title: tab.title)
                        .frame(width: 16, height: 16)
                }
                Text(tab.title.isEmpty ? (tab.displayURL == nil ? "Başlangıç Sayfası" : (tab.host ?? "")) : tab.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contextMenu {
            Button(role: .destructive, action: onClose) {
                Label("Sekmeyi kapat", systemImage: "xmark")
            }
            Button(action: onCloseOthers) {
                Label("Diğer sekmeleri kapat", systemImage: "xmark.square")
            }
        }
    }
}
