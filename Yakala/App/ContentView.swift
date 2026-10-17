import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var subtitleJob = SubtitleJob()
    @ObservedObject private var settings = BrowserSettings.shared

    var body: some View {
        BrowserView()
            .environmentObject(subtitleJob)
            .preferredColorScheme(settings.appearance.colorScheme)
            // Çeviri, ekran değişse de yarıda kalmasın diye en üst görünüme bağlı
            .translationTask(subtitleJob.translationConfiguration) { [job = subtitleJob] session in
                await job.translate(using: session)
            }
    }
}
