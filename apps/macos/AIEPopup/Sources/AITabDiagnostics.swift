import Foundation
import AIEData

enum AITabDiagnostics {
    static func runIfRequested() -> Bool {
        guard let command = CommandLine.arguments.dropFirst().first,
              ["--verify-ai-tab", "--audit-ai-tab"].contains(command)
        else { return false }
        if command == "--audit-ai-tab" {
            auditCurrentLibrary()
            return true
        }

        let now = Date()
        let index = AITabIndex(candidates: [
            .init(value: "陈知夏", kind: .entity, source: "旧周记.md", modifiedAt: now.addingTimeInterval(-100)),
            .init(value: "陈知夏", kind: .entity, source: "个人资料.md", modifiedAt: now),
            .init(value: "陈知秋", kind: .entity, source: "联系人.md", modifiedAt: now),
            .init(value: "陈知夏访谈", kind: .file, source: "陈知夏访谈.pdf", modifiedAt: now),
        ])
        let suggestions = index.suggestions(for: "陈")
        precondition(suggestions.first?.value == "陈知夏")
        precondition(suggestions.first?.suffix(after: "陈") == "知夏")
        precondition(suggestions.first?.source == "个人资料.md")
        precondition(suggestions.first?.sourceCount == 2)
        precondition(index.suggestions(for: "陈知夏").allSatisfy { $0.value != "陈知夏" })

        let facts = AITabIndex.personalFacts(in: "工号：AIE-2048，手机：13800138000")
        precondition(facts.contains { $0.value == "AIE-2048" && $0.kind == .employeeID })
        precondition(facts.contains { $0.value == "13800138000" && $0.kind == .phone })

        let performanceIndex = AITabIndex(candidates: (0..<10_000).map {
            AITabCandidate(
                value: String(format: "联系人%05d", $0), kind: .entity,
                source: "资料\($0 % 100).md", modifiedAt: now
            )
        })
        var durations: [Double] = []
        for query in ["联", "联系人0", "联系人09", "联系人099"].repeated(50) {
            let started = ProcessInfo.processInfo.systemUptime
            _ = performanceIndex.suggestions(for: query)
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }
        durations.sort()
        let p95 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
        precondition(p95 < 50, "AI Tab lookup P95 exceeded 50ms: \(p95)")

        let report: [String: Any] = [
            "passed": true,
            "candidateCount": 10_000,
            "lookupP95Milliseconds": p95,
            "topSuggestion": suggestions.first?.value ?? "",
            "sourceCount": suggestions.first?.sourceCount ?? 0,
            "factKinds": Array(Set(facts.map { $0.kind.rawValue })).sorted(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return true
    }

    private static func auditCurrentLibrary() {
        guard CommandLine.arguments.count >= 3 else {
            fputs("usage: AIEPopup --audit-ai-tab prefix [/library/root ...]\n", stderr)
            exit(2)
        }
        let requestedRoots = CommandLine.arguments.dropFirst(3).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let roots = requestedRoots.isEmpty ? LibraryRoots.load() : requestedRoots
        let files = LibraryGateway.load(roots: roots)
        let databaseEntities: [String: [String]]
        let databaseEntityError: String?
        do {
            databaseEntities = try AppDatabase.open().entityNames(rootPaths: roots.map {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
            })
            databaseEntityError = nil
        } catch {
            databaseEntities = [:]
            databaseEntityError = String(describing: error)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let index = AITabIndex(files: files)
        let buildMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let lookupStarted = ProcessInfo.processInfo.systemUptime
        let suggestions = index.suggestions(for: CommandLine.arguments[2])
        let lookupMilliseconds = (ProcessInfo.processInfo.systemUptime - lookupStarted) * 1_000
        let report: [String: Any] = [
            "files": files.count,
            "entityFiles": files.filter { !$0.entityNames.isEmpty }.count,
            "entityValues": files.reduce(0) { $0 + $1.entityNames.count },
            "databaseEntityFiles": databaseEntities.count,
            "databaseEntityError": databaseEntityError ?? NSNull(),
            "libraryError": LibraryGateway.lastError ?? NSNull(),
            "databasePath": AppDatabase.url.path,
            "rootIDs": roots.map { ContentIdentity.root($0.standardizedFileURL.resolvingSymlinksInPath().path) },
            "prefix": CommandLine.arguments[2],
            "buildMilliseconds": buildMilliseconds,
            "lookupMilliseconds": lookupMilliseconds,
            "suggestions": suggestions.map {
                ["value": $0.value, "kind": $0.kind.rawValue, "source": $0.sourceLabel]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

private extension Array {
    func repeated(_ count: Int) -> [Element] {
        (0..<count).flatMap { _ in self }
    }
}
