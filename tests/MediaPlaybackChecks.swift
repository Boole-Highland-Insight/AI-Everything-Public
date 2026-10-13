import AppKit
import AVFoundation

@main enum MediaPlaybackChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do { try await run() } catch { failure = error }
            MediaTimeWindow.shared.close()
            finished = true
        }
        while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        if let failure { fputs("Media playback checks failed: \(failure)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "PlaybackChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aie-playback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("测试 'media' & #1.wav")
        try makeAudioFixture(video)
        let link = MediaOpenPolicy.iinaURL(file: video, seconds: 2.25)!
        let query = URLComponents(url: link, resolvingAgainstBaseURL: false)!.queryItems!
        try check(query.first(where: { $0.name == "url" })?.value == video.absoluteString, "IINA path encoding lost special characters")
        try check(query.first(where: { $0.name == "mpv_start" })?.value == "2.25", "IINA time lost precision")
        try check(MediaOpenPolicy.iinaURL(file: video, seconds: .nan) == nil, "NaN became an external seek")
        try check(MediaOpenPolicy.clock(3661) == "1:01:01", "Hour-long recordings are mislabelled")
        try check(MediaOpenPolicy.rangeLabel(start: 2, end: 1) == "00:02", "Invalid end time displayed as a range")
        try check(!MediaOpenPolicy.supportsExternalSeek(appID: "org.videolan.vlc"), "Unsupported player promised a time jump")

        let player = MediaTimeWindow.shared
        player.show(url: video, startSeconds: 2.25, endSeconds: 3.25, muted: true)
        try await wait { player.state != .loading }
        player.pause()
        try check(player.state == .ready, "Valid video failed: \(player.state)")
        try check(abs((player.playbackTime ?? -1) - 2.25) < 0.2, "Real video did not seek to the evidence time")
        try capture("ready")

        // A closed or replaced player's completion must never resume the old recording.
        player.show(url: video, startSeconds: 1, endSeconds: nil, muted: true)
        player.show(url: video, startSeconds: 3, endSeconds: nil, muted: true)
        try await wait { player.state != .loading }
        player.pause()
        try check(player.state == .ready && abs((player.playbackTime ?? -1) - 3) < 0.2, "Rapid selection kept an old target")
        player.returnToMoment(1)
        player.returnToMoment(2)
        try await wait { abs((player.playbackTime ?? -1) - 2) < 0.2 && player.playbackRate == 1 }
        player.pause()
        try check(player.state == .ready, "Cancelled seek broke the next seek")
        player.close()
        try await Task.sleep(for: .milliseconds(100))
        try check(!player.isVisible && player.playbackTime == nil && player.playbackRate == nil, "Closing left a player alive")
        player.show(url: video, startSeconds: 1, endSeconds: nil, muted: true)
        player.close()
        try await Task.sleep(for: .milliseconds(100))
        try check(player.playbackRate == nil, "Late readiness resumed a closed recording")

        player.show(url: video, startSeconds: 999, endSeconds: nil, muted: true)
        try await wait { player.state != .loading }
        if case .failed = player.state {} else { try check(false, "Stale time silently played another position") }
        let broken = folder.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: broken)
        player.show(url: broken, startSeconds: 1, endSeconds: nil, muted: true)
        try await wait { player.state != .loading }
        if case .failed = player.state {} else { try check(false, "Broken media lacked an error state") }
        try capture("failed")
        player.show(url: folder.appendingPathComponent("missing.mov"), startSeconds: 1, endSeconds: nil, muted: true)
        if case .failed = player.state {} else { try check(false, "Missing file lacked an error state") }
        try check(!player.show(url: video, startSeconds: .infinity, endSeconds: nil, muted: true), "Nonfinite time accepted")
        player.show(url: video, startSeconds: 0, endSeconds: nil, muted: true)
        try await wait { player.state != .loading }
        try check(player.state == .ready, "Recovery from failure or zero-second evidence failed")
        print("Media playback checks passed: generated media seeking, rapid replacement, repeated seeks, close cancellation, stale time, corrupt/missing media, recovery, zero time, IINA URL encoding and player capability labels. No personal files or external players opened.")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 25)
        while !condition() {
            if Date() > deadline { throw NSError(domain: "PlaybackChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out awaiting player"]) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private static func capture(_ name: String) throws {
        guard CommandLine.arguments.count == 2 else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
    }

    private static func makeAudioFixture(_ url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let seconds: UInt32 = 5
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = sampleRate * seconds * UInt32(channels) * bytesPerSample
        var wav = Data()
        func appendASCII(_ value: String) { wav.append(contentsOf: value.utf8) }
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        appendASCII("RIFF"); append(UInt32(36) + dataSize); appendASCII("WAVE")
        appendASCII("fmt "); append(UInt32(16)); append(UInt16(1)); append(channels)
        append(sampleRate); append(sampleRate * UInt32(channels) * bytesPerSample)
        append(UInt16(channels) * UInt16(bytesPerSample)); append(bitsPerSample)
        appendASCII("data"); append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        try wav.write(to: url, options: .atomic)
    }
}
