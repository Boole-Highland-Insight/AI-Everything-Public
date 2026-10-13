import AIEData
import Darwin
import Foundation
import PDFKit

final class LibrarySearchStageRecorder {
    var metadataMilliseconds = 0.0
    var ftsMilliseconds = 0.0
    var evidenceMilliseconds = 0.0
    var fusionMilliseconds = 0.0
    var tieringMilliseconds = 0.0
    var totalMilliseconds = 0.0
}

/// The application's local data gateway. No socket listener, cloud access, or file mutation tools.
enum LibraryGateway {
    private static let resultLimit = 12
    private static let loadLock = NSLock()
    private static let stateLock = NSLock()
    private static var errorText: String?
    private static var selectedPaths: Set<String>?
    private static var hashes: [String: (stamp: String, hash: String)] = [:]
    private static var extracted: [String: [ContentBlock]] = [:]

    static var databaseURL: URL { AppDatabase.url }
    static var lastError: String? { stateLock.lock(); defer { stateLock.unlock() }; return errorText ?? AppDatabase.lastError }
    private static func setError(_ error: String?) { stateLock.lock(); errorText = error; stateLock.unlock() }
    static func selectRoots(_ roots: [URL]) {
        let paths = Set(roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        stateLock.lock(); selectedPaths = paths; stateLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            loadLock.lock(); defer { loadLock.unlock() }
            stateLock.lock(); let current = selectedPaths ?? []; stateLock.unlock()
            do { try store().restrictRoots(to: Array(current)) }
            catch { setError("本机数据库暂不可用，已使用文件索引") }
        }
    }
    private static func accepts(_ paths: [String]) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return selectedPaths.map { $0 == Set(paths) } ?? true
    }
    static func allowsScanning(_ file: IndexedFile) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return selectedPaths?.contains(file.rootPath) ?? true
    }
    static func store() throws -> ContentStore { try AppDatabase.open() }

    static func load(
        roots: [URL],
        catalogReady: (([IndexedFile]) -> Void)? = nil,
        indexProgress: ((Int, Int) -> Void)? = nil
    ) -> [IndexedFile] {
        loadLock.lock(); defer { loadLock.unlock() }
        let roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard accepts(roots.map(\.path)) else { return [] }
        var files = LibraryIndex.load(roots: roots)
        catalogReady?(files)
        do {
            let database = try store()
            let excludedPhotos = try database.excludedPhotoPaths(rootPath: PhotoImport.directory.path)
            files.removeAll { excludedPhotos.contains($0.path) }
            for root in roots { try LegacyImport.run(root: root, database: database) }
            var documents: [SourceDocument] = []
            var analyses: [String: [String: Any]] = [:]
            var staged: [SourceDocument] = []
            var stagedBlocks = 0
            indexProgress?(0, files.count)

            func flushStage() throws {
                guard !staged.isEmpty else { return }
                guard accepts(roots.map(\.path)) else { throw CancellationError() }
                try database.stage(documents: staged, rootPaths: roots.map(\.path))
                staged.removeAll(keepingCapacity: true)
                stagedBlocks = 0
                indexProgress?(documents.count, files.count)
            }

            for file in files {
                let url = URL(fileURLWithPath: file.path)
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                let stamp = "\(file.size):\(file.mtime.timeIntervalSince1970):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(attrs[.creationDate] ?? "")"
                let identity = "\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? ""):\(attrs[.creationDate] ?? file.path)"
                let fileID = ContentIdentity.digest(file.rootPath + ":" + identity)
                let hash: String
                if let cached = hashes[file.path], cached.stamp == stamp { hash = cached.hash }
                else { hash = try ContentIdentity.hashFile(url); hashes[file.path] = (stamp, hash) }
                var source = SourceDocument(id: fileID, rootPath: file.rootPath, path: file.path, relativePath: ScanRecords.relative(for: file),
                                            kind: file.kind.rawValue, ext: file.ext, contentHash: hash, size: Int64(file.size),
                                            modifiedAt: file.mtime.timeIntervalSince1970,
                                            blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: file.name)])
                try database.ensureAnalysis(root: file.rootPath, relative: source.relativePath, fileID: fileID) { [:] }
                var record = try database.analysis(root: file.rootPath, relative: source.relativePath) ?? [:]
                // Stamp legacy analyses once, while their original metadata still matches. Future local
                // scans cannot silently make an old cloud summary look current by updating size/mtime.
                if SidecarProjection.metadataMatches(record, source: source) {
                    let wrote = ScanRecords.mutate(file) { disk in
                        var changed = false
                        if var local = disk["localScan"] as? [String: Any], local["sourceHash"] == nil {
                            local["sourceHash"] = hash; disk["localScan"] = local; changed = true
                        }
                        if var quick = disk["quickScan"] as? [String: Any] {
                            var parse = quick["parse"] as? [String: Any] ?? [:]
                            if parse["sourceHash"] == nil { parse["sourceHash"] = hash; quick["parse"] = parse; disk["quickScan"] = quick; changed = true }
                        }
                        return changed
                    }
                    if wrote { record = ScanRecords.read(file) ?? [:] }
                }
                if let cached = extracted[source.versionID] { source.blocks += cached }
                else {
                    let blocks = if file.ext == "pdf",
                                    let cached = try database.cachedSourceBlocks(
                                        versionID: source.versionID, parserVersion: "pdfkit-1"
                                    ) {
                        cached
                    } else {
                        sourceBlocks(file: file)
                    }
                    source.blocks += blocks
                    extracted[source.versionID] = blocks
                }
                source = SidecarProjection.apply(record, to: source)
                if !staged.isEmpty,
                   staged.count >= 16 || stagedBlocks + source.blocks.count > 512 {
                    try flushStage()
                }
                documents.append(source)
                staged.append(source)
                stagedBlocks += source.blocks.count
                analyses[file.path] = record
                if stagedBlocks >= 512 { try flushStage() }
            }
            try flushStage()
            guard accepts(roots.map(\.path)) else { return [] }
            try database.publishSnapshot(
                documentIDs: documents.map(\.id), rootPaths: roots.map(\.path)
            )
            let byPath = Dictionary(uniqueKeysWithValues: documents.map { ($0.path, $0) })
            for document in documents {
                if let provenance = analyses[document.path]?["provenance"] as? [String: Any],
                   let sourceVersion = provenance["sourceVersionID"] as? String {
                    do { try database.linkArtifact(sourceVersionID: sourceVersion, artifactFileID: document.id, relation: "reuse", rootPaths: roots.map(\.path)) }
                    catch DataLayerError.unauthorizedRoot { /* Source not selected or provenance imported from another installation. */ }
                }
            }
            let blocks = try database.chunks(rootPaths: roots.map(\.path))
            let grouped = Dictionary(grouping: blocks, by: \.path)
            let entityNames = try database.entityNames(rootPaths: roots.map(\.path))
            for index in files.indices {
                let path = files[index].path
                let evidence = (grouped[path] ?? []).map {
                    IndexedChunk(id: $0.id, versionID: $0.versionID, page: $0.page, text: $0.text, tags: $0.tags,
                                 summary: $0.summary, kind: $0.kind, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, locationJSON: $0.locationJSON)
                }
                files[index].fileID = byPath[path]?.id
                files[index].versionID = byPath[path]?.versionID
                files[index].contentHash = byPath[path]?.contentHash
                LibraryIndex.applyAnalysis(analyses[path] ?? [:], to: &files[index])
                files[index].entityNames = entityNames[path] ?? files[index].entityNames
                files[index].chunks = evidence
                files[index].fileSummary = byPath[path]?.fileSummary ?? ""
                files[index].summaryIssue = byPath[path]?.stages.first { $0.stage == "summary_quality" }?.error
                files[index].contentIssue = byPath[path]?.stages.first { $0.stage == "content_quality" }?.error
                // Search uses current-version chunks, not historical scan text.
                let body = evidence.map { [$0.text, $0.summary, $0.tags.joined(separator: " ")].joined(separator: "\n") }.joined(separator: "\n")
                files[index].haystack = "\(files[index].name)\n\(files[index].relative)\n\(files[index].kind.rawValue)\n\(files[index].ext)\n\(body)".lowercased()
                files[index].haystack += "\n" + LibraryIndex.zhAliases(in: files[index].haystack)
                files[index].preview = byPath[path]?.fileSummary.isEmpty == false ? byPath[path]!.fileSummary : body
                files[index].llmLine = String("\(files[index].relative) · \(files[index].preview)".prefix(260))
                files[index].llmCard = String("\(files[index].relative) · \(files[index].preview)".prefix(600))
            }
            hashes = hashes.filter { byPath[$0.key] != nil }
            let liveVersions = Set(documents.map(\.versionID))
            extracted = extracted.filter { liveVersions.contains($0.key) }
            setError(nil)
        } catch is CancellationError {
            return []
        } catch {
            setError("本机数据库暂不可用，已使用文件索引")
            AppLog.write("data-layer: \(error)")
        }
        return files
    }

    static func search(
        query: String, in files: [IndexedFile], semantic: [ChunkResult] = [],
        limit: Int = resultLimit, recorder: LibrarySearchStageRecorder? = nil
    ) -> [FileHit] {
        let totalStarted = ProcessInfo.processInfo.systemUptime
        defer {
            recorder?.totalMilliseconds =
                (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
        }
        let metadataStarted = ProcessInfo.processInfo.systemUptime
        let compiled = LibraryIndex.compile(query)
        let filtered = files.filter { file in
            (compiled.kinds == nil || compiled.kinds!.contains(file.kind)) && (compiled.ext == nil || compiled.ext == file.ext)
        }
        let hasDatabaseProjection = files.contains(where: { $0.versionID != nil })
        recorder?.metadataMilliseconds =
            (ProcessInfo.processInfo.systemUptime - metadataStarted) * 1_000
        guard hasDatabaseProjection, !compiled.tokens.isEmpty || !compiled.anyOf.isEmpty else {
            let local = LibraryIndex.search(query: query, in: filtered, limit: max(filtered.count, 40))
            return Array(local.prefix(limit).map { hit in
                var hit = hit
                let identifier = compiled.numericTerms.contains {
                    NumericSearch.contains($0, in: filtered.first(where: { $0.path == hit.path })?.haystack ?? "")
                }
                if hit.reason == "文件名" || identifier {
                    hit.confidenceTier = .direct
                    let source: SearchEvidenceSource = identifier ? .identifier : .filename
                    hit.evidence = [.init(source: source, strength: 1, chunkID: hit.chunkID, page: hit.page)]
                }
                return hit
            })
        }
        // Projected files are already represented in FTS5. Scanning their complete in-memory
        // haystacks first made broad alias queries proportional to total library text size.
        // Keep this path only for a file that has not reached the database projection yet.
        let unprojected = filtered.filter { $0.versionID == nil }
        let local = LibraryIndex.search(query: query, in: unprojected, limit: max(unprojected.count, 40))
        do {
            let roots = Array(Set(filtered.map(\.rootPath)))
            let ftsStarted = ProcessInfo.processInfo.systemUptime
            let strict = try store().search(allTerms: compiled.tokens.map(LibraryIndex.aliases), anyTerms: compiled.anyOf, rootPaths: roots)
            recorder?.ftsMilliseconds =
                (ProcessInfo.processInfo.systemUptime - ftsStarted) * 1_000
            let evidenceStarted = ProcessInfo.processInfo.systemUptime
            let byPath = Dictionary(uniqueKeysWithValues: filtered.map { ($0.path, $0) })
            var lexicalPaths: [String] = [], semanticPaths: [String] = []
            var lexicalSeen = Set<String>(), semanticSeen = Set<String>()
            var evidence: [String: [String: (chunk: ChunkResult, cosine: Double)]] = [:]
            for chunk in strict {
                guard let file = byPath[chunk.path], file.versionID == chunk.versionID else { continue }
                if lexicalSeen.insert(chunk.path).inserted { lexicalPaths.append(chunk.path) }
                evidence[chunk.path, default: [:]][chunk.id] = (chunk, 0)
            }
            for chunk in semantic {
                guard let file = byPath[chunk.path], file.versionID == chunk.versionID else { continue }
                guard compiled.numericTerms.allSatisfy({ NumericSearch.contains($0, in: file.haystack) }) else { continue }
                // A named drawing medium needs supporting content, not merely a
                // weak vector association with hands, art or decoration.
                let drawingTerms = ["手绘", "素描", "速写", "铅笔画", "线稿"]
                if compiled.tokens.contains(where: { drawingTerms.contains($0) }) {
                    let support = ([file.name, file.fileSummary] + file.chunks.map { ($0.tags + [$0.text, $0.summary]).joined(separator: " ") }).joined(separator: " ")
                    guard drawingTerms.contains(where: { term in
                        LibraryIndex.aliases(of: term).contains { support.localizedCaseInsensitiveContains($0) }
                    }) else { continue }
                }
                if semanticSeen.insert(chunk.path).inserted { semanticPaths.append(chunk.path) }
                evidence[chunk.path, default: [:]][chunk.id] = (chunk, chunk.score)
            }
            var hits = Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) })
            var strengths: [String: Int] = [:]
            var numericStrengths: [String: Int] = [:]
            for file in filtered where hits[file.path] != nil || evidence[file.path] != nil {
                let candidates = Array(evidence[file.path, default: [:]].values)
                let chosen = candidates.map { (value: $0, priority: EvidencePolicy.priority($0.chunk, cosine: $0.cosine, query: compiled)) }.sorted {
                    if $0.priority != $1.priority { return $0.priority > $1.priority }
                    return $0.value.chunk.id < $1.value.chunk.id
                }.first?.value
                numericStrengths[file.path] = compiled.numericTerms.map { NumericSearch.strength($0, in: file.haystack) }.min() ?? 0
                let nameMatch = EvidencePolicy.coverage(file.name, query: compiled) >= 1
                let bodyScores = file.chunks.filter { $0.kind != "document" }.map {
                    (chunk: $0, coverage: EvidencePolicy.coverage(($0.tags + [$0.text]).joined(separator: " "), query: compiled))
                }
                let bodyMatch = bodyScores.filter { !EvidencePolicy.isModelDerived($0.chunk.kind) }
                    .map(\.coverage).max() ?? 0
                let inferredMatch = bodyScores.filter { EvidencePolicy.isModelDerived($0.chunk.kind) }
                    .map(\.coverage).max() ?? 0
                let semanticMatch = candidates.map(\.cosine).max() ?? 0
                let summaryMatch = max(EvidencePolicy.coverage(file.fileSummary, query: compiled), inferredMatch)
                // Only complete concept matches or credible semantic matches precede partial keyword hits.
                strengths[file.path] = nameMatch ? 4 : (bodyMatch >= 1 ? 3 : (semanticMatch >= 0.52 ? 2 : (summaryMatch >= 1 ? 1 : 0)))
                if let chosen {
                    hits[file.path] = evidenceHit(file: file, chunk: chosen.chunk, query: query, reason: nameMatch ? "文件名" : (chosen.cosine > 0 ? "语义" : "全文"))
                }
                if let existing = hits[file.path], existing.chunkID == nil || chosen?.chunk.kind == "document" {
                    // A summary/root match may nominate the file, but display relevant source evidence when available.
                    let bestBody = bodyScores.filter { !$0.chunk.text.isEmpty }.sorted {
                        $0.coverage > $1.coverage
                    }.first
                    if let bestBody, bestBody.coverage > 0 {
                        let body = bestBody.chunk
                        hits[file.path] = EvidencePolicy.hit(file: file, chunk: body, query: query, reason: existing.reason)
                    } else if chosen == nil { hits[file.path] = EvidencePolicy.fallback(file: file, original: existing) }
                }
            }
            recorder?.evidenceMilliseconds =
                (ProcessInfo.processInfo.systemUptime - evidenceStarted) * 1_000
            let fusionStarted = ProcessInfo.processInfo.systemUptime
            let fused = RankFusion.fuse(
                [local.map(\.path), lexicalPaths, semanticPaths],
                limit: max(hits.count, 40)
            )
            let rank = Dictionary(uniqueKeysWithValues: fused.enumerated().map { ($1, $0) })
            let ordered = hits.keys.sorted {
                if numericStrengths[$0, default: 0] != numericStrengths[$1, default: 0] { return numericStrengths[$0, default: 0] > numericStrengths[$1, default: 0] }
                if strengths[$0, default: 0] != strengths[$1, default: 0] { return strengths[$0, default: 0] > strengths[$1, default: 0] }
                return rank[$0, default: Int.max] < rank[$1, default: Int.max]
            }
            recorder?.fusionMilliseconds =
                (ProcessInfo.processInfo.systemUptime - fusionStarted) * 1_000
            let tieringStarted = ProcessInfo.processInfo.systemUptime
            let result = Array(ordered.compactMap { path -> FileHit? in
                guard var hit = hits[path] else { return nil }
                let strength = strengths[path, default: 0]
                let numeric = numericStrengths[path, default: 0]
                var sources = Set<SearchEvidenceSource>()
                if numeric > 0 { sources.insert(.identifier) }
                if strength >= 4 { sources.insert(.filename) }
                else if strength == 3 {
                    let kind = byPath[path]?.chunks.first(where: { $0.id == hit.chunkID })?.kind ?? ""
                    if kind.contains("ocr") { sources.insert(.ocr) }
                    else if kind.contains("transcript") || kind.contains("audio") { sources.insert(.transcript) }
                    else { sources.insert(.body) }
                } else if strength == 2 { sources.insert(.semantic) }
                else if strength == 1 { sources.insert(.summary) }
                if sources.isEmpty { sources.insert(hit.reason == "路径" ? .path : .summary) }
                hit.confidenceTier = (strength >= 3 || numeric > 0) ? .direct : .possible
                hit.evidence = sources.map {
                    SearchEvidence(
                        source: $0, strength: strength > 0 ? Double(strength) / 4 : 0.25,
                        chunkID: hit.chunkID, page: hit.page,
                        startSeconds: hit.startSeconds, endSeconds: hit.endSeconds
                    )
                }.sorted { $0.source.rawValue < $1.source.rawValue }
                return hit
            }.prefix(limit))
            recorder?.tieringMilliseconds =
                (ProcessInfo.processInfo.systemUptime - tieringStarted) * 1_000
            return result
        } catch {
            setError("本机数据库暂不可用，已使用文件索引")
            return Array(LibraryIndex.search(query: query, in: filtered, limit: limit).prefix(limit))
        }
    }

    /// Structured search boundary used by the UI and new retrieval stages. `search` remains as
    /// a compatibility adapter for diagnostics while callers migrate away from bare FileHit arrays.
    static func searchCandidates(query: String, in files: [IndexedFile],
                                 semantic: [ChunkResult] = []) -> [SearchCandidate] {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        return search(query: query, in: files, semantic: semantic).compactMap { hit in
            guard let file = byPath[hit.path] else { return nil }
            return SearchCandidate(
                hit: hit, tier: hit.confidenceTier, evidence: hit.evidence,
                fileID: file.fileID, versionID: file.versionID, contentHash: file.contentHash
            )
        }
    }

    /// Broader text evidence is independently available even when no vector passed its threshold.
    /// This list is sent to the local verifier, never displayed as a confirmed search result.
    static func fallbackCandidates(query: String, in files: [IndexedFile], semantic: [ChunkResult],
                                   expandedTerms: [String] = [], limit: Int = 12) -> [FileHit] {
        let compiled = LibraryIndex.compile(query)
        let filtered = files.filter { file in
            (compiled.kinds == nil || compiled.kinds!.contains(file.kind)) && (compiled.ext == nil || compiled.ext == file.ext)
                && compiled.numericTerms.allSatisfy { NumericSearch.contains($0, in: file.haystack) }
        }
        let byPath = Dictionary(uniqueKeysWithValues: filtered.map { ($0.path, $0) })
        let terms = compiled.tokens.flatMap(LibraryIndex.aliases) + compiled.anyOf + expandedTerms
        var textHits: [FileHit] = [], seen = Set<String>()
        do {
            let chunks = try store().search(allTerms: [], anyTerms: terms, rootPaths: Array(Set(filtered.map(\.rootPath))))
            let evidenceQuery = LibraryIndex.compile(([query] + expandedTerms).joined(separator: " "))
            let ordered = chunks.enumerated().sorted {
                let left = EvidencePolicy.priority($0.element, cosine: 0, query: evidenceQuery)
                let right = EvidencePolicy.priority($1.element, cosine: 0, query: evidenceQuery)
                return left == right ? $0.offset < $1.offset : left > right
            }
            for (_, chunk) in ordered {
                guard let file = byPath[chunk.path], file.versionID == chunk.versionID, seen.insert(file.path).inserted else { continue }
                textHits.append(evidenceHit(file: file, chunk: chunk, query: ([query] + expandedTerms).joined(separator: " "), reason: "原文候选"))
            }
        } catch { AppLog.write("fallback text retrieval unavailable: \(error)") }
        let vectorHits = search(query: query, in: filtered, semantic: semantic)
        let all = Dictionary((textHits + vectorHits).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return RankFusion.fuse([textHits.map(\.path), vectorHits.map(\.path)], limit: limit).compactMap { all[$0] }
    }

    private static func evidenceHit(file: IndexedFile, chunk: ChunkResult, query: String, reason: String) -> FileHit {
        let indexed = IndexedChunk(id: chunk.id, versionID: chunk.versionID, page: chunk.page, text: chunk.text, tags: chunk.tags,
                                   summary: chunk.summary, kind: chunk.kind, startSeconds: chunk.startSeconds, endSeconds: chunk.endSeconds, locationJSON: chunk.locationJSON)
        return EvidencePolicy.hit(file: file, chunk: indexed, query: query, reason: reason)
    }

    static func evidence(chunkID: String, roots: [URL]) throws -> ChunkResult? {
        try store().chunk(id: chunkID, rootPaths: roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
    }

    static func recordArtifact(source: IndexedFile, path: String) {
        guard let versionID = source.versionID, path.hasPrefix(source.rootPath + "/") else { return }
        let relative = String(path.dropFirst(source.rootPath.count + 1))
        ScanRecords.mutate(root: URL(fileURLWithPath: source.rootPath), relative: relative) { record in
            record["provenance"] = ["sourceFileID": source.fileID ?? "", "sourceVersionID": versionID,
                                    "sourceContentHash": source.contentHash ?? "",
                                    "sourceRelative": ScanRecords.relative(for: source), "relation": "reuse"]
            return true
        }
    }

    private static func sourceBlocks(file: IndexedFile) -> [ContentBlock] {
        let url = URL(fileURLWithPath: file.path)
        if ["txt","md","csv","tsv","json"].contains(file.ext) {
            guard let data = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? data.close() }
            let bytes = (try? data.read(upToCount: 4 * 1024 * 1024)) ?? Data()
            let text = String(data: bytes, encoding: .utf8) ?? ""
            return SidecarProjection.textBlocks(text, kind: file.ext == "csv" || file.ext == "tsv" ? "table_text" : "paragraph")
        }
        if StructuredFileReader.extensions.contains(file.ext) { return StructuredFileReader.read(path: file.path)?.blocks ?? [] }
        if file.ext == "xlsx" { return SpreadsheetReader.read(path: file.path)?.blocks ?? [] }
        if file.ext == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<min(pdf.pageCount, 500)).flatMap { index -> [ContentBlock] in
                guard let text = pdf.page(at: index)?.string, !text.isEmpty else { return [] }
                return StructuralChunker.page(String(text.prefix(32000)), key: "pdf-\(index + 1)", kind: "page", page: index + 1, parserVersion: "pdfkit-1")
            }
        }
        if file.ext == "docx", let bytes = ArchiveEntryReader.data(path: file.path, member: "word/document.xml"), let xml = String(data: bytes, encoding: .utf8) {
            let text = xml.replacingOccurrences(of: "</w:p>", with: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return SidecarProjection.textBlocks(String(text.prefix(2_000_000)), parserKind: "docx")
        }
        return []
    }
}

private extension SidecarProjection {
    static func textBlocks(_ text: String, parserKind: String) -> [ContentBlock] {
        textBlocks(text).map { block in var block = block; block.parserVersion = parserKind + "-1"; return block }
    }
}
