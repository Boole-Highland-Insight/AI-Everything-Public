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
    private static let resultLimit = 30
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
            let indexedFiles = Dictionary(grouping: try database.indexedFileMetadata(rootPaths: roots.map(\.path)), by: \.path)
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
                let hash: String
                if let cached = hashes[file.path], cached.stamp == stamp { hash = cached.hash }
                else { hash = try ContentIdentity.hashFile(url); hashes[file.path] = (stamp, hash) }
                let matchingIDs = Set((indexedFiles[file.path] ?? []).filter {
                    $0.rootPath == file.rootPath && $0.contentHash == hash
                }.map(\.fileID))
                guard matchingIDs.count <= 1 else {
                    throw DataLayerError.invalidDocument("Ambiguous file identity: " + file.path)
                }
                let fileID = matchingIDs.first ?? ContentIdentity.digest(file.rootPath + ":" + identity)
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
                                        versionID: source.versionID, parserVersion: "pdfkit-visual-2"
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
            let grouped = Dictionary(grouping: blocks.filter { !EvidencePolicy.isModelDerived($0.kind) }, by: \.path)
            for index in files.indices {
                let path = files[index].path
                let evidence = (grouped[path] ?? []).map {
                    IndexedChunk(id: $0.id, versionID: $0.versionID, page: $0.page, text: $0.text,
                                 tags: $0.kind == "document" ? [] : $0.tags,
                                 summary: $0.kind == "document" ? "" : $0.summary, kind: $0.kind,
                                 startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, locationJSON: $0.locationJSON)
                }
                files[index].fileID = byPath[path]?.id
                files[index].versionID = byPath[path]?.versionID
                files[index].contentHash = byPath[path]?.contentHash
                LibraryIndex.applyAnalysis(analyses[path] ?? [:], to: &files[index])
                files[index].entityNames = []
                files[index].chunks = evidence
                files[index].fileSummary = ""
                files[index].browseSummary = byPath[path]?.fileSummary ?? ""
                files[index].summaryIssue = nil
                files[index].contentIssue = byPath[path]?.stages.first { $0.stage == "content_quality" }?.error
                // Search uses current-version chunks, not historical scan text.
                let body = evidence.filter { $0.kind != "document" }.map(\.text).joined(separator: "\n")
                files[index].haystack = "\(files[index].name)\n\(files[index].relative)\n\(files[index].kind.rawValue)\n\(files[index].ext)\n\(body)".lowercased()
                files[index].haystack += "\n" + LibraryIndex.zhAliases(in: files[index].haystack)
                files[index].preview = body
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

    /// Evaluation snapshot from the existing index; never enters the scanner or publishes a snapshot.
    static func loadIndexedSnapshot(roots: [URL]) throws -> [IndexedFile] {
        let database = try AppDatabase.open(readOnly: true)
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        let excludedPhotos = try database.excludedPhotoPaths(rootPath: PhotoImport.directory.path)
        let metadata = try database.indexedFileMetadata(rootPaths: rootPaths)
            .filter { !excludedPhotos.contains($0.path) }
        let blocks = try database.chunks(rootPaths: rootPaths)
        let grouped = Dictionary(grouping: blocks.filter { !EvidencePolicy.isModelDerived($0.kind) }, by: \.path)
        return try metadata.map { item in
            let relative = roots.count > 1
                ? URL(fileURLWithPath: item.rootPath).lastPathComponent + "/" + item.relativePath
                : item.relativePath
            var file = IndexedFile(path: item.path, name: URL(fileURLWithPath: item.path).lastPathComponent,
                relative: relative, kind: FileKind(rawValue: item.kind) ?? .other, ext: item.ext,
                mtime: Date(timeIntervalSince1970: item.modifiedAt), haystack: "", preview: "",
                thumbPath: item.path, rootPath: item.rootPath, size: Int(item.size),
                hasBarcode: false, isScreenshot: false, llmLine: "", llmCard: "", uploadedToCloud: false)
            file.fileID = item.fileID
            file.versionID = item.versionID
            file.contentHash = item.contentHash
            LibraryIndex.applyAnalysis(try database.analysis(root: item.rootPath, relative: item.relativePath) ?? [:], to: &file)
            file.entityNames = []
            file.fileSummary = ""
            file.summaryIssue = nil
            file.chunks = (grouped[item.path] ?? []).map {
                IndexedChunk(id: $0.id, versionID: $0.versionID, page: $0.page, text: $0.text,
                    tags: $0.kind == "document" ? [] : $0.tags,
                    summary: $0.kind == "document" ? "" : $0.summary, kind: $0.kind,
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, locationJSON: $0.locationJSON)
            }
            let body = file.chunks.filter { $0.kind != "document" }.map(\.text).joined(separator: "\n")
            file.haystack = "\(file.name)\n\(file.relative)\n\(file.kind.rawValue)\n\(file.ext)\n\(body)".lowercased()
            file.haystack += "\n" + LibraryIndex.zhAliases(in: file.haystack)
            file.preview = body
            file.llmLine = String("\(file.relative) · \(file.preview)".prefix(260))
            file.llmCard = String("\(file.relative) · \(file.preview)".prefix(600))
            return file
        }
    }

    static func search(
        query: String, in files: [IndexedFile], semantic: [ChunkResult] = [],
        limit: Int = resultLimit, recorder: LibrarySearchStageRecorder? = nil,
        reuseEvidence: Bool = true, acceptDeepScan: Bool = false
    ) -> [FileHit] {
        let auditSearch = ArchitectureAuditTrace.begin("gateway_total")
        defer { auditSearch?.end() }
        let totalStarted = ProcessInfo.processInfo.systemUptime
        defer {
            recorder?.totalMilliseconds =
                (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000
        }
        let metadataStarted = ProcessInfo.processInfo.systemUptime
        let compiled = LibraryIndex.compile(query)
        let needles = compiled.tokens.flatMap(LibraryIndex.aliases)
        let visualCandidatePaths = Set(semantic.filter { $0.retrievalChannel == "visual" }.map(\.path))
        let filtered = files.filter { file in
            (compiled.kinds == nil || compiled.kinds!.contains(file.kind) || visualCandidatePaths.contains(file.path))
                && (compiled.ext == nil || compiled.ext == file.ext)
        }
        recorder?.metadataMilliseconds =
            (ProcessInfo.processInfo.systemUptime - metadataStarted) * 1_000
        guard !compiled.tokens.isEmpty || !compiled.anyOf.isEmpty else {
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
        // During catalog refresh, files lack version IDs but the last complete database snapshot
        // remains searchable. Scan filenames locally and include current FTS results below.
        let unprojected = filtered.filter { $0.versionID == nil }
        let local = LibraryIndex.search(query: query, in: unprojected, limit: max(unprojected.count, 40))
        do {
            let roots = Array(Set(filtered.map(\.rootPath)))
            let ftsStarted = ProcessInfo.processInfo.systemUptime
            let auditFTS = ArchitectureAuditTrace.begin("fts5")
            let strict = try store().search(allTerms: compiled.tokens.map(LibraryIndex.aliases), anyTerms: compiled.anyOf, rootPaths: roots)
            auditFTS?.end(count: strict.count)
            recorder?.ftsMilliseconds =
                (ProcessInfo.processInfo.systemUptime - ftsStarted) * 1_000
            let evidenceStarted = ProcessInfo.processInfo.systemUptime
            let auditEvidence = ArchitectureAuditTrace.begin("gateway_evidence_and_file_strength")
            let byPath = Dictionary(uniqueKeysWithValues: filtered.map { ($0.path, $0) })
            var lexicalPaths: [String] = [], semanticPaths: [String] = [], visualPaths: [String] = []
            var lexicalSeen = Set<String>(), semanticSeen = Set<String>(), visualSeen = Set<String>()
            var evidence: [String: [String: (chunk: ChunkResult, cosine: Double, ranked: Bool)]] = [:]
            let auditSupport = ArchitectureAuditTrace.begin("gateway_candidate_support_filter")
            var numericCheckMS = 0.0, supportCacheHits = 0
            // This verdict depends only on the query and immutable file snapshot, not on
            // a candidate chunk. Visual candidates bypass it; permission/version guards
            // still run for every candidate before looking up the verdict.
            var fileSupport: [String: Bool] = [:]
            let reuseFileSupport = reuseEvidence && !(ArchitectureAuditTrace.enabled &&
                ProcessInfo.processInfo.environment["AIE_AUDIT_DISABLE_EVIDENCE_REUSE"] == "1")
            func supports(_ file: IndexedFile) -> Bool {
                if reuseFileSupport, let cached = fileSupport[file.path] {
                    supportCacheHits += 1
                    return cached
                }
                let numericStarted = auditSupport == nil ? 0 : ProcessInfo.processInfo.systemUptime
                let numericSupported = compiled.numericTerms.allSatisfy { NumericSearch.contains($0, in: file.haystack) }
                if auditSupport != nil { numericCheckMS += (ProcessInfo.processInfo.systemUptime - numericStarted) * 1000 }
                guard numericSupported else { fileSupport[file.path] = false; return false }
                fileSupport[file.path] = true
                return true
            }
            for chunk in strict {
                guard let file = byPath[chunk.path], file.versionID == nil || file.versionID == chunk.versionID else { continue }
                if lexicalSeen.insert(chunk.path).inserted { lexicalPaths.append(chunk.path) }
                evidence[chunk.path, default: [:]][chunk.id + ":fts"] = (chunk, 0, false)
            }
            for chunk in semantic {
                if chunk.retrievalChannel == "deepscan" && !acceptDeepScan { continue }
                guard let file = byPath[chunk.path], file.versionID == nil || file.versionID == chunk.versionID else { continue }
                if chunk.retrievalChannel != "visual" && !supports(file) { continue }
                if chunk.retrievalChannel == "visual" {
                    if visualSeen.insert(chunk.path).inserted { visualPaths.append(chunk.path) }
                } else if semanticSeen.insert(chunk.path).inserted { semanticPaths.append(chunk.path) }
                evidence[chunk.path, default: [:]][chunk.id + ":" + (chunk.retrievalChannel ?? "semantic")] =
                    (chunk, chunk.score, chunk.retrievalChannel != nil)
            }
            auditSupport?.end(count: evidence.count, fields: [
                "numeric_check_ms": numericCheckMS,
                "semantic_candidates": semantic.count, "support_cache_hits": supportCacheHits,
                "reuse_file_support": reuseFileSupport,
                "drawing_rule_enabled": false,
            ])
            let localHits = Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) })
            let candidatePaths = Set(localHits.keys).union(evidence.keys)
            var filenameMatches = Set<String>()
            var numericStrengths: [String: Int] = [:]
            for file in filtered where candidatePaths.contains(file.path) {
                numericStrengths[file.path] = compiled.numericTerms.map { NumericSearch.strength($0, in: file.haystack) }.min() ?? 0
                if EvidencePolicy.coverage(file.name, query: compiled) >= 1 {
                    filenameMatches.insert(file.path)
                }
            }
            recorder?.evidenceMilliseconds =
                (ProcessInfo.processInfo.systemUptime - evidenceStarted) * 1_000
            auditEvidence?.end(count: candidatePaths.count)
            let fusionStarted = ProcessInfo.processInfo.systemUptime
            let auditFusion = ArchitectureAuditTrace.begin("gateway_rrf_and_sort")
            let fused = RankFusion.fuse(
                [local.map(\.path), lexicalPaths, semanticPaths, visualPaths],
                limit: max(candidatePaths.count, 40)
            )
            let rank = Dictionary(uniqueKeysWithValues: fused.enumerated().map { ($1, $0) })
            let ordered = candidatePaths.sorted {
                if numericStrengths[$0, default: 0] != numericStrengths[$1, default: 0] { return numericStrengths[$0, default: 0] > numericStrengths[$1, default: 0] }
                return rank[$0, default: Int.max] < rank[$1, default: Int.max]
            }
            recorder?.fusionMilliseconds =
                (ProcessInfo.processInfo.systemUptime - fusionStarted) * 1_000
            auditFusion?.end(count: ordered.count)
            let tieringStarted = ProcessInfo.processInfo.systemUptime
            let auditDisplay = ArchitectureAuditTrace.begin("gateway_snippets_and_tiering")
            let displayPaths = ordered.filter { path in
                lexicalSeen.contains(path) || evidence[path, default: [:]].values.contains { candidate in
                    switch candidate.chunk.retrievalChannel {
                    case "raw_text": return candidate.cosine >= 0.70
                    case "deepscan": return acceptDeepScan && candidate.cosine >= 0.70
                    case "visual": return candidate.cosine >= 0.65
                    default: return false
                    }
                }
            }
            let result = Array(displayPaths.prefix(limit).compactMap { path -> FileHit? in
                guard let file = byPath[path] else { return nil }
                let candidates = Array(evidence[path, default: [:]].values)
                let chosen = candidates.map { (value: $0, priority: EvidencePolicy.priority(
                    $0.chunk, cosine: $0.cosine, query: compiled, ranked: $0.ranked)) }.sorted {
                    if $0.priority != $1.priority { return $0.priority > $1.priority }
                    return $0.value.chunk.id < $1.value.chunk.id
                }.first?.value
                var selected = localHits[path]
                if let chosen {
                    selected = evidenceHit(file: file, chunk: chosen.chunk, query: query,
                        reason: filenameMatches.contains(path) ? "文件名" : (chosen.chunk.retrievalChannel == "visual" ? "视觉" : (chosen.ranked || chosen.cosine > 0 ? "语义" : "全文")),
                        needles: needles)
                }
                guard var hit = selected else { return nil }
                let numeric = numericStrengths[path, default: 0]
                var sourceHits: [SearchEvidenceSource: SearchEvidence] = [:]
                for candidate in evidence[path, default: [:]].values {
                    let chunk = candidate.chunk
                    let source: SearchEvidenceSource
                    switch chunk.retrievalChannel {
                    case "visual": source = .visual
                    case "deepscan": source = .summary
                    case "summary": source = .summary
                    case "raw_text": source = .semantic
                    default:
                        if candidate.cosine > 0 { source = .semantic }
                        else if chunk.kind.contains("ocr") { source = .ocr }
                        else if chunk.kind.contains("transcript") { source = .transcript }
                        else if EvidencePolicy.isModelDerived(chunk.kind) || chunk.kind == "document" { source = .summary }
                        else { source = .body }
                    }
                    if sourceHits[source] == nil {
                        sourceHits[source] = SearchEvidence(
                            source: source, strength: candidate.ranked ? 0.5 : (candidate.cosine > 0 ? candidate.cosine : 0.75),
                            chunkID: chunk.id, page: chunk.page,
                            startSeconds: chunk.startSeconds, endSeconds: chunk.endSeconds
                        )
                    }
                }
                if numeric > 0 { sourceHits[.identifier] = .init(source: .identifier, strength: 1, chunkID: hit.chunkID, page: hit.page) }
                if filenameMatches.contains(path) { sourceHits[.filename] = .init(source: .filename, strength: 1, chunkID: hit.chunkID, page: hit.page) }
                if sourceHits.isEmpty {
                    let source: SearchEvidenceSource = hit.reason == "路径" ? .path : .summary
                    sourceHits[source] = .init(source: source, strength: 0.25, chunkID: hit.chunkID, page: hit.page)
                }
                hit.confidenceTier = (lexicalSeen.contains(path) || filenameMatches.contains(path) || numeric > 0) ? .direct : .possible
                hit.evidence = sourceHits.values.sorted { $0.source.rawValue < $1.source.rawValue }
                return hit
            })
            recorder?.tieringMilliseconds =
                (ProcessInfo.processInfo.systemUptime - tieringStarted) * 1_000
            auditDisplay?.end(count: result.count)
            SearchRuleAblationDiagnostics.gateway(query: query, files: filtered, strict: strict,
                semantic: semantic, support: fileSupport, ordered: ordered, strengths: [:], hits: result)
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
        let filterAudit = ArchitectureAuditTrace.begin("fallback_file_filter")
        let compiled = LibraryIndex.compile(query)
        let filtered = files.filter { file in
            (compiled.kinds == nil || compiled.kinds!.contains(file.kind)) && (compiled.ext == nil || compiled.ext == file.ext)
                && compiled.numericTerms.allSatisfy { NumericSearch.contains($0, in: file.haystack) }
        }
        let byPath = Dictionary(uniqueKeysWithValues: filtered.map { ($0.path, $0) })
        let terms = compiled.tokens.flatMap(LibraryIndex.aliases) + compiled.anyOf + expandedTerms
        filterAudit?.end(count: filtered.count)
        var textHits: [FileHit] = [], seen = Set<String>()
        do {
            let ftsAudit = ArchitectureAuditTrace.begin("fallback_fts")
            var ftsFinished = false
            defer { if !ftsFinished { ftsAudit?.end(fields: ["completed": false]) } }
            let chunks = try store().search(allTerms: [], anyTerms: terms, rootPaths: Array(Set(filtered.map(\.rootPath))))
            ftsAudit?.end(count: chunks.count)
            ftsFinished = true
            let evidenceAudit = ArchitectureAuditTrace.begin("fallback_evidence_sort_and_materialize")
            defer { evidenceAudit?.end(count: textHits.count) }
            let evidenceQuery = LibraryIndex.compile(([query] + expandedTerms).joined(separator: " "))
            let ordered = chunks.enumerated().sorted {
                let left = EvidencePolicy.priority($0.element, cosine: 0, query: evidenceQuery)
                let right = EvidencePolicy.priority($1.element, cosine: 0, query: evidenceQuery)
                return left == right ? $0.offset < $1.offset : left > right
            }
            for (_, chunk) in ordered {
                guard let file = byPath[chunk.path], file.versionID == nil || file.versionID == chunk.versionID,
                      seen.insert(file.path).inserted else { continue }
                textHits.append(evidenceHit(file: file, chunk: chunk, query: ([query] + expandedTerms).joined(separator: " "), reason: "原文候选"))
            }
        } catch { AppLog.write("fallback text retrieval unavailable: \(error)") }
        let vectorHits = search(query: query, in: filtered, semantic: semantic)
        let mergeAudit = ArchitectureAuditTrace.begin("fallback_fusion")
        defer { mergeAudit?.end(count: textHits.count + vectorHits.count) }
        let all = Dictionary((textHits + vectorHits).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return RankFusion.fuse([textHits.map(\.path), vectorHits.map(\.path)], limit: limit).compactMap { all[$0] }
    }

    static func visualCandidates(_ semantic: [ChunkResult], in files: [IndexedFile]) -> [FileHit] {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var seen = Set<String>()
        return semantic.compactMap { chunk in
            guard let file = byPath[chunk.path], file.versionID == nil || file.versionID == chunk.versionID,
                  seen.insert(chunk.path).inserted else { return nil }
            var hit = evidenceHit(file: file, chunk: chunk, query: "", reason: "视觉")
            hit.confidenceTier = .possible
            hit.evidence = [.init(source: .visual, strength: 0.5, chunkID: chunk.id, page: chunk.page,
                                  startSeconds: chunk.startSeconds, endSeconds: chunk.endSeconds)]
            return hit
        }
    }

    private static func evidenceHit(file: IndexedFile, chunk: ChunkResult, query: String, reason: String,
                                    needles: [String]? = nil) -> FileHit {
        let indexed = IndexedChunk(id: chunk.id, versionID: chunk.versionID, page: chunk.page, text: chunk.text, tags: chunk.tags,
                                   summary: chunk.summary, kind: chunk.kind, startSeconds: chunk.startSeconds, endSeconds: chunk.endSeconds, locationJSON: chunk.locationJSON)
        return EvidencePolicy.hit(file: file, chunk: indexed, query: query, reason: reason, needles: needles)
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
        if ["jpg","jpeg","png","webp","heic","bmp","gif","tif","tiff"].contains(file.ext) {
            return [ContentBlock(key: "visual-image", kind: "visual_image", text: "",
                                 summaryMethod: "visual_anchor", parserVersion: "visual-image-1")]
        }
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
                let page = index + 1
                let text = pdf.page(at: index)?.string ?? ""
                let content = text.isEmpty ? [] : StructuralChunker.page(
                    String(text.prefix(32000)), key: "pdf-\(page)", kind: "page", page: page, parserVersion: "pdfkit-visual-2"
                )
                return content + [ContentBlock(
                    key: "visual-page-\(page)", kind: "visual_page", page: page,
                    text: "", summaryMethod: "visual_anchor", parserVersion: "pdfkit-visual-2"
                )]
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
