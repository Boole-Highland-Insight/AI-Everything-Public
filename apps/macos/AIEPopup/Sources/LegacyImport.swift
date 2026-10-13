import Foundation
import AIEData

/// The only reader of old scanner JSON. Source files are retained unchanged as migration backups.
enum LegacyImport {
    static func run(root: URL, database: ContentStore) throws {
        let marker = "legacy-root:" + root.path
        guard try !database.hasImported(marker) else { return }
        let directory = root.appendingPathComponent("scanner")
        if FileManager.default.fileExists(atPath: directory.path) {
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            var enumerationError: Error?
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let candidate as URL in files where candidate.pathExtension == "json" {
                let file = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
                let relative = String(file.path.dropFirst(directory.path.count + 1).dropLast(5))
                try database.ensureAnalysis(root: root.path, relative: relative) {
                    guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                    return record
                }
            }
            if let enumerationError { throw enumerationError }
        }
        try database.markImported(marker)
    }
}
