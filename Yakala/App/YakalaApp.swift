import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Sessiz modda da videoların sesi çalsın
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        _ = DownloadManager.shared
        return true
    }

    /// Arka planda biten indirmeler için iOS uygulamayı uyandırdığında çağrılır
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.storeBackgroundCompletion(completionHandler, for: identifier)
    }
}

@main
struct YakalaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
        }
    }
}
