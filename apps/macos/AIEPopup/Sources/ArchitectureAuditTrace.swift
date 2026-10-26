import Foundation
import Darwin

/// Opt-in, content-free diagnostics. No query, prompt, file path or credential is recorded.
enum ArchitectureAuditTrace {
    @TaskLocal static var traceID: String?
    private static let destination: String? = {
        guard let path = ProcessInfo.processInfo.environment["AIE_AUDIT_TRACE_PATH"],
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return nil }
        return path
    }()
    private static let writer = DispatchQueue(label: "aie.audit.trace")
    static var enabled: Bool { destination != nil }

    struct Span {
        let trace: String
        let name: String
        let start: Double
        let cpuStart: Double
        let mainAtStart: Bool
        let threadAtStart: UInt64

        func end(id: String? = nil, count: Int = 0, fields: [String: Any] = [:]) {
            let end = ProcessInfo.processInfo.systemUptime
            var row = fields
            row.merge([
                "trace_id": id ?? trace, "stage": name, "start_s": start, "end_s": end,
                "wall_ms": (end - start) * 1000, "count": count,
                "process_cpu_ms": (ArchitectureAuditTrace.cpuSeconds() - cpuStart) * 1000,
                "main_at_start": mainAtStart, "main_at_end": Thread.isMainThread,
                "thread_at_start": threadAtStart, "thread_at_end": ArchitectureAuditTrace.threadID(),
            ]) { _, new in new }
            ArchitectureAuditTrace.write(row)
        }
    }

    static func begin(_ name: String, id: String? = nil) -> Span? {
        guard enabled else { return nil }
        return Span(trace: id ?? traceID ?? UUID().uuidString, name: name,
                    start: ProcessInfo.processInfo.systemUptime, cpuStart: cpuSeconds(),
                    mainAtStart: Thread.isMainThread, threadAtStart: threadID())
    }

    static func event(_ name: String, id: String? = nil, count: Int = 0) {
        begin(name, id: id)?.end(count: count)
    }

    private static func threadID() -> UInt64 {
        var value: UInt64 = 0
        pthread_threadid_np(nil, &value)
        return value
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func write(_ row: [String: Any]) {
        guard let destination,
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        writer.async {
            let fd = Darwin.open(destination, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            let line = data + Data([10])
            line.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { _ = Darwin.write(fd, base, bytes.count) }
            }
        }
    }

    static func flush() { if enabled { writer.sync {} } }
}
