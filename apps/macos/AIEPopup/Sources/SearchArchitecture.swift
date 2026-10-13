import Foundation

struct SearchRequestVersion: Equatable, Sendable {
    let generation: Int
    let normalizedQuery: String

    init(generation: Int, query: String) {
        self.generation = generation
        normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(generation currentGeneration: Int, query currentQuery: String) -> Bool {
        generation == currentGeneration
            && normalizedQuery == currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SearchPlanCacheKey: Hashable, Sendable {
    let model: String
    let schemaVersion: String
    let normalizedQuery: String
    let round: Int
    let evidenceRevision: String

    init(model: String, schemaVersion: String, query: String, round: Int, evidence: [FileHit]) {
        self.model = model
        self.schemaVersion = schemaVersion
        normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.round = round
        evidenceRevision = evidence.prefix(16).map {
            [$0.path, $0.chunkID ?? "", String($0.page ?? -1), $0.snippet].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
    }
}

struct ProgressiveSearchBudget: Equatable, Sendable {
    let maxRounds: Int
    let deadline: TimeInterval
    private(set) var roundsStarted = 0

    init(maxRounds: Int = 3, timeout: TimeInterval = 12,
         startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.maxRounds = max(0, maxRounds)
        deadline = startedAt + max(0, timeout)
    }

    mutating func beginNextRound(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        guard roundsStarted < maxRounds, now < deadline else { return nil }
        roundsStarted += 1
        return roundsStarted
    }
}

struct SearchQuery: Sendable {
    let text: String
    let normalized: String
    let isIdentifier: Bool

    init(_ text: String) {
        self.text = text
        normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        isIdentifier = LibraryIndex.compile(text).isIdentifierQuery
    }
}

enum SearchQueryKind: String, Codable, Sendable {
    case browse
    case identifier
    case locator
    case content
}

enum SearchRetrievalRoute: String, Codable, Hashable, Sendable {
    case metadata
    case lexical
    case semantic
    case modelPlan
}

struct SearchRoutingDecision: Equatable, Sendable {
    let kind: SearchQueryKind
    let routes: Set<SearchRetrievalRoute>

    func uses(_ route: SearchRetrievalRoute) -> Bool { routes.contains(route) }
}

enum SearchRouter {
    static func route(_ text: String) -> SearchRoutingDecision {
        let query = SearchQuery(text)
        let compiled = LibraryIndex.compile(text)
        if query.isIdentifier {
            return .init(kind: .identifier, routes: [.metadata, .lexical])
        }
        if compiled.allowsUnfilteredBrowse {
            return .init(kind: .browse, routes: [.metadata])
        }
        let namedExtension = query.normalized.range(
            of: #"[^\s/\\]+\.[a-z0-9]{1,8}\b"#, options: .regularExpression
        ) != nil
        if query.normalized.contains("/") || query.normalized.contains("\\") || namedExtension {
            return .init(kind: .locator, routes: [.metadata, .lexical])
        }
        guard !compiled.tokens.isEmpty || !compiled.anyOf.isEmpty else {
            return .init(kind: .browse, routes: [])
        }
        return .init(kind: .content, routes: [.lexical, .semantic, .modelPlan])
    }
}

struct SearchPlan: Sendable {
    let intent: String
    let mustTerms: [String]
    let optionalTerms: [String]
    let excludedTerms: [String]
    let media: [String]
    let people: [String]
    let places: [String]
    let timeExpression: String?
    let rankedPaths: [String]
    let done: Bool

    var retrievalTerms: [String] {
        var seen = Set<String>()
        return (mustTerms + optionalTerms).filter { seen.insert($0.lowercased()).inserted }
    }
}

enum SearchConfidenceTier: String, Codable, Sendable {
    case direct
    case possible
}

enum SearchEvidenceSource: String, Codable, Hashable, Sendable {
    case filename
    case path
    case body
    case ocr
    case transcript
    case identifier
    case summary
    case semantic
    case modelVerified
}

struct SearchEvidence: Codable, Equatable, Sendable {
    let source: SearchEvidenceSource
    let strength: Double
    let chunkID: String?
    let page: Int?
    var startSeconds: Double? = nil
    var endSeconds: Double? = nil
}

struct SearchCandidate: Identifiable, Equatable {
    var id: String { hit.id }
    var hit: FileHit
    var tier: SearchConfidenceTier
    var evidence: [SearchEvidence]
    let fileID: String?
    let versionID: String?
    let contentHash: String?
    let matchedUnitID: String?

    init(hit: FileHit, tier: SearchConfidenceTier, evidence: [SearchEvidence],
         fileID: String?, versionID: String?, contentHash: String?) {
        self.hit = hit
        self.tier = tier
        self.evidence = evidence
        self.fileID = fileID
        self.versionID = versionID
        self.contentHash = contentHash
        matchedUnitID = hit.chunkID
    }

    func isCurrent(in file: IndexedFile) -> Bool {
        hit.path == file.path
            && (fileID == nil || fileID == file.fileID)
            && (versionID == nil || versionID == file.versionID)
            && (contentHash == nil || contentHash == file.contentHash)
    }
}

struct SearchTrace: Codable, Sendable {
    struct Stage: Codable, Sendable {
        let name: String
        let milliseconds: Double
        let candidates: Int
    }

    let id: UUID
    let startedAt: TimeInterval
    let stages: [Stage]
    let queryKind: SearchQueryKind?
    let routes: [SearchRetrievalRoute]
    let resultCount: Int
    let directCount: Int
}

/// Per-query diagnostics intentionally contain no query text, filenames or paths.
final class SearchTraceSession: @unchecked Sendable {
    let id = UUID()
    let startedAt = Date().timeIntervalSince1970
    private let lock = NSLock()
    private var stages: [SearchTrace.Stage] = []
    private var routing: SearchRoutingDecision?

    func recordRouting(_ decision: SearchRoutingDecision) {
        lock.lock()
        routing = decision
        lock.unlock()
    }

    func measure<T>(_ name: String, operation: () -> T, candidates: (T) -> Int) -> T {
        let started = ProcessInfo.processInfo.systemUptime
        let value = operation()
        record(name, startedAt: started, candidates: candidates(value))
        return value
    }

    func record(_ name: String, startedAt: TimeInterval, candidates: Int) {
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        lock.lock()
        stages.append(.init(name: name, milliseconds: elapsed, candidates: candidates))
        lock.unlock()
    }

    func finish(hits: [FileHit]) -> SearchTrace {
        lock.lock()
        let snapshot = stages
        let routing = routing
        lock.unlock()
        let trace = SearchTrace(
            id: id,
            startedAt: startedAt,
            stages: snapshot,
            queryKind: routing?.kind,
            routes: routing.map { Array($0.routes).sorted { $0.rawValue < $1.rawValue } } ?? [],
            resultCount: hits.count,
            directCount: hits.filter { $0.confidenceTier == .direct }.count
        )
        SearchTraceStore.append(trace)
        return trace
    }
}

enum SearchTraceStore {
    private static let lock = NSLock()
    private static var traces: [SearchTrace] = []

    static func append(_ trace: SearchTrace) {
        lock.lock()
        traces.append(trace)
        if traces.count > 100 { traces.removeFirst(traces.count - 100) }
        lock.unlock()
    }

    static var latest: SearchTrace? {
        lock.lock()
        defer { lock.unlock() }
        return traces.last
    }
}

enum SearchTiering {
    /// Model ordering never crosses the independently evidenced direct/possible boundary.
    static func mergeModelOrder(rankedPaths: [String], current: [FileHit]) -> [FileHit] {
        guard !rankedPaths.isEmpty else { return current }
        let direct = current.filter { $0.confidenceTier == .direct }
        let possible = current.filter { $0.confidenceTier == .possible }
        let byPath = Dictionary(uniqueKeysWithValues: possible.map { ($0.path, $0) })
        var seen = Set(direct.map(\.path))
        var result = direct
        for path in rankedPaths where seen.insert(path).inserted {
            guard var hit = byPath[path] else { continue }
            hit.evidence.append(.init(
                source: .modelVerified, strength: 0.75, chunkID: hit.chunkID, page: hit.page
            ))
            result.append(hit)
        }
        for hit in possible where seen.insert(hit.path).inserted { result.append(hit) }
        return result
    }
}
