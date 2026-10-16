import SwiftUI
import UIKit
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @State private var showMedia = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            ZStack(alignment: .top) {
                WebViewContainer(webView: model.webView)
                if model.isLoading {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                }
            }

            if let message = model.bannerMessage {
                Text(message)
                    .font(.footnote)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.15))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            toolbar
        }
        .animation(.easeInOut(duration: 0.2), value: model.bannerMessage)
        .onChange(of: model.bannerMessage) {
            guard let shown = model.bannerMessage else { return }
            let browser = model
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if browser.bannerMessage == shown {
                    browser.bannerMessage = nil
                }
            }
        }
        .sheet(isPresented: $showMedia) {
            DetectedMediaSheet(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    private var addressBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: addressFocused ? "magnifyingglass" : "globe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("Ara veya adres yaz", text: $model.addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        model.load(model.addressText)
                        addressFocused = false
                    }
                if addressFocused && !model.addressText.isEmpty {
                    Button {
                        model.addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if addressFocused {
                Button("Vazgeç") { addressFocused = false }
            } else {
                Button {
                    model.reloadOrStop()
                } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var toolbar: some View {
        HStack {
            Button { model.webView.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)

            Spacer()

            Button { model.webView.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)

            Spacer()

            Button { showMedia = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: model.detected.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .font(.title2)
                    if !model.detected.isEmpty {
                        Text("\(model.detected.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 10, y: -6)
                    }
                }
            }

            Spacer()

            Button { model.goHome() } label: {
                Image(systemName: "house")
            }

            Spacer()

            Button {
                if let url = model.webView.url {
                    UIPasteboard.general.url = url
                    model.bannerMessage = "Bağlantı kopyalandı"
                }
            } label: {
                Image(systemName: "link")
            }
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct DetectedMediaSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.detected.isEmpty {
                    ContentUnavailableView(
                        "Henüz video yakalanmadı",
                        systemImage: "film",
                        description: Text("Sayfadaki videoyu oynatmaya başlat; uygulama videoyu otomatik olarak yakalar ve burada listeler.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(model.detected) { item in
                                row(item)
                            }
                        } footer: {
                            Text("“Akış (HLS)” genellikle videonun tamamıdır, önce onu dene. DRM korumalı videolar (Netflix vb.) indirilemez. İndirmeler arka planda devam eder.")
                        }
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
                    Button("Temizle") { model.clearDetected() }
                        .disabled(model.detected.isEmpty)
                }
            }
        }
    }

    private func row(_ item: DetectedMedia) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isHLS ? "dot.radiowaves.left.and.right" : "film")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.pageTitle.isEmpty ? item.displayName : item.pageTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(item.kindLabel) · \(item.url.host ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.download(item)
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
