import Foundation

@main struct ArchitectureAuditTraceChecks {
    static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIE_AUDIT_TRACE_PATH"] else {
            precondition(!ArchitectureAuditTrace.enabled)
            precondition(ArchitectureAuditTrace.begin("disabled") == nil)
            print("Audit tracing disabled by default")
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await ArchitectureAuditTrace.$traceID.withValue("test-\(index)") {
                        let span = ArchitectureAuditTrace.begin("parallel_stage")
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        span?.end(count: index)
                    }
                }
            }
        }
        ArchitectureAuditTrace.flush()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 8)
        var ids = Set<String>()
        for line in lines {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            ids.insert(row["trace_id"] as! String)
            precondition((row["end_s"] as! Double) >= (row["start_s"] as! Double))
            precondition((row["wall_ms"] as! Double) >= 0)
            precondition(row["thread_at_start"] != nil && row["thread_at_end"] != nil)
            precondition(row["query"] == nil && row["prompt"] == nil && row["path"] == nil)
        }
        precondition(ids.count == 8)
        print("Audit trace checks passed: opt-in, parallel trace isolation, monotonic timestamps, no content fields")
    }
}
