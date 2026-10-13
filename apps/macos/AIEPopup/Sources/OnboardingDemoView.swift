import SwiftUI
import AVKit

/// Bundled, silent product walkthrough. It never loads a remote URL or starts a model.
struct OnboardingDemoView: View {
    var active: Bool
    var autoplay: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var playback = OnboardingDemoPlayback()

    private var resource: String { "OnboardingDemo-" + (colorScheme == .dark ? "dark" : "light") }

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                if let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                   let poster = NSImage(contentsOf: url) {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                }
                if playback.hasStarted {
                    DemoPlayerSurface(player: playback.player)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
            .accessibilityLabel("AI Everything 界面演示：搜索旅行草稿，用咔哒再利用，并对比原版和新版本。")

            HStack {
                Text("8 秒看懂 · 示例资料，流程已缩短")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    playback.toggle()
                } label: {
                    Label(playback.playing ? "暂停" : "播放演示",
                          systemImage: playback.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .disabled(!playback.ready)
            }
            .font(.system(size: 12))
        }
        .onAppear { playback.load(resource, autoplay: autoplay && active && !reduceMotion) }
        .onChange(of: active) { _, active in if !active { playback.pause() } }
        .onChange(of: colorScheme) { _, _ in playback.load(resource, autoplay: playback.playing && !reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in if reduced { playback.pause() } }
        .onDisappear { playback.pause() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in playback.pause() }
    }
}

@MainActor final class OnboardingDemoPlayback: ObservableObject {
    let player = AVQueuePlayer()
    @Published private(set) var playing = false
    @Published private(set) var ready = false
    @Published private(set) var hasStarted = false
    private var looper: AVPlayerLooper?
    private var resource: String?

    func load(_ name: String, autoplay: Bool) {
        if resource != name {
            pause()
            looper?.disableLooping()
            player.removeAllItems()
            resource = name
            ready = false
            hasStarted = false
            guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return }
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            ready = true
        }
        if autoplay && ready { hasStarted = true; playing = true; player.play() }
    }

    func toggle() {
        guard ready else { return }
        if playing { pause() } else { hasStarted = true; playing = true; player.play() }
    }

    func pause() { player.pause(); playing = false }
}

private struct DemoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
