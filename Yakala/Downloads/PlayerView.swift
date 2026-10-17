import SwiftUI
import AVFoundation
import Combine
import UIKit

// MARK: - Oynatıcı mantığı

@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer
    let url: URL

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var rate: Float = 1

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastScrubSeek = Date.distantPast

    private let startTime: Double

    init(url: URL, headers: [String: String] = [:], startTime: Double = 0) {
        self.url = url
        self.startTime = startTime
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTime(time)
            }
        }

        player.publisher(for: \.timeControlStatus)
            .map { $0 != .paused }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPlaying)

        // Hazır olunca kaldığı yerden devam et
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .first(where: { $0 == .readyToPlay })
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restorePosition()
                }
            }
            .store(in: &cancellables)
    }

    private func handleTime(_ time: CMTime) {
        if !isScrubbing {
            let seconds = time.seconds
            currentTime = seconds.isFinite ? seconds : 0
        }
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0 && currentTime >= duration - 0.5 {
                seek(to: 0)
            }
            player.playImmediately(atRate: rate)
        }
    }

    func play() {
        player.playImmediately(atRate: rate)
    }

    func seek(by delta: Double) {
        let upper = duration > 0 ? duration : currentTime + abs(delta)
        seek(to: min(max(0, currentTime + delta), upper))
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    /// Kaydırma çubuğu sürüklenirken hızlı önizleme
    func scrub(to seconds: Double) {
        currentTime = seconds
        guard Date().timeIntervalSince(lastScrubSeek) > 0.12 else { return }
        lastScrubSeek = Date()
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }

    // MARK: Kaldığın yerden devam

    private var memoryKey: String {
        "yakala.position." + url.lastPathComponent
    }

    private func restorePosition() {
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
            duration = itemDuration
        }
        if startTime > 1 {
            seek(to: startTime)
            return
        }
        guard url.isFileURL else { return }
        let saved = UserDefaults.standard.double(forKey: memoryKey)
        if saved > 5, duration <= 0 || saved < duration - 5 {
            seek(to: saved)
        }
    }

    func teardown() {
        let position = currentTime
        if !url.isFileURL {
            // akış: konumu kaydetme
        } else if duration > 0, position > 5, position < duration - 5 {
            UserDefaults.standard.set(position, forKey: memoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: memoryKey)
        }
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        cancellables.removeAll()
    }
}

// MARK: - Video yüzeyi (hazır iOS kontrolleri olmadan)

final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.playerLayer.videoGravity = gravity
    }
}

// MARK: - Oynatıcı ekranı

struct PlayerView: View {
    let url: URL
    var title: String?
    var onDownload: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PlayerController
    @AppStorage("yakala.seekInterval") private var seekInterval: Int = 10
    @State private var showControls = true
    @State private var fillScreen = false
    @State private var flash: SeekFlash?
    @State private var hideTask: Task<Void, Never>?
    @State private var flashTask: Task<Void, Never>?
    @State private var downloadStarted = false

    private static let intervals = [10, 15, 30]
    private static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    struct SeekFlash: Equatable {
        let forward: Bool
        let text: String
    }

    init(url: URL, headers: [String: String] = [:], startTime: Double = 0, title: String? = nil, onDownload: (() -> Void)? = nil) {
        self.url = url
        self.title = title
        self.onDownload = onDownload
        _controller = StateObject(wrappedValue: PlayerController(url: url, headers: headers, startTime: startTime))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(player: controller.player, gravity: fillScreen ? .resizeAspectFill : .resizeAspect)
                .ignoresSafeArea()

            gestureLayer

            if let flash {
                seekFlashView(flash)
                    .transition(.opacity)
            }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .onAppear {
            controller.play()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            flashTask?.cancel()
            controller.teardown()
        }
        .onChange(of: controller.isPlaying) {
            if controller.isPlaying {
                scheduleHide()
            } else {
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) { showControls = true }
            }
        }
    }

    // MARK: Dokunma alanları: tek dokunuş = kontroller, çift dokunuş = sar

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { quickSeek(forward: false) }
                .onTapGesture { toggleControls() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { quickSeek(forward: true) }
                .onTapGesture { toggleControls() }
        }
        .ignoresSafeArea()
    }

    private func seekFlashView(_ flash: SeekFlash) -> some View {
        HStack {
            if flash.forward { Spacer() }
            HStack(spacing: 6) {
                Image(systemName: flash.forward ? "goforward" : "gobackward")
                Text(flash.text)
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.horizontal, 36)
            if !flash.forward { Spacer() }
        }
        .allowsHitTesting(false)
    }

    // MARK: Kontroller (yalnızca üst ve alt şerit; ortada buton yok)

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }

            Text(title ?? url.deletingPathExtension().lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let onDownload {
                Button {
                    guard !downloadStarted else { return }
                    onDownload()
                    downloadStarted = true
                    scheduleHide()
                } label: {
                    Label(downloadStarted ? "İndiriliyor" : "İndir",
                          systemImage: downloadStarted ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(downloadStarted ? Color.green : Color.accentColor))
                }
                .buttonStyle(.plain)
            }

            Menu {
                Picker("Atlama süresi", selection: $seekInterval) {
                    ForEach(Self.intervals, id: \.self) { value in
                        Text("\(value) saniye").tag(value)
                    }
                }
            } label: {
                Label("\(seekInterval) sn", systemImage: "timer")
                    .font(.footnote.weight(.semibold))
            }

            Menu {
                Picker("Hız", selection: Binding(get: { controller.rate }, set: { controller.setRate($0); scheduleHide() })) {
                    ForEach(Self.rates, id: \.self) { value in
                        Text(Self.rateLabel(value)).tag(value)
                    }
                }
            } label: {
                Text(Self.rateLabel(controller.rate))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }

            Button {
                fillScreen.toggle()
                scheduleHide()
            } label: {
                Image(systemName: fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(Self.timeString(controller.currentTime))
                    .monospacedDigit()
                Slider(
                    value: Binding(
                        get: { min(controller.currentTime, max(controller.duration, 0.1)) },
                        set: { controller.scrub(to: $0) }
                    ),
                    in: 0...max(controller.duration, 0.1),
                    onEditingChanged: { editing in
                        controller.isScrubbing = editing
                        if editing {
                            hideTask?.cancel()
                        } else {
                            controller.seek(to: controller.currentTime)
                            scheduleHide()
                        }
                    }
                )
                .tint(.white)
                Text("-" + Self.timeString(max(controller.duration - controller.currentTime, 0)))
                    .monospacedDigit()
            }
            .font(.caption)

            HStack(spacing: 44) {
                Button {
                    controller.seek(by: -Double(seekInterval))
                    scheduleHide()
                } label: {
                    Image(systemName: "gobackward.\(seekInterval)")
                }

                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 30)
                }

                Button {
                    controller.seek(by: Double(seekInterval))
                    scheduleHide()
                } label: {
                    Image(systemName: "goforward.\(seekInterval)")
                }
            }
            .font(.title3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: Davranış

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleHide() }
    }

    private func quickSeek(forward: Bool) {
        controller.seek(by: forward ? Double(seekInterval) : -Double(seekInterval))
        let text = (forward ? "+" : "−") + "\(seekInterval) sn"
        withAnimation(.easeOut(duration: 0.12)) {
            flash = SeekFlash(forward: forward, text: text)
        }
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { flash = nil }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, controller.isPlaying, !controller.isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func rateLabel(_ rate: Float) -> String {
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        return String(format: "%gx", rate)
    }
}
