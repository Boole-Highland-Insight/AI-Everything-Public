import Foundation

/// Only processes launched by this app are terminated. An existing Ollama service is untouched.
enum OwnedModelProcesses {
    private static let lock = NSLock()
    private static var processes: [Process] = []
    private static var stopping = false

    static func run(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { throw CancellationError() }
        try process.run()
        processes.removeAll { !$0.isRunning }
        processes.append(process)
    }

    static func stop() {
        lock.lock()
        stopping = true
        let owned = processes
        processes.removeAll()
        lock.unlock()
        for process in owned where process.isRunning { process.terminate() }
    }
}
