import SwiftUI
import Translation

enum AppTab: Hashable {
    case browser
    case library
    case subtitles
}

struct ContentView: View {
    @State private var selection: AppTab = .browser
    @StateObject private var browser = BrowserModel()
    @StateObject private var subtitleJob = SubtitleJob()

    var body: some View {
        TabView(selection: $selection) {
            BrowserView(model: browser)
                .tabItem { Label("Tarayıcı", systemImage: "globe") }
                .tag(AppTab.browser)

            LibraryView { url in
                subtitleJob.select(video: url)
                selection = .subtitles
            }
            .tabItem { Label("İndirilenler", systemImage: "arrow.down.circle") }
            .tag(AppTab.library)

            SubtitleStudioView(job: subtitleJob)
                .tabItem { Label("Altyazı", systemImage: "captions.bubble") }
                .tag(AppTab.subtitles)
        }
        // Çeviri, sekme değiştirilse de yarıda kalmasın diye en üst görünüme bağlı
        .translationTask(subtitleJob.translationConfiguration) { [job = subtitleJob] session in
            await job.translate(using: session)
        }
    }
}
