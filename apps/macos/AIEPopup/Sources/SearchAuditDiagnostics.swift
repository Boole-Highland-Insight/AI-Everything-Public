import Foundation

/// Explicit local audit of selected roots. Refreshes their DB projection but starts no scanner/cloud requests.
enum SearchAuditDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        let uiAudit = args.dropFirst().first == "--audit-search-ui"
        guard args.dropFirst().first == "--audit-search" || uiAudit else { return false }
        guard args.count == 3 else { fputs("usage: AIEPopup --audit-search query\n", stderr); exit(2) }
        let roots = LibraryRoots.load()
        Task { @MainActor in
            let files = LibraryGateway.load(roots: roots)
            guard LibraryGateway.lastError == nil else { fputs("Unable to load content database\n", stderr); exit(1) }
            if uiAudit {
                guard !APIConfiguration.cloudRerankEnabled else { fputs("Disable cloud rerank for local UI audit\n", stderr); exit(2) }
                let model = SearchModel()
                model.files = files
                var longestTick = 0.0
                var previous = ProcessInfo.processInfo.systemUptime
                let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    longestTick = max(longestTick, now - previous)
                    previous = now
                }
                model.query = "过时查询"
                model.query = args[2]
                let start = ProcessInfo.processInfo.systemUptime
                while model.status == "正在搜索…", ProcessInfo.processInfo.systemUptime - start < 10 {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                let expected = LibraryGateway.search(query: args[2], in: files).map(\.path)
                let matched = model.hits.map(\.path) == expected
                timer.invalidate()
                model.query = ""
                let recent = model.hits.map(\.path)
                try? await Task.sleep(nanoseconds: 700_000_000)
                let passed = matched && model.query.isEmpty && model.hits.map(\.path) == recent
                let result: [String: Any] = ["passed": passed, "matchesSynchronousResults": matched,
                    "clearedQueryPreserved": model.hits.map(\.path) == recent, "maxMainTickMilliseconds": longestTick * 1000]
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(passed ? 0 : 1)
            }
            let searchStart = ProcessInfo.processInfo.systemUptime
            let lexicalCandidates = LibraryGateway.searchCandidates(query: args[2], in: files)
            let lexical = lexicalCandidates.map(\.hit)
            let lexicalMilliseconds = (ProcessInfo.processInfo.systemUptime - searchStart) * 1000
            let identifier = LibraryIndex.compile(args[2]).isIdentifierQuery
            if !identifier { try? await LocalSemanticIndex.shared.prepareSearch(roots: roots.map(\.path)) }
            let semanticStart = ProcessInfo.processInfo.systemUptime
            let semantic = identifier ? [] : await LocalSemanticIndex.shared.search(query: args[2], roots: roots.map(\.path))
            let semanticMilliseconds = (ProcessInfo.processInfo.systemUptime - semanticStart) * 1000
            let structured = LibraryGateway.searchCandidates(query: args[2], in: files, semantic: semantic)
            let hits = structured.map(\.hit)
            var localPlan: [String: Any] = ["available": LocalRerank.isAvailable]
            if LocalRerank.isAvailable, !identifier {
                let started = ProcessInfo.processInfo.systemUptime
                if let plan = await LocalRerank.plan(query: args[2], files: files, evidence: hits) {
                    localPlan = [
                        "available": true, "intent": plan.intent,
                        "mustTerms": plan.mustTerms, "optionalTerms": plan.optionalTerms,
                        "excludedTerms": plan.excludedTerms, "media": plan.media,
                        "people": plan.people, "places": plan.places,
                        "timeExpression": plan.timeExpression as Any? ?? NSNull(),
                                 "confirmed": plan.rankedPaths, "done": plan.done,
                        "seconds": ProcessInfo.processInfo.systemUptime - started,
                    ]
                } else {
                    localPlan = ["available": true, "error": "8B query plan unavailable",
                                 "seconds": ProcessInfo.processInfo.systemUptime - started]
                }
            }
            // Mirror the UI fallback so a thin result set can be inspected without driving the panel.
            var fallback: [String: Any] = ["triggered": false]
            if LocalRerank.isAvailable, !LibraryIndex.compile(args[2]).isIdentifierQuery, hits.count <= LocalRerank.thinResultCount {
                let started = ProcessInfo.processInfo.systemUptime
                let wide = await LocalSemanticIndex.shared.search(query: args[2], roots: roots.map(\.path),
                                                                  minScore: LocalRerank.wideMinScore)
                var widened = LibraryGateway.fallbackCandidates(query: args[2], in: files, semantic: wide)
                if widened.isEmpty {
                    let terms = await LocalRerank.expandQuery(args[2])
                    if !terms.isEmpty { widened = LibraryGateway.fallbackCandidates(query: args[2], in: files, semantic: [], expandedTerms: terms) }
                }
                let ranked = await LocalRerank.rank(query: args[2], files: files, evidence: widened)
                let merged = ranked.map { LocalRerank.merge(ranked: $0, precise: hits, widened: widened) } ?? hits
                fallback = ["triggered": true, "widenedCandidates": wide.count,
                            "widenedHits": widened.count, "modelKept": ranked?.count as Any? ?? NSNull(),
                            "seconds": ProcessInfo.processInfo.systemUptime - started,
                            "result": merged.map { ["file": $0.relative, "reason": $0.reason] }]
            }
            let report: [String: Any] = ["query": args[2], "files": files.count, "semanticCandidates": semantic.count,
                "lexicalMilliseconds": lexicalMilliseconds, "localFallback": fallback,
                "searchTrace": [
                    "stages": [
                        ["name": "fast_retrieval", "milliseconds": lexicalMilliseconds, "candidates": lexical.count],
                        ["name": "semantic_retrieval", "milliseconds": semanticMilliseconds, "candidates": semantic.count],
                    ],
                    "resultCount": hits.count,
                    "directCount": hits.filter { $0.confidenceTier == .direct }.count,
                ],
                "local8BPlan": localPlan,
                "summaryNeedsReview": files.filter { $0.summaryIssue != nil }.count,
                "limitedCoverage": files.filter { $0.contentIssue != nil }.count,
                "lexicalTop": lexical.prefix(10).map(\.name),
                "candidateTiers": structured.map { ["file": $0.hit.relative, "tier": $0.tier.rawValue,
                    "evidence": $0.evidence.map(\.source.rawValue)] },
                "hits": hits.map {
                    [
                        "file": $0.relative, "kind": $0.kind.rawValue, "reason": $0.reason,
                        "tier": $0.confidenceTier.rawValue,
                        "evidenceSources": $0.evidence.map(\.source.rawValue),
                        "snippet": $0.snippet,
                        "chunkID": $0.chunkID as Any? ?? NSNull(),
                        "page": $0.page as Any? ?? NSNull(),
                    ]
                }]
            do { let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]); print(String(decoding:data,as:UTF8.self)); exit(0) }
            catch { exit(1) }
        }
        RunLoop.current.run(); return true
    }
}
