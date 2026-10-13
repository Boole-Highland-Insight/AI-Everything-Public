import Foundation
import AIEData

/// Explicit maintenance and offline fixture checks; never starts scanners or reads API credentials.
enum StorageDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let command = args.dropFirst().first,
              ["--backup-database", "--compact-database", "--verify-storage"].contains(command) else { return false }
        do {
            guard args.count == 3, args[2].hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
            if command == "--backup-database" {
                try AppDatabase.open().backup(to: args[2])
                print("Database backup completed.")
            } else if command == "--compact-database" {
                try AppDatabase.open().compactCopy(to: args[2])
                print("Compacted database copy completed and verified.")
            } else {
                let env = ProcessInfo.processInfo.environment
                guard let dbPath = env["AIE_DATABASE_PATH"], dbPath.hasPrefix("/"), let trashPath = env["AIE_TRASH_PATH"], trashPath.hasPrefix("/") else { throw CocoaError(.fileWriteNoPermission) }
                let root = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
                let fm = FileManager.default
                guard try fm.contentsOfDirectory(atPath: root.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
                func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
                    guard try value() else { throw NSError(domain: "StorageChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage invariant failed at line \(line)"]) }
                }
                let original = root.appendingPathComponent("fixture.md")
                try "# 第一节\n需要保留的原文".write(to: original, atomically: true, encoding: .utf8)
                let files = LibraryGateway.load(roots: [root])
                try check(LibraryGateway.lastError == nil && files.count == 1)
                try check(ScanRecords.mutate(files[0]) { $0["cloudUpload"] = ["uploadedAt": "fixture"]; $0["provenance"] = ["sourceVersionID": "fixture"]; return true })
                ReuseFeedback.begin(files[0])
                try check((ScanRecords.read(files[0])?["reuseFeedback"] as? [String: Any])?["sessionActive"] as? Bool == true)
                ReuseFeedback.markResolved(files[0], resultPath: root.appendingPathComponent("fixture 补全.md").path)
                let completedFeedback = ScanRecords.read(files[0])?["reuseFeedback"] as? [String: Any]
                try check(completedFeedback?["resolved"] as? Bool == true)
                try check(completedFeedback?["currentResultPath"] as? String == root.appendingPathComponent("fixture 补全.md").path)
                ReuseFeedback.close(files[0])
                try check((ScanRecords.read(files[0])?["reuseFeedback"] as? [String: Any])?["sessionActive"] as? Bool == false)
                let db = try AppDatabase.open()
                let identity = try db.analysisIdentity(root: root.path, relative: "fixture.md")
                try check(TrashBin.ingest(paths: [original.path], files: files, roots: [root]) == [original.path])
                try check(!fm.fileExists(atPath: original.path))
                let trash = TrashBin.load()
                try check(trash.count == 1)
                try check(try String(contentsOfFile: trash[0].storedPath, encoding: .utf8).contains("原文"))
                try "新文件不能覆盖".write(to: original, atomically: true, encoding: .utf8)
                // Create a new analysis at the previous path while the original is in the trash.
                try db.ensureAnalysis(root: root.path, relative: "fixture.md") { ["new": true] }
                TrashBin.restore(ids: [trash[0].id], roots: [root])
                let restored = root.appendingPathComponent("fixture 还原1.md")
                try check(fm.fileExists(atPath: restored.path) && TrashBin.load().isEmpty)
                try check(try String(contentsOf: original, encoding: .utf8) == "新文件不能覆盖")
                try check(try db.analysisIdentity(root: root.path, relative: restored.lastPathComponent) == identity)
                try check(try db.analysis(root: root.path, relative: restored.lastPathComponent)?["cloudUpload"] != nil)
                let metadataFiles = LibraryIndex.load(roots: [root])
                try check(TrashBin.ingest(paths: [restored.path], files: metadataFiles, roots: [root]) == [restored.path])
                let second = TrashBin.load()
                try check(second.count == 1)
                TrashBin.purge(ids: second.map(\.id))
                try check(TrashBin.load().isEmpty && !fm.fileExists(atPath: second[0].storedPath))
                try check(!fm.fileExists(atPath: root.appendingPathComponent("scanner").path))
                try check(!fm.fileExists(atPath: URL(fileURLWithPath: trashPath).appendingPathComponent("manifest.json").path))
                try check(AppDatabase.lastError == nil)
                // A separate fixture exercises the old manifest importer and interrupted move recovery.
                let legacyRoot = URL(fileURLWithPath: trashPath).deletingLastPathComponent().appendingPathComponent("legacy-trash")
                setenv("AIE_TRASH_PATH", legacyRoot.path, 1)
                let legacyID = UUID().uuidString
                let archive = legacyRoot.appendingPathComponent("files/" + legacyID)
                try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                let oldStored = archive.appendingPathComponent("old.md")
                try "旧垃圾桶文件".write(to: oldStored, atomically: true, encoding: .utf8)
                let legacyAnalysis = try JSONSerialization.data(withJSONObject: ["cloudUpload": ["uploadedAt": "old-fixture"]])
                try legacyAnalysis.write(to: archive.appendingPathComponent("sidecar.json"))
                let manifest = try JSONSerialization.data(withJSONObject: [["id": legacyID, "originalPath": root.appendingPathComponent("old.md").path,
                    "name": "old.md", "relative": "old.md", "kind": "document", "ext": "md", "storedName": "old.md",
                    "trashedAt": ISO8601DateFormatter().string(from: Date())]])
                try manifest.write(to: legacyRoot.appendingPathComponent("manifest.json"))
                try check(TrashBin.load().count == 1)
                TrashBin.restore(ids: [legacyID], roots: [root])
                try check(TrashBin.load().isEmpty)
                try check(try db.analysis(root: root.path, relative: "old.md")?["cloudUpload"] != nil)
                try check(try Data(contentsOf: archive.appendingPathComponent("sidecar.json")) == legacyAnalysis)
                try check(try Data(contentsOf: legacyRoot.appendingPathComponent("manifest.json")) == manifest)
                let interruptedID = UUID().uuidString
                let interruptedDir = legacyRoot.appendingPathComponent("files/" + interruptedID)
                try fm.createDirectory(at: interruptedDir, withIntermediateDirectories: true)
                let interruptedSource = root.appendingPathComponent("old.md"), interruptedStored = interruptedDir.appendingPathComponent("old.md")
                let interrupted = StoredTrash(id: interruptedID, originalPath: interruptedSource.path, rootPath: root.path, relativePath: "old.md",
                    name: "old.md", kind: "document", ext: "md", trashedAt: Date().timeIntervalSince1970, storedPath: interruptedStored.path,
                    analysisID: try db.analysisIdentity(root: root.path, relative: "old.md"), state: "moving", contentHash: try ContentIdentity.hashFile(interruptedSource))
                try db.saveTrash(interrupted)
                try fm.moveItem(at: interruptedSource, to: interruptedStored)
                try check(TrashBin.load().count == 1)
                try check(try db.trashRecords().first?.state == "trashed")
                TrashBin.restore(ids: [interruptedID], roots: [root])
                try check(fm.fileExists(atPath: interruptedSource.path) && TrashBin.load().isEmpty)
                try check(AppDatabase.lastError == nil)
                print("Storage checks passed: SQLite writes, durable reuse sessions, trash move/restore/purge, collision safety, analysis identity, cloud/provenance preservation, no runtime JSON output, legacy trash import, interrupted move recovery.")
            }
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        return true
    }
}
