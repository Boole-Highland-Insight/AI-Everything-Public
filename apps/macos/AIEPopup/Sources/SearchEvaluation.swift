import Foundation
import AIEData
import AppKit
import SwiftUI
import Combine

struct SearchEvaluationSuite: Decodable {
    let version: Int
    let includeSemantic: Bool
    let cases: [SearchEvaluationCase]

    init(version: Int, includeSemantic: Bool, cases: [SearchEvaluationCase]) {
        self.version = version
        self.includeSemantic = includeSemantic
        self.cases = cases
    }

    enum CodingKeys: String, CodingKey { case version, includeSemantic, cases }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        includeSemantic = try values.decodeIfPresent(Bool.self, forKey: .includeSemantic) ?? false
        cases = try values.decode([SearchEvaluationCase].self, forKey: .cases)
    }
}

struct SearchEvaluationCase: Decodable {
    let id: String
    let query: String
    let mustAppear: [String]
    let mayAppear: [String]
    let mustNotAppear: [String]
    let expectedDirect: [String]
    let locations: [String: SearchExpectedLocation]

    enum CodingKeys: String, CodingKey {
        case id, query, mustAppear, mayAppear, mustNotAppear, expectedDirect, locations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        query = try values.decode(String.self, forKey: .query)
        mustAppear = try values.decodeIfPresent([String].self, forKey: .mustAppear) ?? []
        mayAppear = try values.decodeIfPresent([String].self, forKey: .mayAppear) ?? []
        mustNotAppear = try values.decodeIfPresent([String].self, forKey: .mustNotAppear) ?? []
        expectedDirect = try values.decodeIfPresent([String].self, forKey: .expectedDirect) ?? []
        locations = try values.decodeIfPresent(
            [String: SearchExpectedLocation].self, forKey: .locations
        ) ?? [:]
    }
}

struct SearchExpectedLocation: Decodable {
    let page: Int?
    let startSeconds: Double?
    let endSeconds: Double?
}

struct SearchEvaluationRankedFile: Encodable {
    let rank: Int
    let fileID: String?
    let path: String
}

struct SearchEvaluationCaseResult: Encodable {
    let id: String
    let query: String
    let milliseconds: Double
    let semanticCandidates: Int
    let semanticTopKBeforeThreshold: Int
    let semanticRejectedByThreshold: Int
    let semanticHighestScore: Double?
    let semanticLowestAcceptedScore: Double?
    let semanticError: String?
    let scannedVectors: Int
    let queryVectorCacheHit: Bool
    let stageMilliseconds: [String: Double]
    let modelCallsAttempted: Int
    let modelCallsCompleted: Int
    let jevRequests: Int
    let jevErrors: Int
    let jevInputTokens: Int
    let returned: [String]
    let top30: [SearchEvaluationRankedFile]
    let missingRequired: [String]
    let forbidden: [String]
    let missingDirect: [String]
    let wrongLocations: [String]
    let reciprocalRank: Double
}

struct SearchEvaluationStageSummary: Encodable {
    let samples: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
}

struct SearchEvaluationReport: Encodable {
    let suiteVersion: Int
    let mode: String
    let caseCount: Int
    let semanticQueriesWithCandidates: Int
    let semanticErrors: Int
    let queryVectorCacheHits: Int
    let scannedVectors: Int
    let semanticTopKBeforeThreshold: Int
    let semanticRejectedByThreshold: Int
    let semanticHighestScoreP50: Double
    let semanticHighestScoreP95: Double
    let stageTimings: [String: SearchEvaluationStageSummary]
    let modelCallsAttempted: Int
    let modelCallsCompleted: Int
    let jevRequests: Int
    let jevErrors: Int
    let jevInputTokens: Int
    let jevOutputTokens: Int
    let jevEstimatedCostUSD: Double
    let precisionAt5: Double
    let precisionAt10: Double
    let top1HitRate: Double
    let recallAt20: Double
    let meanReciprocalRank: Double
    let nDCGAt10: Double
    let forbiddenHitRateAt20: Double
    let directRecall: Double
    let locationAccuracy: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let passed: Bool
    let cases: [SearchEvaluationCaseResult]
}

enum SearchEvaluation {
    static func report(
        suite: SearchEvaluationSuite,
        mode: String,
        results: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)],
        fileIDsByPath: [String: String] = [:]
    ) -> SearchEvaluationReport {
        var caseResults: [SearchEvaluationCaseResult] = []
        var relevantTop5 = 0
        var returnedTop5 = 0
        var relevantTop10 = 0
        var returnedTop10 = 0
        var top1Hits = 0
        var requiredFound = 0
        var requiredTotal = 0
        var forbiddenHits = 0
        var returnedTop20 = 0
        var reciprocalRank = 0.0
        var normalizedDiscountedGain = 0.0
        var rankedCases = 0
        var directFound = 0
        var directTotal = 0
        var locationsCorrect = 0
        var locationsTotal = 0
        var latencies: [Double] = []
        var semanticQueriesWithCandidates = 0
        var semanticErrors = 0
        var queryVectorCacheHits = 0
        var scannedVectors = 0
        var semanticTopKBeforeThreshold = 0
        var semanticRejectedByThreshold = 0
        var semanticHighestScores: [Double] = []
        var stageSamples: [String: [Double]] = [:]
        var modelCallsAttempted = 0
        var modelCallsCompleted = 0
        var jevRequests = 0
        var jevErrors = 0
        var jevInputTokens = 0
        var jevOutputTokens = 0
        var jevCostUSD = 0.0

        for (test, execution, milliseconds) in results {
            let hits = execution.hits
            if execution.semanticCandidates > 0 { semanticQueriesWithCandidates += 1 }
            if execution.semanticError != nil { semanticErrors += 1 }
            if execution.queryVectorCacheHit { queryVectorCacheHits += 1 }
            scannedVectors += execution.scannedVectors
            semanticTopKBeforeThreshold += execution.semanticTopKBeforeThreshold
            semanticRejectedByThreshold += execution.semanticRejectedByThreshold
            if let score = execution.semanticHighestScore {
                semanticHighestScores.append(score)
            }
            for (stage, value) in execution.stageMilliseconds {
                stageSamples[stage, default: []].append(value)
            }
            stageSamples["query.total", default: []].append(milliseconds)
            modelCallsAttempted += execution.modelCallsAttempted
            modelCallsCompleted += execution.modelCallsCompleted
            jevRequests += execution.jevRequests
            jevErrors += execution.jevErrors
            jevInputTokens += execution.jevInputTokens
            jevOutputTokens += execution.jevOutputTokens
            jevCostUSD += execution.jevCostUSD
            let top20 = Array(hits.prefix(20))
            let returned = Array(hits.prefix(30)).map(\.relative)
            let relevant = Set(test.mustAppear + test.mayAppear)
            relevantTop5 += top20.prefix(5).filter { relevant.contains($0.relative) }.count
            relevantTop10 += top20.prefix(10).filter { relevant.contains($0.relative) }.count
            if !relevant.isEmpty {
                returnedTop5 += max(1, min(5, top20.count))
                returnedTop10 += max(1, min(10, top20.count))
                rankedCases += 1
                if let first = top20.first, relevant.contains(first.relative) { top1Hits += 1 }
            }
            let found = Set(top20.map(\.relative))
            let missingRequired = test.mustAppear.filter { !found.contains($0) }
            requiredFound += test.mustAppear.count - missingRequired.count
            requiredTotal += test.mustAppear.count
            let forbidden = test.mustNotAppear.filter { found.contains($0) }
            forbiddenHits += forbidden.count
            returnedTop20 += top20.count
            if let rank = top20.firstIndex(where: { relevant.contains($0.relative) }) {
                reciprocalRank += 1.0 / Double(rank + 1)
            }
            if !relevant.isEmpty {
                let required = Set(test.mustAppear)
                let gains = top20.prefix(10).enumerated().map { index, hit -> Double in
                    let relevance = required.contains(hit.relative) ? 2
                        : (relevant.contains(hit.relative) ? 1 : 0)
                    return relevance == 0 ? 0
                        : (pow(2, Double(relevance)) - 1) / log2(Double(index + 2))
                }
                let idealRelevance = (
                    Array(repeating: 2, count: test.mustAppear.count)
                        + Array(repeating: 1, count: test.mayAppear.count)
                ).prefix(10)
                let ideal = idealRelevance.enumerated().reduce(0.0) { value, item in
                    value + (pow(2, Double(item.element)) - 1) / log2(Double(item.offset + 2))
                }
                if ideal > 0 { normalizedDiscountedGain += gains.reduce(0, +) / ideal }
            }

            let direct = Set(top20.filter { $0.confidenceTier == .direct }.map(\.relative))
            let missingDirect = test.expectedDirect.filter { !direct.contains($0) }
            directFound += test.expectedDirect.count - missingDirect.count
            directTotal += test.expectedDirect.count

            var wrongLocations: [String] = []
            for (path, expected) in test.locations {
                locationsTotal += 1
                guard let hit = top20.first(where: { $0.relative == path }),
                      location(hit, matches: expected) else {
                    wrongLocations.append(path)
                    continue
                }
                locationsCorrect += 1
            }
            latencies.append(milliseconds)
            caseResults.append(SearchEvaluationCaseResult(
                id: test.id, query: test.query, milliseconds: milliseconds,
                semanticCandidates: execution.semanticCandidates,
                semanticTopKBeforeThreshold: execution.semanticTopKBeforeThreshold,
                semanticRejectedByThreshold: execution.semanticRejectedByThreshold,
                semanticHighestScore: execution.semanticHighestScore,
                semanticLowestAcceptedScore: execution.semanticLowestAcceptedScore,
                semanticError: execution.semanticError,
                scannedVectors: execution.scannedVectors,
                queryVectorCacheHit: execution.queryVectorCacheHit,
                stageMilliseconds: execution.stageMilliseconds,
                modelCallsAttempted: execution.modelCallsAttempted,
                modelCallsCompleted: execution.modelCallsCompleted,
                jevRequests: execution.jevRequests,
                jevErrors: execution.jevErrors,
                jevInputTokens: execution.jevInputTokens,
                returned: returned,
                top30: hits.prefix(30).enumerated().map {
                    SearchEvaluationRankedFile(rank: $0.offset + 1,
                        fileID: fileIDsByPath[$0.element.path], path: $0.element.path)
                },
                missingRequired: missingRequired, forbidden: forbidden,
                missingDirect: missingDirect, wrongLocations: wrongLocations,
                reciprocalRank: top20.firstIndex(where: { relevant.contains($0.relative) })
                    .map { 1.0 / Double($0 + 1) } ?? 0
            ))
        }

        let stageTimings = stageSamples.mapValues { values in
            SearchEvaluationStageSummary(
                samples: values.count,
                p50Milliseconds: percentile(values, 0.50),
                p95Milliseconds: percentile(values, 0.95),
                minimumMilliseconds: values.min() ?? 0,
                maximumMilliseconds: values.max() ?? 0
            )
        }
        let report = SearchEvaluationReport(
            suiteVersion: suite.version,
            mode: mode,
            caseCount: results.count,
            semanticQueriesWithCandidates: semanticQueriesWithCandidates,
            semanticErrors: semanticErrors,
            queryVectorCacheHits: queryVectorCacheHits,
            scannedVectors: scannedVectors,
            semanticTopKBeforeThreshold: semanticTopKBeforeThreshold,
            semanticRejectedByThreshold: semanticRejectedByThreshold,
            semanticHighestScoreP50: percentile(semanticHighestScores, 0.50),
            semanticHighestScoreP95: percentile(semanticHighestScores, 0.95),
            stageTimings: stageTimings,
            modelCallsAttempted: modelCallsAttempted,
            modelCallsCompleted: modelCallsCompleted,
            jevRequests: jevRequests,
            jevErrors: jevErrors,
            jevInputTokens: jevInputTokens,
            jevOutputTokens: jevOutputTokens,
            jevEstimatedCostUSD: jevCostUSD > 0
                ? jevCostUSD
                : Double(jevInputTokens) * JevRerank.inputDollarsPerMillionTokens / 1_000_000,
            precisionAt5: returnedTop5 == 0 ? 1 : Double(relevantTop5) / Double(returnedTop5),
            precisionAt10: returnedTop10 == 0 ? 1 : Double(relevantTop10) / Double(returnedTop10),
            top1HitRate: rankedCases == 0 ? 1 : Double(top1Hits) / Double(rankedCases),
            recallAt20: requiredTotal == 0 ? 1 : Double(requiredFound) / Double(requiredTotal),
            meanReciprocalRank: rankedCases == 0 ? 1 : reciprocalRank / Double(rankedCases),
            nDCGAt10: rankedCases == 0 ? 1 : normalizedDiscountedGain / Double(rankedCases),
            forbiddenHitRateAt20: returnedTop20 == 0 ? 0 : Double(forbiddenHits) / Double(returnedTop20),
            directRecall: directTotal == 0 ? 1 : Double(directFound) / Double(directTotal),
            locationAccuracy: locationsTotal == 0 ? 1 : Double(locationsCorrect) / Double(locationsTotal),
            p50Milliseconds: percentile(latencies, 0.50),
            p95Milliseconds: percentile(latencies, 0.95),
            passed: caseResults.allSatisfy {
                $0.missingRequired.isEmpty && $0.forbidden.isEmpty
                    && $0.missingDirect.isEmpty && $0.wrongLocations.isEmpty
            },
            cases: caseResults
        )
        return report
    }

    private static func location(_ hit: FileHit, matches expected: SearchExpectedLocation) -> Bool {
        if let page = expected.page, hit.page != page { return false }
        if let start = expected.startSeconds,
           hit.startSeconds == nil || abs(hit.startSeconds! - start) > 0.01 { return false }
        if let end = expected.endSeconds,
           hit.endSeconds == nil || abs(hit.endSeconds! - end) > 0.01 { return false }
        return true
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[max(0, index)]
    }
}

private enum SearchEvaluationMode: String {
    case fast
    case hybrid
    case planned
    case precision
    case jev
    case bge
    case fair
    case local
    case decisionAB = "decision-ab"

    var usesSemantic: Bool { self != .fast }
    var usesModel: Bool { self == .planned || self == .precision || self == .fair || self == .local }
    var usesJev: Bool { self == .jev || self == .fair || self == .decisionAB }
    var usesClef: Bool { self == .decisionAB }
}

struct SearchEvaluationQueryResult {
    let hits: [FileHit]
    let semanticCandidates: Int
    let semanticTopKBeforeThreshold: Int
    let semanticRejectedByThreshold: Int
    let semanticHighestScore: Double?
    let semanticLowestAcceptedScore: Double?
    let semanticError: String?
    let scannedVectors: Int
    let queryVectorCacheHit: Bool
    let stageMilliseconds: [String: Double]
    let modelCallsAttempted: Int
    let modelCallsCompleted: Int
    let jevRequests: Int
    let jevErrors: Int
    let jevInputTokens: Int
    let jevOutputTokens: Int
    let jevCostUSD: Double

    init(
        hits: [FileHit], semantic: SemanticSearchProfile?,
        gateway: LibrarySearchStageRecorder,
        modelCallsAttempted: Int, modelCallsCompleted: Int,
        extraStages: [String: Double] = [:],
        jevRequests: Int = 0, jevErrors: Int = 0,
        jevInputTokens: Int = 0, jevOutputTokens: Int = 0, jevCostUSD: Double = 0
    ) {
        self.hits = hits
        semanticCandidates = semantic?.results.count ?? 0
        semanticTopKBeforeThreshold = semantic?.topKBeforeThreshold ?? 0
        semanticRejectedByThreshold = semantic?.topKRejectedByThreshold ?? 0
        semanticHighestScore = semantic?.highestScore
        semanticLowestAcceptedScore = semantic?.lowestAcceptedScore
        semanticError = semantic?.error
        scannedVectors = semantic?.vectorDiagnostics?.scannedVectors ?? 0
        queryVectorCacheHit = semantic?.queryVectorCacheHit ?? false
        var stages: [String: Double] = [
            "gateway.metadata": gateway.metadataMilliseconds,
            "gateway.fts": gateway.ftsMilliseconds,
            "gateway.evidence": gateway.evidenceMilliseconds,
            "gateway.fusion": gateway.fusionMilliseconds,
            "gateway.tiering": gateway.tieringMilliseconds,
            "gateway.total": gateway.totalMilliseconds,
        ]
        if let semantic {
            stages["semantic.embedding"] = semantic.embeddingMilliseconds
            stages["semantic.threshold"] = semantic.thresholdMilliseconds
            stages["semantic.total"] = semantic.totalMilliseconds
            if let vector = semantic.vectorDiagnostics {
                stages["vector.connection_wait"] = vector.connectionWaitMilliseconds
                stages["vector.metadata_read"] = vector.metadataReadMilliseconds
                stages["vector.candidate_read"] = vector.candidateReadMilliseconds
                stages["vector.cosine"] = vector.cosineMilliseconds
                stages["vector.detail_read"] = vector.detailReadMilliseconds
                stages["vector.total"] = vector.totalMilliseconds
            }
        }
        for (stage, value) in extraStages { stages[stage] = value }
        stageMilliseconds = stages
        self.modelCallsAttempted = modelCallsAttempted
        self.modelCallsCompleted = modelCallsCompleted
        self.jevRequests = jevRequests
        self.jevErrors = jevErrors
        self.jevInputTokens = jevInputTokens
        self.jevOutputTokens = jevOutputTokens
        self.jevCostUSD = jevCostUSD
    }
}

private struct FairComparison: Encodable {
    let candidateLimit: Int
    let minimumCandidates: Int
    let excerptCharacters: Int
    let queryCount: Int
    let jev: SearchEvaluationReport
    let local8B: SearchEvaluationReport
}

private struct DecisionABComparison: Encodable {
    let candidateLimit: Int
    let excerptCharacters: Int
    let queryCount: Int
    let baseline: SearchEvaluationReport
    let jev: SearchEvaluationReport
    let clefFlash: SearchEvaluationReport
}

private struct PrecisionDraft {
    let semanticProfile: SemanticSearchProfile
    let gateway: LibrarySearchStageRecorder
    let fast: [FileHit]
    let candidates: [FileHit]
}

private enum SearchEvaluationPipeline {
    static func run(
        mode: SearchEvaluationMode, query: String, files: [IndexedFile], roots: [String],
        resultLimit: Int = 20
    ) async -> SearchEvaluationQueryResult {
        if mode == .hybrid && resultLimit == 30 {
            let gateway = LibrarySearchStageRecorder()
            guard SearchRouter.route(query).uses(.semantic) else {
                let lexical = LibraryGateway.search(query: query, in: files, limit: 30, recorder: gateway)
                return SearchEvaluationQueryResult(hits: lexical, semantic: nil, gateway: gateway,
                    modelCallsAttempted: 0, modelCallsCompleted: 0)
            }
            async let profile = LocalSemanticIndex.shared.searchProfiled(
                query: query, roots: roots, minScore: LocalRerank.precisionWideMinScore,
                candidateLimit: files.count <= 200 && LocalSemanticIndex.usesGemma ? 1000 : nil)
            let lexical = LibraryGateway.searchCandidates(query: query, in: files).map(\.hit)
            let semantic = await profile
            let hybrid = LibraryGateway.search(query: query, in: files, semantic: semantic.results,
                limit: 30, recorder: gateway)
            return SearchEvaluationQueryResult(
                hits: Array(SearchResultMerge.merge(lexical: lexical, semantic: hybrid).prefix(30)),
                semantic: semantic, gateway: gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0)
        }
        let semanticProfile = mode.usesSemantic
            ? await LocalSemanticIndex.shared.searchProfiled(query: query, roots: roots)
            : nil
        let semantic = semanticProfile?.results ?? []
        let gateway = LibrarySearchStageRecorder()
        let fast = LibraryGateway.search(
            query: query, in: files, semantic: semantic,
            limit: mode == .jev || mode == .bge ? JevRerank.candidateLimit : resultLimit,
            recorder: gateway
        )
        if mode.usesModel, !SearchRouter.route(query).uses(.modelPlan) {
            return SearchEvaluationQueryResult(
                hits: fast, semantic: semanticProfile, gateway: gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0
            )
        }
        switch mode {
        case .fast, .hybrid:
            return SearchEvaluationQueryResult(
                hits: fast, semantic: semanticProfile, gateway: gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0
            )
        case .planned:
            return await planned(
                query: query, files: files, roots: roots, semantic: semantic,
                semanticProfile: semanticProfile, gateway: gateway, fast: fast
            )
        case .precision:
            return await precision(
                query: query, files: files, roots: roots, semantic: semantic,
                semanticProfile: semanticProfile, gateway: gateway, fast: fast
            )
        case .jev:
            return await jev(
                query: query, files: files, semanticProfile: semanticProfile,
                gateway: gateway, fast: fast
            )
        case .bge:
            return await bge(
                query: query, files: files, semanticProfile: semanticProfile,
                gateway: gateway, fast: fast
            )
        case .fair, .local, .decisionAB:
            return SearchEvaluationQueryResult(
                hits: fast, semantic: semanticProfile, gateway: gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0
            )
        }
    }

    private static func jev(
        query: String, files: [IndexedFile], semanticProfile: SemanticSearchProfile?,
        gateway: LibrarySearchStageRecorder, fast: [FileHit]
    ) async -> SearchEvaluationQueryResult {
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = await JevRerank.rerank(query: query, hits: fast, files: files)
        return SearchEvaluationQueryResult(
            hits: outcome.hits, semantic: semanticProfile, gateway: gateway,
            modelCallsAttempted: outcome.requests,
            modelCallsCompleted: outcome.requests - outcome.errors,
            extraStages: [
                "jev.total": (ProcessInfo.processInfo.systemUptime - started) * 1_000
            ],
            jevRequests: outcome.requests, jevErrors: outcome.errors,
            jevInputTokens: outcome.inputTokens, jevOutputTokens: outcome.outputTokens,
            jevCostUSD: outcome.costUSD
        )
    }

    private static func bge(
        query: String, files: [IndexedFile], semanticProfile: SemanticSearchProfile?,
        gateway: LibrarySearchStageRecorder, fast: [FileHit]
    ) async -> SearchEvaluationQueryResult {
        let started = ProcessInfo.processInfo.systemUptime
        let ranked = await LocalBGERerank.rerank(query: query, hits: fast, files: files) ?? fast
        return SearchEvaluationQueryResult(
            hits: ranked, semantic: semanticProfile, gateway: gateway,
            modelCallsAttempted: fast.isEmpty ? 0 : 1,
            modelCallsCompleted: fast.isEmpty ? 0 : 1,
            extraStages: [
                "bge.total": (ProcessInfo.processInfo.systemUptime - started) * 1_000
            ]
        )
    }

    private static func planned(
        query: String, files: [IndexedFile], roots: [String],
        semantic: [ChunkResult], semanticProfile: SemanticSearchProfile?,
        gateway: LibrarySearchStageRecorder, fast: [FileHit]
    ) async -> SearchEvaluationQueryResult {
        var attempted = 1
        var completed = 0
        guard let plan = await LocalRerank.plan(
            query: query, files: files, evidence: fast, round: 0
        ) else {
            return SearchEvaluationQueryResult(
                hits: fast, semantic: semanticProfile, gateway: gateway,
                modelCallsAttempted: attempted, modelCallsCompleted: completed
            )
        }
        completed += 1
        var hits = LocalRerank.mergePlan(ranked: plan.rankedPaths, current: fast)
        var expansionTerms = plan.retrievalTerms
        if fast.isEmpty && expansionTerms.isEmpty {
            attempted += 1
            expansionTerms = await LocalRerank.expandQuery(query)
            completed += 1
        }
        if !expansionTerms.isEmpty {
            let wide = await LocalSemanticIndex.shared.search(
                query: query, roots: roots, minScore: LocalRerank.wideMinScore
            )
            let expanded = LibraryGateway.fallbackCandidates(
                query: query, in: files, semantic: wide,
                expandedTerms: expansionTerms, limit: LocalRerank.precisionCandidateLimit
            )
            let existing = Set(fast.map(\.path))
            let novel = expanded.filter { !existing.contains($0.path) }
            if !novel.isEmpty {
                attempted += 1
                if let ranked = await LocalRerank.rank(
                    query: query, files: files, evidence: novel
                ) {
                    completed += 1
                    if !ranked.isEmpty {
                        hits = LocalRerank.merge(
                            ranked: ranked, precise: hits, widened: novel
                        )
                    }
                }
            }
        }
        return SearchEvaluationQueryResult(
            hits: hits, semantic: semanticProfile, gateway: gateway,
            modelCallsAttempted: attempted, modelCallsCompleted: completed
        )
    }

    private static func precision(
        query: String, files: [IndexedFile], roots: [String],
        semantic: [ChunkResult], semanticProfile: SemanticSearchProfile?,
        gateway: LibrarySearchStageRecorder, fast: [FileHit]
    ) async -> SearchEvaluationQueryResult {
        let wide = await LocalSemanticIndex.shared.search(
            query: query, roots: roots, minScore: LocalRerank.precisionWideMinScore
        )
        let initial = LibraryGateway.fallbackCandidates(
            query: query, in: files, semantic: wide,
            limit: LocalRerank.precisionCandidateLimit
        )
        var candidates = precisionPool(
            current: fast, widened: initial, limit: LocalRerank.precisionCandidateLimit
        )
        guard !candidates.isEmpty else {
            return SearchEvaluationQueryResult(
                hits: fast, semantic: semanticProfile, gateway: gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0
            )
        }

        var budget = ProgressiveSearchBudget(maxRounds: 1, timeout: 20)
        var confirmed: [String] = []
        var reviewed = Set<String>()
        var expansionTerms: [String] = []
        var attempted = 0
        var completed = 0
        while let round = budget.beginNextRound() {
            let unread = candidates.filter { !reviewed.contains($0.path) }
            let evidence = Array((unread.isEmpty ? candidates : unread).prefix(16))
            evidence.forEach { reviewed.insert($0.path) }
            attempted += 1
            guard let plan = await LocalRerank.plan(
                query: query, files: files, evidence: evidence, round: round,
                timeoutSeconds: 24
            ) else { break }
            completed += 1
            for path in plan.rankedPaths where !confirmed.contains(path) {
                confirmed.append(path)
            }
            for term in plan.retrievalTerms where !expansionTerms.contains(term) {
                expansionTerms.append(term)
            }
            if plan.done || expansionTerms.isEmpty || round == 3 { break }
            let expanded = LibraryGateway.fallbackCandidates(
                query: query, in: files, semantic: wide,
                expandedTerms: expansionTerms, limit: LocalRerank.precisionCandidateLimit
            )
            let before = candidates.count
            candidates = deduplicated(candidates + expanded)
            if candidates.count == before { break }
        }
        let hits = confirmed.isEmpty ? fast : LocalRerank.mergePrecision(
            ranked: confirmed, current: fast, candidates: candidates
        )
        return SearchEvaluationQueryResult(
            hits: hits, semantic: semanticProfile, gateway: gateway,
            modelCallsAttempted: attempted, modelCallsCompleted: completed
        )
    }

    fileprivate static func preparePrecision(
        query: String, files: [IndexedFile], roots: [String]
    ) async -> PrecisionDraft {
        let semanticProfile = await LocalSemanticIndex.shared.searchProfiled(query: query, roots: roots)
        let gateway = LibrarySearchStageRecorder()
        let fast = LibraryGateway.search(
            query: query, in: files, semantic: semanticProfile.results, limit: 20, recorder: gateway
        )
        let wide = await LocalSemanticIndex.shared.search(
            query: query, roots: roots, minScore: LocalRerank.precisionWideMinScore
        )
        let initial = LibraryGateway.fallbackCandidates(
            query: query, in: files, semantic: wide, limit: LocalRerank.precisionCandidateLimit
        )
        let candidates = precisionPool(
            current: fast, widened: initial, limit: LocalRerank.precisionCandidateLimit
        )
        return PrecisionDraft(
            semanticProfile: semanticProfile, gateway: gateway, fast: fast, candidates: candidates
        )
    }

    /// One 8B read of an already retrieved pool. The embedding model is unloaded before this runs.
    fileprivate static func judgePrecision(
        query: String, files: [IndexedFile], draft: PrecisionDraft
    ) async -> SearchEvaluationQueryResult {
        guard !draft.candidates.isEmpty else {
            return SearchEvaluationQueryResult(
                hits: draft.fast, semantic: draft.semanticProfile, gateway: draft.gateway,
                modelCallsAttempted: 0, modelCallsCompleted: 0
            )
        }
        let evidence = Array(draft.candidates.prefix(16))
        guard let plan = await LocalRerank.plan(
            query: query, files: files, evidence: evidence, round: 1,
            timeoutSeconds: 45, retainModel: true
        ) else {
            return SearchEvaluationQueryResult(
                hits: draft.fast, semantic: draft.semanticProfile, gateway: draft.gateway,
                modelCallsAttempted: 1, modelCallsCompleted: 0
            )
        }
        let hits = plan.rankedPaths.isEmpty ? draft.fast : LocalRerank.mergePrecision(
            ranked: plan.rankedPaths, current: draft.fast, candidates: draft.candidates
        )
        return SearchEvaluationQueryResult(
            hits: hits, semantic: draft.semanticProfile, gateway: draft.gateway,
            modelCallsAttempted: 1, modelCallsCompleted: 1
        )
    }

    private static func precisionPool(
        current: [FileHit], widened: [FileHit], limit: Int
    ) -> [FileHit] {
        var seen = Set<String>()
        var pool: [FileHit] = []
        for hit in current.prefix(min(current.count, 12))
        where seen.insert(hit.path).inserted {
            pool.append(hit)
        }
        for hit in widened where seen.insert(hit.path).inserted {
            pool.append(hit)
            if pool.count >= limit { break }
        }
        return pool
    }

    private static func deduplicated(_ hits: [FileHit]) -> [FileHit] {
        var seen = Set<String>()
        return hits.filter { seen.insert($0.path).inserted }
    }

    /// Same retrieval as Jev mode, then one local 8B ordering of each list.
    /// The context window is wide enough for the 800-character excerpts Jev reads.
    fileprivate static func runLocal(
        suite: SearchEvaluationSuite, files: [IndexedFile], roots: [String]
    ) async -> SearchEvaluationReport {
        let excerpt = JevRerank.textLimit
        var drafts: [(SearchEvaluationCase, SemanticSearchProfile, LibrarySearchStageRecorder, [FileHit], Double)] = []
        for (offset, test) in suite.cases.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            let semantic = await LocalSemanticIndex.shared.searchProfiled(query: test.query, roots: roots)
            let gateway = LibrarySearchStageRecorder()
            let hits = LibraryGateway.search(
                query: test.query, in: files, semantic: semantic.results,
                limit: JevRerank.candidateLimit, recorder: gateway
            )
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            drafts.append((test, semantic, gateway, hits, elapsed))
            fputs(
                String(format: "recall %d/%d %@ %.0fms candidates %d\n",
                       offset + 1, suite.cases.count, test.id, elapsed, hits.count),
                stderr
            )
            fflush(stderr)
        }
        fputs("unloading embedding model; 8B ordering \(drafts.count) lists\n", stderr)
        fflush(stderr)
        await LocalSemanticIndex.shared.unload()
        var results: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        for (offset, draft) in drafts.enumerated() {
            let (test, semantic, gateway, hits, retrieveMs) = draft
            let started = ProcessInfo.processInfo.systemUptime
            let ordered = hits.isEmpty ? nil : await LocalRerank.orderAll(
                query: test.query, files: files, hits: hits, excerptLimit: excerpt,
                contextTokens: 24576
            )
            let modelMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let named = ordered?.named ?? 0
            results.append((test, SearchEvaluationQueryResult(
                hits: ordered?.hits ?? hits, semantic: semantic, gateway: gateway,
                modelCallsAttempted: hits.isEmpty ? 0 : 1,
                modelCallsCompleted: ordered == nil ? 0 : 1,
                extraStages: ["local8b.total": modelMs]
            ), retrieveMs + modelMs))
            fputs(
                String(format: "[%d/%d] %@ 8b %.0fms named %d/%d\n",
                       offset + 1, drafts.count, test.id, modelMs, named, hits.count),
                stderr
            )
            fflush(stderr)
        }
        await LocalQuickScan.shared.unload()
        return SearchEvaluation.report(suite: suite, mode: "local-8b", results: results)
    }

    fileprivate static func runFair(
        suite: SearchEvaluationSuite, files: [IndexedFile], roots: [String]
    ) async -> FairComparison {
        let excerpt = 120
        var drafts: [(SearchEvaluationCase, SemanticSearchProfile, LibrarySearchStageRecorder, [FileHit], Double)] = []
        for (offset, test) in suite.cases.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            let semantic = await LocalSemanticIndex.shared.searchProfiled(query: test.query, roots: roots)
            let gateway = LibrarySearchStageRecorder()
            let hits = LibraryGateway.search(
                query: test.query, in: files, semantic: semantic.results,
                limit: JevRerank.candidateLimit, recorder: gateway
            )
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            if hits.count >= 5 {
                drafts.append((test, semantic, gateway, hits, elapsed))
            }
            fputs(
                String(format: "recall %d/%d %@ %.0fms candidates %d\n",
                       offset + 1, suite.cases.count, test.id, elapsed, hits.count),
                stderr
            )
            fflush(stderr)
        }
        let skip8B = ProcessInfo.processInfo.environment["AIE_FAIR_SKIP_8B"] == "1"
        fputs("unloading embedding model; ranking \(drafts.count) lists\n", stderr)
        fflush(stderr)
        await LocalSemanticIndex.shared.unload()
        let compared = SearchEvaluationSuite(
            version: suite.version, includeSemantic: suite.includeSemantic,
            cases: drafts.map(\.0)
        )
        var jevResults: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        var localResults: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        for (offset, draft) in drafts.enumerated() {
            let (test, semantic, gateway, hits, retrieveMs) = draft
            let jevStarted = ProcessInfo.processInfo.systemUptime
            let jevOutcome = await JevRerank.rerank(
                query: test.query, hits: hits, files: files, excerptLimit: excerpt
            )
            let jevMs = retrieveMs + (ProcessInfo.processInfo.systemUptime - jevStarted) * 1000
            jevResults.append((test, SearchEvaluationQueryResult(
                hits: jevOutcome.hits, semantic: semantic, gateway: gateway,
                modelCallsAttempted: jevOutcome.requests,
                modelCallsCompleted: jevOutcome.requests - jevOutcome.errors,
                extraStages: ["jev.total": (ProcessInfo.processInfo.systemUptime - jevStarted) * 1000],
                jevRequests: jevOutcome.requests, jevErrors: jevOutcome.errors,
                jevInputTokens: jevOutcome.inputTokens, jevOutputTokens: jevOutcome.outputTokens,
                jevCostUSD: jevOutcome.costUSD
            ), jevMs))
            var named = 0
            var localMs = retrieveMs
            if skip8B {
                localResults.append((test, SearchEvaluationQueryResult(
                    hits: hits, semantic: semantic, gateway: gateway,
                    modelCallsAttempted: 0, modelCallsCompleted: 0
                ), retrieveMs))
            } else {
                let localStarted = ProcessInfo.processInfo.systemUptime
                let ordered = await LocalRerank.orderAll(
                    query: test.query, files: files, hits: hits, excerptLimit: excerpt
                )
                localMs = retrieveMs + (ProcessInfo.processInfo.systemUptime - localStarted) * 1000
                named = ordered?.named ?? 0
                localResults.append((test, SearchEvaluationQueryResult(
                    hits: ordered?.hits ?? hits, semantic: semantic, gateway: gateway,
                    modelCallsAttempted: 1, modelCallsCompleted: ordered == nil ? 0 : 1
                ), localMs))
            }
            fputs(
                String(format: "[%d/%d] %@ jev %.0fms 8b %.0fms named %d/%d\n",
                       offset + 1, drafts.count, test.id, jevMs, localMs,
                       named, hits.count),
                stderr
            )
            fflush(stderr)
            if JevRerank.authorizationFailed {
                fputs((JevRerank.lastError ?? "OpenRouter rejected the key") + "\n", stderr)
                break
            }
        }
        await LocalQuickScan.shared.unload()
        return FairComparison(
            candidateLimit: JevRerank.candidateLimit,
            minimumCandidates: 5,
            excerptCharacters: excerpt,
            queryCount: drafts.count,
            jev: SearchEvaluation.report(
                suite: compared,
                mode: JevRerank.usesLocalEndpoint ? "openjev-2b" : "fair-jev",
                results: jevResults
            ),
            local8B: SearchEvaluation.report(
                suite: compared, mode: skip8B ? "not-run" : "fair-8b", results: localResults
            )
        )
    }

    fileprivate static func runDecisionAB(
        suite: SearchEvaluationSuite, files: [IndexedFile], roots: [String]
    ) async -> DecisionABComparison {
        let candidateLimit = 10
        let excerpt = JevRerank.textLimit
        var drafts: [(
            SearchEvaluationCase, SemanticSearchProfile,
            LibrarySearchStageRecorder, [FileHit], Double
        )] = []
        for (offset, test) in suite.cases.enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            let semantic = await LocalSemanticIndex.shared.searchProfiled(
                query: test.query, roots: roots
            )
            let gateway = LibrarySearchStageRecorder()
            let hits = LibraryGateway.search(
                query: test.query, in: files, semantic: semantic.results,
                limit: candidateLimit, recorder: gateway
            )
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            drafts.append((test, semantic, gateway, hits, elapsed))
            fputs(
                String(
                    format: "recall %d/%d %@ %.0fms candidates %d\n",
                    offset + 1, suite.cases.count, test.id, elapsed, hits.count
                ),
                stderr
            )
            fflush(stderr)
        }
        await LocalSemanticIndex.shared.unload()

        var baselineResults: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        var jevResults: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        var clefResults: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
        for (offset, draft) in drafts.enumerated() {
            let (test, semantic, gateway, hits, retrieveMs) = draft
            baselineResults.append((
                test,
                SearchEvaluationQueryResult(
                    hits: hits, semantic: semantic, gateway: gateway,
                    modelCallsAttempted: 0, modelCallsCompleted: 0
                ),
                retrieveMs
            ))

            let jevStarted = ProcessInfo.processInfo.systemUptime
            let jevOutcome = await JevRerank.rerank(
                query: test.query, hits: hits, files: files, excerptLimit: excerpt
            )
            let jevModelMs = (ProcessInfo.processInfo.systemUptime - jevStarted) * 1_000
            jevResults.append((
                test,
                SearchEvaluationQueryResult(
                    hits: jevOutcome.hits, semantic: semantic, gateway: gateway,
                    modelCallsAttempted: jevOutcome.requests,
                    modelCallsCompleted: jevOutcome.requests - jevOutcome.errors,
                    extraStages: ["jev.total": jevModelMs],
                    jevRequests: jevOutcome.requests, jevErrors: jevOutcome.errors,
                    jevInputTokens: jevOutcome.inputTokens,
                    jevOutputTokens: jevOutcome.outputTokens,
                    jevCostUSD: jevOutcome.costUSD
                ),
                retrieveMs + jevModelMs
            ))

            let clefStarted = ProcessInfo.processInfo.systemUptime
            let clefOutcome = await ClefRerank.rerank(
                query: test.query, hits: hits, files: files,
                limit: candidateLimit, excerptLimit: excerpt
            )
            let clefModelMs = (ProcessInfo.processInfo.systemUptime - clefStarted) * 1_000
            clefResults.append((
                test,
                SearchEvaluationQueryResult(
                    hits: clefOutcome.hits, semantic: semantic, gateway: gateway,
                    modelCallsAttempted: clefOutcome.requests,
                    modelCallsCompleted: clefOutcome.requests - clefOutcome.errors,
                    extraStages: ["clef.total": clefModelMs],
                    jevRequests: clefOutcome.requests, jevErrors: clefOutcome.errors,
                    jevInputTokens: clefOutcome.inputTokens,
                    jevOutputTokens: clefOutcome.outputTokens,
                    jevCostUSD: clefOutcome.costUSD
                ),
                retrieveMs + clefModelMs
            ))
            fputs(
                String(
                    format: "[%d/%d] %@ jev %.0fms clef %.0fms candidates %d\n",
                    offset + 1, drafts.count, test.id, jevModelMs, clefModelMs, hits.count
                ),
                stderr
            )
            fflush(stderr)
            if JevRerank.authorizationFailed || ClefRerank.authorizationFailed { break }
        }
        return DecisionABComparison(
            candidateLimit: candidateLimit,
            excerptCharacters: excerpt,
            queryCount: drafts.count,
            baseline: SearchEvaluation.report(
                suite: suite, mode: "decision-ab-baseline", results: baselineResults
            ),
            jev: SearchEvaluation.report(
                suite: suite, mode: "decision-ab-jev", results: jevResults
            ),
            clefFlash: SearchEvaluation.report(
                suite: suite, mode: "decision-ab-clef-flash", results: clefResults
            )
        )
    }
}

private enum SearchEnhancementComparison {
    @MainActor static func run(suite: SearchEvaluationSuite, files: [IndexedFile], roots: [URL]) async throws -> [[String: Any]] {
        guard AIEApplicationPaths.isCleanV2, ArchitectureAuditTrace.enabled, LocalBGERerank.isAvailable else {
            throw DataLayerError.invalidDocument("Enhancement comparison requires audit timing and the existing local BGE runtime")
        }
        try await LocalSemanticIndex.shared.prepareSearch(roots: roots.map(\.path))
        await LocalSemanticIndex.shared.warmUp()
        guard let file = files.first else { throw DataLayerError.invalidDocument("Empty indexed snapshot") }
        let warmHit = FileHit(path: file.path, name: file.name, relative: file.relative, kind: file.kind,
            ext: file.ext, mtime: file.mtime, reason: "warmup", score: 0,
            snippet: String(file.preview.prefix(800)), highlights: [], thumbPath: file.thumbPath,
            uploadedToCloud: file.uploadedToCloud)
        fputs("Warming existing local BGE model (excluded from measurements)\n", stderr)
        guard await LocalBGERerank.rerank(query: "预热", hits: [warmHit], files: files,
            candidateLimit: 1, timeout: 60) != nil else {
            throw DataLayerError.invalidDocument("Existing local BGE model failed to warm up")
        }
        let model = SearchModel(indexedFiles: files, roots: roots)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 620, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "AIE · 只读搜索评估"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SearchPanelView(model: model, onDismiss: {}))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let fileIDs = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.fileID.map { (file.path, $0) } })
        func rankedRows(_ hits: [FileHit]) -> [[String: Any]] {
            hits.enumerated().map { ["rank": $0.offset + 1, "fileID": fileIDs[$0.element.path] ?? "",
                "path": $0.element.path, "chunkID": $0.element.chunkID as Any? ?? NSNull(),
                "page": $0.element.page as Any? ?? NSNull(),
                "startSeconds": $0.element.startSeconds as Any? ?? NSNull()] }
        }
        var rows: [[String: Any]] = []
        for round in 0..<3 {
            let orders = [[0, 3, 5, 10], [5, 10, 0, 3], [10, 3, 5, 0]]
            for test in suite.cases {
                for topN in orders[round] {
                    model.query = ""
                    try await Task.sleep(nanoseconds: 20_000_000)
                    UserDefaults.standard.setVolatileDomain([
                        ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
                        ScanConfiguration.pendingKey: false, "aie.scan.userPaused": true,
                        ScanConfiguration.deepPausedKey: true,
                        "aie.search.automaticRerank": topN > 0,
                        DeepScanSearchEnhancement.topNKey: topN,
                    ], forName: UserDefaults.argumentDomain)
                    var v1: [FileHit] = [], captured = false, sawFastSearch = false
                    let searching = model.$fastSearching.sink { if $0 { sawFastSearch = true } }
                    let observation = model.$hits.sink { hits in
                        if sawFastSearch, !captured, model.hasActiveQuery, !model.fastSearching, !model.reranking {
                            captured = true; v1 = hits
                        }
                    }
                    let previous = model.lastSearchTrace?.id
                    let started = ProcessInfo.processInfo.systemUptime
                    model.query = test.query
                    while model.searchInProgress || model.lastSearchTrace?.id == previous {
                        guard ProcessInfo.processInfo.systemUptime - started < 35 else {
                            model.query = ""; observation.cancel(); searching.cancel()
                            throw DataLayerError.invalidDocument("UI evaluation timed out: " + test.id)
                        }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    observation.cancel()
                    searching.cancel()
                    try await Task.sleep(nanoseconds: 35_000_000)
                    guard captured, let trace = model.lastSearchTrace else {
                        throw DataLayerError.invalidDocument("Missing V1 publication: " + test.id)
                    }
                    rows.append(["round": round + 1, "id": test.id, "query": test.query, "topN": topN,
                        "traceID": trace.id.uuidString, "v1": rankedRows(v1), "final": rankedRows(model.hits),
                        "trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace))])
                    fputs("[\(rows.count)/\(suite.cases.count * 12)] round \(round + 1) \(test.id) Top\(topN) done\n", stderr)
                    fflush(stderr)
                }
            }
        }
        model.query = ""
        // Exercise timeout rejection without starting a worker or publishing an alternative order.
        guard await LocalBGERerank.rerank(query: "timeout check", hits: [warmHit], files: files,
            candidateLimit: 1, timeout: 0) == nil else {
            throw DataLayerError.invalidDocument("BGE accepted an expired deadline")
        }
        await LocalGemmaWorker.shared.stop()
        ArchitectureAuditTrace.flush()
        return rows
    }
}

enum SearchEvaluationDiagnostics {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        let readOnly = arguments.dropFirst().first == "--evaluate-search-readonly"
        guard readOnly || arguments.dropFirst().first == "--evaluate-search" else { return false }
        guard ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"] != nil else {
            fputs(readOnly ? "Set AIE_DATABASE_PATH to the existing database for read-only evaluation.\n"
                : "Search evaluation requires an isolated AIE_DATABASE_PATH; use tools/evaluate_search.sh.\n", stderr)
            exit(2)
        }
        guard (3...4).contains(arguments.count) else {
            fputs(
                readOnly ? "usage: AIEPopup --evaluate-search-readonly SUITE [fast|hybrid|deepscan|enhancement|check-only]\n"
                    : "usage: AIEPopup --evaluate-search /path/to/search-evaluation.json "
                        + "[fast|hybrid|planned|precision|jev|fair|local|decision-ab]\n",
                stderr
            )
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[2])
        let suite: SearchEvaluationSuite
        do {
            suite = try JSONDecoder().decode(
                SearchEvaluationSuite.self, from: Data(contentsOf: url)
            )
            guard suite.version == 1, !suite.cases.isEmpty else {
                throw CocoaError(.coderInvalidValue)
            }
        } catch {
            fputs("Unable to read search evaluation suite: \(error)\n", stderr)
            exit(2)
        }
        let defaultMode: SearchEvaluationMode = suite.includeSemantic ? .hybrid : .fast
        let initializeOnly = readOnly && arguments.count == 4 && arguments[3] == "check-only"
        let deepScanOnly = readOnly && arguments.count == 4 && arguments[3] == "deepscan"
        let enhancementComparison = readOnly && arguments.count == 4 && arguments[3] == "enhancement"
        let mode: SearchEvaluationMode
        if initializeOnly || deepScanOnly || enhancementComparison {
            mode = .fast
        } else if arguments.count == 4 {
            guard let requested = SearchEvaluationMode(rawValue: arguments[3]) else {
                fputs("Unknown search evaluation mode: \(arguments[3])\n", stderr)
                exit(2)
            }
            mode = requested
        } else {
            mode = defaultMode
        }
        if readOnly && mode != .fast && mode != .hybrid {
            fputs("Read-only evaluation supports fast, hybrid or check-only; model rerank modes are not enabled.\n", stderr)
            exit(2)
        }
        if mode.usesModel, !LocalRerank.isAvailable {
            fputs("The local 8B model is unavailable; install or enable it before evaluation\n", stderr)
            exit(2)
        }
        if mode.usesJev, !JevRerank.hasKey, !JevRerank.usesLocalEndpoint {
            fputs("Save an OpenRouter API key before jev evaluation. Only retrieved chunk excerpts are sent.\n", stderr)
            exit(2)
        }
        if mode.usesClef, !ClefRerank.hasCredentials {
            fputs(
                "Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN before Clef evaluation. "
                    + "Only the same retrieved chunk excerpts sent to Jev are sent to Clef.\n",
                stderr
            )
            exit(2)
        }

        let roots: [URL]
        if readOnly, let value = ProcessInfo.processInfo.environment["AIE_EVALUATION_ROOTS"] {
            do {
                roots = try JSONDecoder().decode([String].self, from: Data(value.utf8))
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
            } catch {
                fputs("Invalid read-only evaluation roots: \(error)\n", stderr)
                exit(2)
            }
        } else if let path = ProcessInfo.processInfo.environment["AIE_LIBRARY_ROOT"], !path.isEmpty {
            roots = [URL(fileURLWithPath: path, isDirectory: true)]
        } else {
            roots = LibraryRoots.load()
        }
        guard !roots.isEmpty else {
            fputs("No library root configured; set AIE_LIBRARY_ROOT for CLI evaluation\n", stderr)
            exit(2)
        }
        Task { @MainActor in
            let files: [IndexedFile]
            if readOnly {
                do {
                    let database = try AppDatabase.open(readOnly: true)
                    try database.verifyReadOnlyAccess()
                    files = try LibraryGateway.loadIndexedSnapshot(roots: roots)
                    if initializeOnly {
                        let report: [String: Any] = [
                            "readOnly": database.isReadOnly, "writeRejected": true,
                            "writeProbeResult": "SQLITE_READONLY", "files": files.count,
                            "fileIDsPresent": files.allSatisfy { $0.fileID != nil && $0.versionID != nil },
                            "chunks": files.reduce(0) { $0 + $1.chunks.count },
                            "suiteCases": suite.cases.count, "queriesExecuted": 0,
                            "gemmaAvailable": LocalGemmaWorker.isAvailable,
                            "resourcePath": Bundle.main.resourceURL?.path ?? "",
                        ]
                        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                        exit(0)
                    }
                    if (mode.usesSemantic || deepScanOnly || enhancementComparison) && !LocalGemmaWorker.isAvailable {
                        fputs("Read-only semantic evaluation requires the existing Gemma model; no installation was started.\n", stderr)
                        exit(2)
                    }
                } catch {
                    fputs("Read-only evaluation initialization failed: \(error)\n", stderr)
                    exit(1)
                }
            } else {
                files = LibraryGateway.load(roots: roots)
            }
            if let error = LibraryGateway.lastError {
                fputs(error + "\n", stderr)
                exit(1)
            }
            if enhancementComparison {
                do {
                    let rows = try await SearchEnhancementComparison.run(suite: suite, files: files, roots: roots)
                    print(String(decoding: try JSONSerialization.data(withJSONObject:
                        ["readOnly": true, "rounds": 3, "cases": rows],
                        options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                    exit(0)
                } catch {
                    fputs("Read-only enhancement comparison failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            if mode.usesSemantic || deepScanOnly {
                try? await LocalSemanticIndex.shared.prepareSearch(roots: roots.map(\.path))
            }
            if deepScanOnly {
                do {
                    var results: [[String: Any]] = []
                    for test in suite.cases {
                        let started = ProcessInfo.processInfo.systemUptime
                        let hits = try await LocalSemanticIndex.shared.searchDeepScan(
                            query: test.query, roots: roots.map(\.path), topK: 30, readOnly: true)
                        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                        results.append([
                            "id": test.id, "query": test.query, "milliseconds": milliseconds,
                            "top30": hits.enumerated().map { item -> [String: Any] in
                                ["rank": item.offset + 1, "fileID": item.element.fileID,
                                 "path": item.element.path, "score": item.element.score]
                            },
                        ])
                    }
                    await LocalGemmaWorker.shared.stop()
                    let report: [String: Any] = ["mode": "deepscan", "readOnly": true,
                        "caseCount": results.count, "cases": results]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: report,
                        options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                    exit(0)
                } catch {
                    await LocalGemmaWorker.shared.stop()
                    fputs("Read-only DeepScan evaluation failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            if mode == .local {
                let report = await SearchEvaluationPipeline.runLocal(
                    suite: suite, files: files, roots: roots.map(\.path)
                )
                do {
                    let data = try JSONEncoder.sorted.encode(report)
                    print(String(decoding: data, as: UTF8.self))
                    exit(report.passed ? 0 : 1)
                } catch {
                    fputs("Unable to encode local rerank report: \(error)\n", stderr)
                    exit(1)
                }
            }
            if mode == .fair {
                let comparison = await SearchEvaluationPipeline.runFair(
                    suite: suite, files: files, roots: roots.map(\.path)
                )
                do {
                    let data = try JSONEncoder.sorted.encode(comparison)
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                } catch {
                    fputs("Unable to encode fair comparison: \(error)\n", stderr)
                    exit(1)
                }
            }
            if mode == .decisionAB {
                let comparison = await SearchEvaluationPipeline.runDecisionAB(
                    suite: suite, files: files, roots: roots.map(\.path)
                )
                do {
                    let data = try JSONEncoder.sorted.encode(comparison)
                    print(String(decoding: data, as: UTF8.self))
                    exit(
                        JevRerank.authorizationFailed || ClefRerank.authorizationFailed
                            ? 2 : 0
                    )
                } catch {
                    fputs("Unable to encode Clef/Jev comparison: \(error)\n", stderr)
                    exit(1)
                }
            }
            var results: [(SearchEvaluationCase, SearchEvaluationQueryResult, Double)] = []
            if mode == .precision {
                var drafts: [(SearchEvaluationCase, PrecisionDraft, Double)] = []
                for test in suite.cases {
                    let started = ProcessInfo.processInfo.systemUptime
                    let draft = await SearchEvaluationPipeline.preparePrecision(
                        query: test.query, files: files, roots: roots.map(\.path)
                    )
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    drafts.append((test, draft, elapsed))
                    fputs(
                        String(format: "recall %d/%d %@ %.0fms candidates %d\n",
                               drafts.count, suite.cases.count, test.id, elapsed, draft.candidates.count),
                        stderr
                    )
                    fflush(stderr)
                }
                fputs("unloading embedding model before 8B\n", stderr)
                fflush(stderr)
                await LocalSemanticIndex.shared.stopAndUnload()
                for (offset, item) in drafts.enumerated() {
                    let (test, draft, retrieveMs) = item
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = await SearchEvaluationPipeline.judgePrecision(
                        query: test.query, files: files, draft: draft
                    )
                    let elapsed = retrieveMs + (ProcessInfo.processInfo.systemUptime - started) * 1000
                    results.append((test, result, elapsed))
                    fputs(
                        String(format: "[%d/%d] %@ %.0fms model %d/%d\n",
                               offset + 1, drafts.count, test.id, elapsed,
                               result.modelCallsCompleted, result.modelCallsAttempted),
                        stderr
                    )
                    fflush(stderr)
                }
                await LocalQuickScan.shared.unload()
            } else {
                for test in suite.cases {
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = await SearchEvaluationPipeline.run(
                        mode: mode, query: test.query, files: files, roots: roots.map(\.path),
                        resultLimit: readOnly ? 30 : 20
                    )
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    results.append((test, result, elapsed))
                    if mode.usesJev {
                        fputs(
                            String(format: "[%d/%d] %@ %.0fms model %d/%d\n",
                                   results.count, suite.cases.count, test.id, elapsed,
                                   result.modelCallsCompleted, result.modelCallsAttempted),
                            stderr
                        )
                        fflush(stderr)
                    }
                    if mode.usesJev, JevRerank.authorizationFailed {
                        fputs((JevRerank.lastError ?? "Jev API rejected the key") + "\n", stderr)
                        exit(2)
                    }
                }
            }
            let report = SearchEvaluation.report(
                suite: suite, mode: mode.rawValue, results: results,
                fileIDsByPath: Dictionary(uniqueKeysWithValues: files.compactMap { file in
                    file.fileID.map { (file.path, $0) }
                })
            )
            do {
                let data = try JSONEncoder.sorted.encode(report)
                print(String(decoding: data, as: UTF8.self))
                exit(report.passed ? 0 : 1)
            } catch {
                fputs("Unable to encode search evaluation report: \(error)\n", stderr)
                exit(1)
            }
        }
        if enhancementComparison {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else {
            RunLoop.current.run()
        }
        return true
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
