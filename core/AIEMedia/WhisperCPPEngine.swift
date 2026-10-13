import AVFoundation
import Foundation

/// Optional offline CLI engine. The application never downloads a model during indexing.
public struct WhisperCPPEngine: LocalSpeechEngine {
    public let modelID = "whisper.cpp-small-multilingual-v1"
    public init() {}
    public static var executable: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    public static var model: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Everything/Speech/ggml-small.bin")
    }
    public static var isInstalled: Bool { executable != nil && FileManager.default.fileExists(atPath: model.path) }
    public func prepare(locale: String) async throws {
        guard Self.isInstalled else { throw NSError(domain: "AIEMedia", code: 5, userInfo: [NSLocalizedDescriptionKey: "请先运行 tools/setup_local_speech.sh 安装本机 Whisper"] ) }
    }
    public func transcribe(audioURL: URL, locale: String) async throws -> String {
        try await prepare(locale: locale)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aie-whisper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("input.wav"), output = directory.appendingPathComponent("transcript")
        try Self.convertToWAV(audioURL, destination: wav)
        let process = Process()
        process.executableURL = Self.executable
        let language = locale == "auto" ? "auto" : String(locale.prefix(2)).lowercased()
        process.arguments = ["-m", Self.model.path, "-f", wav.path, "-l", language, "-t", "4", "-otxt", "-of", output.path, "-np", "-nt"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate(); process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw NSError(domain: "AIEMedia", code: 6, userInfo: [NSLocalizedDescriptionKey: "本机转写分段超时，可从断点重试"])
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard process.terminationStatus == 0 else { throw NSError(domain: "AIEMedia", code: 7, userInfo: [NSLocalizedDescriptionKey: "Whisper 转写失败，请检查本机模型安装"] ) }
        return try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func convertToWAV(_ source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0, input.length <= AVAudioFramePosition(input.processingFormat.sampleRate * 60),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.length) * 16000 / input.processingFormat.sampleRate + 1024)) else { throw MediaBackendError.exportFailed }
        try input.read(into: sourceBuffer)
        var supplied = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return sourceBuffer
        }
        guard status != .error, converted.frameLength > 0 else { throw error ?? MediaBackendError.exportFailed as NSError }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: converted)
    }
}
