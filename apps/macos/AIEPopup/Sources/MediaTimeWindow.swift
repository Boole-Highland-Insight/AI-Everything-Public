import AppKit
import AVFoundation
import AVKit
import Foundation
import SwiftUI

final class MediaTimeWindow: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MediaTimeWindow()

    enum State: Equatable { case loading, ready, failed(String) }
    @Published private(set) var state: State = .loading
    private var window: NSWindow?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var loadTimeout: DispatchWorkItem?
    private var seekGeneration = 0

    var isVisible: Bool { window?.isVisible == true }
    var playbackTime: Double? { player?.currentTime().seconds }
    var playbackRate: Float? { player?.rate }

    func owns(_ candidate: NSWindow?) -> Bool { window != nil && candidate === window }

    @discardableResult
    func show(url: URL, startSeconds: Double, endSeconds: Double?, muted: Bool = false) -> Bool {
        guard let start = MediaOpenPolicy.seekSeconds(startSeconds) else { return false }
        close()
        state = .loading
        let player = AVPlayer(url: url)
        player.isMuted = muted
        self.player = player
        let view = NSHostingView(rootView: MediaPlaybackView(
            model: self, player: player, url: url, start: start, end: endSeconds
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.title = "\(url.lastPathComponent) · \(MediaOpenPolicy.rangeLabel(start: start, end: endSeconds))"
        self.window = window
        AppWindowPresence.shared.show(window)
        NSApp.activate(ignoringOtherApps: true)

        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("文件已移动或无法读取。请在 Finder 中确认位置后重新搜索。")
            return true
        }
        let timeout = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player, self.player === player, self.state == .loading else { return }
            self.fail("读取或定位超时。可重试，或用外部播放器打开。")
        }
        loadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.state == .loading else { return }
                    self.seek(player, to: start)
                case .failed:
                    self.fail("无法播放此文件，可能格式不受支持或文件已损坏。可以尝试外部播放器。")
                default: break
                }
            }
        }
        return true
    }

    func returnToMoment(_ seconds: Double) {
        guard let player, state == .ready else { return }
        seek(player, to: seconds)
    }

    func pause() { player?.pause() }

    private func seek(_ player: AVPlayer, to seconds: Double) {
        seekGeneration += 1
        let generation = seekGeneration
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > seconds else {
            fail("命中时间已超出当前文件长度。文件可能已更新，请重新索引后再试。")
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player,
                      self.seekGeneration == generation else { return }
                guard finished else { self.fail("未能跳到命中位置，请重试。"); return }
                self.loadTimeout?.cancel()
                self.state = .ready
                player.play()
            }
        }
    }

    private func fail(_ message: String) {
        seekGeneration += 1
        loadTimeout?.cancel()
        observation?.invalidate()
        observation = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        state = .failed(message)
    }

    func close() {
        let closing = window
        releasePlayer()
        window = nil
        closing?.close()
    }

    private func releasePlayer() {
        seekGeneration += 1
        loadTimeout?.cancel()
        loadTimeout = nil
        observation?.invalidate()
        observation = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        releasePlayer()
        window = nil
    }
}

private struct MediaPlaybackView: View {
    @ObservedObject var model: MediaTimeWindow
    let player: AVPlayer
    let url: URL
    let start: Double
    let end: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("命中片段 \(MediaOpenPolicy.rangeLabel(start: start, end: end))", systemImage: "play.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Spacer()
                Button("回到命中位置") { model.returnToMoment(start) }
                    .disabled(model.state != .ready)
                Button(MediaExternalOpener.title(url: url, seconds: start)) {
                    model.pause()
                    MediaExternalOpener.open(url: url, seconds: start, endSeconds: end)
                }
            }
            .padding(12)
            Divider()
            ZStack {
                NativeMediaPlayer(player: player)
                switch model.state {
                case .loading:
                    ProgressView("正在定位到 \(MediaOpenPolicy.clock(start))…")
                        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(message).multilineTextAlignment(.center).frame(maxWidth: 360)
                        Button("重试") { model.show(url: url, startSeconds: start, endSeconds: end) }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                case .ready: EmptyView()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NativeMediaPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
