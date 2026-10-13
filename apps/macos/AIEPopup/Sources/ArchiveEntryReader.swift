import Foundation

enum ArchiveEntryReader {
    /// Drain stdout while unzip is running. Waiting first deadlocks once the pipe fills.
    static func data(path: String, member: String, maxBytes: Int? = nil) -> Data? {
        run(arguments: ["-p", path, member], maxBytes: maxBytes)
    }

    static func members(path: String) -> [String]? {
        guard let data = run(arguments: ["-Z1", path]),
              let names = String(data: data, encoding: .utf8) else { return nil }
        return names.split(separator: "\n").map(String.init)
    }

    private static func run(arguments: [String], maxBytes: Int? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        var exceeded = false
        while let chunk = try? output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if !exceeded, let maximum = maxBytes, data.count + chunk.count > maximum {
                exceeded = true
                process.terminate()
            }
            if !exceeded { data.append(chunk) }
        }
        process.waitUntilExit()
        guard !exceeded, process.terminationStatus == 0 else { return nil }
        return data
    }
}
