import Foundation

enum AITabSuggestionKind: String {
    case entity = "实体"
    case employeeID = "工号"
    case phone = "电话"
    case file = "文件"
}

struct AITabSuggestion: Equatable {
    let value: String
    let kind: AITabSuggestionKind
    let source: String
    let sourceCount: Int

    func suffix(after prefix: String) -> String {
        guard value.count > prefix.count else { return "" }
        let index = value.index(value.startIndex, offsetBy: prefix.count)
        return String(value[index...])
    }

    var sourceLabel: String {
        sourceCount > 1 ? "\(source) 等 \(sourceCount) 处" : source
    }
}

struct AITabCandidate {
    let value: String
    let kind: AITabSuggestionKind
    let source: String
    let modifiedAt: Date
}

/// A deterministic, in-memory projection of facts already stored in the local index.
/// Keystrokes never invoke a model or touch the database.
struct AITabIndex {
    private struct Candidate {
        let value: String
        let normalized: String
        let kind: AITabSuggestionKind
        let source: String
        let sourceCount: Int
        let modifiedAt: Date
    }

    private var buckets: [Character: [Candidate]] = [:]

    init() {}

    init(files: [IndexedFile]) {
        var candidates: [AITabCandidate] = []
        candidates.reserveCapacity(files.count * 2)
        for file in files {
            let source = file.relative
            let baseName = (file.name as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isUseful(baseName) {
                candidates.append(.init(value: baseName, kind: .file, source: source, modifiedAt: file.mtime))
            }
            for entity in file.entityNames where Self.isUseful(entity) {
                candidates.append(.init(value: entity, kind: .entity, source: source, modifiedAt: file.mtime))
            }

            // Explicitly labelled personal facts are safe to suggest. Limit the sampled
            // text because this projection is rebuilt after an index refresh.
            let text = file.chunks.prefix(48).map(\.text).joined(separator: "\n")
            for fact in Self.personalFacts(in: String(text.prefix(48_000))) {
                candidates.append(.init(value: fact.value, kind: fact.kind, source: source, modifiedAt: file.mtime))
            }
        }
        self.init(candidates: candidates)
    }

    init(candidates: [AITabCandidate]) {
        struct Aggregate {
            var candidate: AITabCandidate
            var sources: Set<String>
        }
        var aggregate: [String: Aggregate] = [:]
        for candidate in candidates where Self.isUseful(candidate.value) {
            let normalized = Self.normalize(candidate.value)
            guard !normalized.isEmpty else { continue }
            let key = normalized
            if var existing = aggregate[key] {
                existing.sources.insert(candidate.source)
                let candidateRank = Self.kindRank(candidate.kind)
                let existingRank = Self.kindRank(existing.candidate.kind)
                if candidateRank < existingRank
                    || (candidateRank == existingRank && candidate.modifiedAt > existing.candidate.modifiedAt) {
                    existing.candidate = candidate
                }
                aggregate[key] = existing
            } else {
                aggregate[key] = Aggregate(candidate: candidate, sources: [candidate.source])
            }
        }

        for item in aggregate.values {
            let normalized = Self.normalize(item.candidate.value)
            guard let first = normalized.first else { continue }
            buckets[first, default: []].append(Candidate(
                value: item.candidate.value,
                normalized: normalized,
                kind: item.candidate.kind,
                source: item.candidate.source,
                sourceCount: item.sources.count,
                modifiedAt: item.candidate.modifiedAt
            ))
        }
        for key in buckets.keys {
            buckets[key]?.sort(by: Self.precedes)
        }
    }

    func suggestions(for rawPrefix: String, limit: Int = 5) -> [AITabSuggestion] {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalize(prefix)
        guard !normalized.isEmpty, prefix.count <= 120, let first = normalized.first else { return [] }
        return (buckets[first] ?? [])
            .lazy
            .filter { $0.normalized != normalized && $0.normalized.hasPrefix(normalized) }
            .prefix(limit)
            .map {
                AITabSuggestion(value: $0.value, kind: $0.kind, source: $0.source, sourceCount: $0.sourceCount)
            }
    }

    static func personalFacts(in text: String) -> [(value: String, kind: AITabSuggestionKind)] {
        var result: [(String, AITabSuggestionKind)] = []
        let wholeRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in employeeExpression.matches(in: text, range: wholeRange) {
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { continue }
            result.append((String(text[range]), .employeeID))
        }
        for expression in [labelledPhoneExpression, mobilePhoneExpression] {
            for match in expression.matches(in: text, range: wholeRange) {
                let capture = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                guard let range = Range(capture, in: text) else { continue }
                let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append((value, .phone))
            }
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUseful(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= 120 && !trimmed.contains("\n")
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.sourceCount != rhs.sourceCount { return lhs.sourceCount > rhs.sourceCount }
        let leftKind = kindRank(lhs.kind), rightKind = kindRank(rhs.kind)
        if leftKind != rightKind { return leftKind < rightKind }
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
        return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
    }

    private static func kindRank(_ kind: AITabSuggestionKind) -> Int {
        switch kind {
        case .entity: return 0
        case .employeeID: return 1
        case .phone: return 2
        case .file: return 3
        }
    }

    private static let employeeExpression = try! NSRegularExpression(
        pattern: #"(?:工号|员工(?:编号|号)|employee\s*(?:id|no\.?))\s*[:：#]?\s*([A-Z0-9][A-Z0-9_-]{2,31})"#,
        options: [.caseInsensitive]
    )
    private static let labelledPhoneExpression = try! NSRegularExpression(
        pattern: #"(?:电话|手机|phone|mobile)\s*[:：]?\s*((?:\+?86[ -]?)?(?:1[3-9]\d{9}|(?:0\d{2,3}[ -]?)?\d{7,8}))"#,
        options: [.caseInsensitive]
    )
    private static let mobilePhoneExpression = try! NSRegularExpression(
        pattern: #"(?<!\d)((?:\+?86[ -]?)?1[3-9]\d{9})(?!\d)"#
    )
}
