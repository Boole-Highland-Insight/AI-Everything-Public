import Foundation
import Speech

/// No permission prompts in the background and no network fallback.
public struct AppleSpeechEngine: LocalSpeechEngine {
    public let modelID = "apple-speech-on-device-v1"
    public init() {}
    /// Call only after an explicit user action, never while indexing a folder.
    public static func requestPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return status == .authorized
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    public func prepare(locale: String) async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw MediaBackendError.speechPermission }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw MediaBackendError.localSpeechUnavailable }
    }
    public func transcribe(audioURL: URL, locale: String) async throws -> String {
        try await prepare(locale: locale)
        let operation = RecognitionOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(url: audioURL, locale: locale, continuation: continuation)
            }
        } onCancel: { operation.cancel() }
    }
}

private final class RecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var finished = false
    private var timer: DispatchWorkItem?

    func start(url: URL, locale: String, continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { finish(.failure(MediaBackendError.localSpeechUnavailable)); return }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Recognition callbacks can arrive immediately; never hold our lock while starting the task.
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error { self?.finish(.failure(error)) }
            else if let result, result.isFinal { self?.finish(.success(result.bestTranscription.formattedString)) }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(NSError(domain: "AIEMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "此段本机转写超时，可以单独重试"])))
        }
        lock.lock()
        if finished { lock.unlock(); task.cancel(); return }
        self.recognizer = recognizer; self.task = task; timer = timeout
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        timer?.cancel(); timer = nil; recognizer = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
