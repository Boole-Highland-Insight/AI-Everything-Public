import Foundation

@main enum RerankChecks {
    static func main() {
        precondition(GroqRerank.parseIds(#"{"ids":[true,1.5,-1,0,1,10000,"1"]}"#, limit: 2) == [0,1])
        precondition(GroqRerank.parseIds(#"{"ids":[1e300]}"#, limit: 20).isEmpty)
        precondition(Set(JevRerank.questions().keys) == ["relevance", "evidence", "material"],
                     "Jev must ask all three product judgments")
        let rejected = JevRerank.parseJudgment([
            "relevance": ["noul": 0],
            "evidence": ["score": 2],
            "material": ["choice": "supporting_context"],
        ])
        precondition(rejected.map(JevRerank.isSeriouslyIrrelevant) == true,
                     "Jev direct relevance rejection must remove a possible candidate")
        var filename = FileHit(path: "/fixture/exact.pptx", name: "exact.pptx", relative: "exact.pptx", kind: .document, ext: "pptx",
            mtime: .distantPast, reason: "文件名", score: 30, snippet: "第 3 页 · 审批", highlights: [], thumbPath: nil,
            uploadedToCloud: false, chunkID: "page-3", page: 3)
        var content = FileHit(path: "/fixture/content.pptx", name: "content.pptx", relative: "content.pptx", kind: .document, ext: "pptx",
            mtime: .distantPast, reason: "全文", score: 20, snippet: "第 8 页 · 审批", highlights: [], thumbPath: nil,
            uploadedToCloud: false, chunkID: "page-8", page: 8)
        filename.confidenceTier = .direct
        filename.evidence = [.init(source: .filename, strength: 1, chunkID: nil, page: nil)]
        content.confidenceTier = .possible
        let semanticOnly = FileHit(path: "/fixture/semantic.pdf", name: "semantic.pdf", relative: "semantic.pdf",
            kind: .document, ext: "pdf", mtime: .distantPast, reason: "语义", score: 20,
            snippet: "第 63 页 · 记忆模块", highlights: [], thumbPath: nil, uploadedToCloud: false,
            chunkID: "page-63", page: 63)
        let combined = SearchResultMerge.merge(lexical: [filename, content], semantic: [content, semanticOnly])
        precondition(combined.map(\.path) == [content.path, semanticOnly.path, filename.path],
                     "Semantic result was lost when lexical retrieval completed last")
        precondition(SearchResultMerge.merge(lexical: [], semantic: [content, semanticOnly]) == [content, semanticOnly],
                     "Semantic-only results were lost")
        let merged = GroqRerank.merge(ranked: ["/outside/secret", content.path, content.path], local: [filename,content], files: [], query: "审批")
        precondition(merged == [filename, content], "Reranker replaced evidence, displaced filename or introduced an un-retrieved file")
        precondition(GroqRerank.merge(ranked: [], local: [filename,content], files: [], query: "审批") == [filename,content])
        let tiered = SearchTiering.mergeModelOrder(rankedPaths: [content.path, filename.path], current: [filename, content])
        precondition(tiered.map(\.path) == [filename.path, content.path], "Model ordering crossed confidence tiers")
        precondition(tiered[1].confidenceTier == .possible)
        precondition(tiered[1].evidence.contains { $0.source == .modelVerified })
        let trace = SearchTraceSession()
        _ = trace.measure("fixture", operation: { [filename, content] }, candidates: \.count)
        let report = trace.finish(hits: tiered)
        precondition(report.resultCount == 2 && report.directCount == 1 && report.stages.count == 1)
        let routedTrace = SearchTraceSession()
        routedTrace.recordRouting(SearchRouter.route("湖边照片"))
        let routedReport = routedTrace.finish(hits: [])
        precondition(routedReport.queryKind == .content
                     && Set(routedReport.routes) == [.lexical, .semantic, .modelPlan])
        precondition(SearchRouter.route("844209").kind == .identifier)
        precondition(SearchRouter.route("report_final_v3.pdf").kind == .locator)
        precondition(SearchRouter.route("体温 39.2 度的截图").uses(.semantic))
        precondition(LibraryIndex.compile("汽油量 6.7 加仑").ext == nil)
        precondition(SearchRouter.route("LLM 模型名 .env.local").uses(.semantic))
        precondition(LibraryIndex.compile("LLM 模型名 .env.local").ext == nil)
        precondition(SearchRouter.route("所有图片").kind == .browse)
        precondition(!SearchRouter.route("844209").uses(.semantic)
                     && !SearchRouter.route("report_final_v3.pdf").uses(.modelPlan),
                     "Identifiers or explicit locators entered expensive semantic/model routes")
        let current = SearchRequestVersion(generation: 7, query: " 湖边照片 ")
        precondition(current.matches(generation: 7, query: "湖边照片"))
        precondition(!current.matches(generation: 8, query: "湖边照片"))
        precondition(!current.matches(generation: 7, query: "湖边视频"))
        let cacheA = SearchPlanCacheKey(
            model: "8b-a", schemaVersion: "2", query: " 湖边照片 ", round: 0, evidence: [filename])
        let cacheB = SearchPlanCacheKey(
            model: "8b-a", schemaVersion: "2", query: "湖边照片", round: 0, evidence: [filename])
        let cacheNewModel = SearchPlanCacheKey(
            model: "8b-b", schemaVersion: "2", query: "湖边照片", round: 0, evidence: [filename])
        let cacheNewEvidence = SearchPlanCacheKey(
            model: "8b-a", schemaVersion: "2", query: "湖边照片", round: 0, evidence: [content])
        precondition(cacheA == cacheB, "Normalized repeated query missed its plan cache")
        precondition(cacheA != cacheNewModel && cacheA != cacheNewEvidence,
                     "Plan cache survived a model or evidence revision")
        var budget = ProgressiveSearchBudget(maxRounds: 3, timeout: 12, startedAt: 100)
        precondition(budget.beginNextRound(now: 100) == 1)
        precondition(budget.beginNextRound(now: 104) == 2)
        precondition(budget.beginNextRound(now: 108) == 3)
        precondition(budget.beginNextRound(now: 109) == nil, "Deep search exceeded three rounds")
        var expired = ProgressiveSearchBudget(maxRounds: 3, timeout: 12, startedAt: 100)
        precondition(expired.beginNextRound(now: 112) == nil, "Deep search ignored its hard deadline")
        precondition(Set(LibraryIndex.aliases(of: "伤疤")).isSuperset(of: ["伤痕", "疤痕"]),
                     "Scar synonyms must participate in fast retrieval")
        precondition(MediaOpenPolicy.shouldUseTimedPlayer(path: "/fixture/clip.MP4", startSeconds: 12))
        precondition(MediaOpenPolicy.shouldUseTimedPlayer(path: "/fixture/audio.m4a", startSeconds: -1))
        precondition(MediaOpenPolicy.seekSeconds(-1) == 0)
        precondition(!MediaOpenPolicy.shouldUseTimedPlayer(path: "/fixture/report.pdf", startSeconds: 12))
        precondition(!MediaOpenPolicy.shouldUseTimedPlayer(path: "/fixture/clip.mp4", startSeconds: nil))

        for term in ["猫", "狗", "车", "书", "山"] {
            let compiled = LibraryIndex.compile(term)
            precondition(compiled.tokens == [term] && compiled.anyOf.isEmpty,
                         "Meaningful single-character CJK query was discarded: \(term)")
            precondition(!compiled.allowsUnfilteredBrowse,
                         "Single-character CJK query became an unfiltered browse: \(term)")
        }
        for query in ["的", "帮我", "找一下"] {
            let compiled = LibraryIndex.compile(query)
            precondition(compiled.tokens.isEmpty && compiled.anyOf.isEmpty
                         && !compiled.allowsUnfilteredBrowse,
                         "Stop-word-only query became an unfiltered browse: \(query)")
        }
        for query in ["全部", "所有图片", "最近文件", ".pdf"] {
            precondition(LibraryIndex.compile(query).allowsUnfilteredBrowse,
                         "Explicit browse query was rejected: \(query)")
        }
        func fixture(_ name: String, _ text: String) -> IndexedFile {
            IndexedFile(
                path: "/fixture/" + name, name: name, relative: name, kind: .document,
                ext: "txt", mtime: .distantPast, haystack: text, preview: text,
                thumbPath: nil, rootPath: "/fixture", size: text.utf8.count,
                hasBarcode: false, isScreenshot: false, llmLine: text, llmCard: text,
                uploadedToCloud: false
            )
        }
        let cat = fixture("cat.txt", "画面中有一只小猫")
        let mountain = fixture("mountain.txt", "山中雾气还没有散去")
        let candidate = SearchCandidate(
            hit: filename, tier: filename.confidenceTier, evidence: filename.evidence,
            fileID: "file-a", versionID: "version-a", contentHash: "hash-a"
        )
        var currentFile = fixture("exact.pptx", "审批")
        currentFile.fileID = "file-a"
        currentFile.versionID = "version-a"
        currentFile.contentHash = "hash-a"
        precondition(candidate.matchedUnitID == "page-3" && candidate.isCurrent(in: currentFile))
        currentFile.versionID = "version-b"
        precondition(!candidate.isCurrent(in: currentFile), "Stale-version candidate remained current")
        precondition(LibraryIndex.search(query: "猫", in: [cat, mountain]).map(\.path) == [cat.path],
                     "Single-character search leaked unrelated files")
        precondition(LibraryIndex.search(query: "的", in: [cat, mountain]).isEmpty,
                     "Unsearchable non-browse query returned the whole library")
        precondition(LibraryIndex.search(query: "全部", in: [cat, mountain]).count == 2,
                     "Explicit unfiltered browse stopped working")

        print("Rerank checks passed: IDs, evidence tiers, generic CJK queries, explicit browse intent, privacy-safe trace, query versions, plan cache keys and three-round budget.")
    }
}
