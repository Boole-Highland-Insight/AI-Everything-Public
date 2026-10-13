import Foundation
import AIEData

/// Read-only latency baseline for the currently selected database and authorized root.
enum VectorIndexDiagnostics {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--benchmark-vector-index" else { return false }
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[2].hasPrefix("/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
                .standardizedFileURL.resolvingSymlinksInPath().path
            let result = try AppDatabase.open().benchmarkVectorIndex(rootPaths: [root])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
        return true
    }
}
