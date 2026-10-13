import Foundation

enum JunkBin: String, CaseIterable {
    case duplicate, completion, optimization

    var title: String {
        switch self {
        case .duplicate: return "重复"
        case .completion: return "补全"
        case .optimization: return "优化"
        }
    }
}

struct JunkItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let relative: String
    let kind: FileKind
    let ext: String
    let thumbPath: String?
    let bin: JunkBin
    let reason: String
    let snippet: String
    let uploadedToCloud: Bool
    var groupID: String? = nil
    var suggestedOriginal = false
}

enum JunkClassifier {
    static func classify(_ files: [IndexedFile]) -> [JunkItem] {
        let kept = ((try? AppDatabase.open().preferencePaths("kept")) ?? [])
        let queued = ((try? AppDatabase.open().preferencePaths("cleanup")) ?? [])
        let generatedArtifacts = generatedArtifactPaths(in: files)
        var items: [JunkItem] = []
        var seen = Set<String>()

        for group in duplicateGroups(in: files, kept: kept) {
            for (index, file) in group.members.enumerated() where seen.insert(file.path).inserted {
                let original = group.members[0]
                let reason = index == 0
                    ? suggestedOriginalReason(file, explicitlyKept: kept.contains(file.path))
                    : "与 \(original.name) 内容完全相同"
                items.append(item(file, bin: .duplicate, reason: reason,
                                  groupID: group.id, suggestedOriginal: index == 0))
            }
        }

        for file in files where queued.contains(file.path) && !seen.contains(file.path) {
            seen.insert(file.path)
            let bin: JunkBin = completionReason(file) == nil ? .optimization : .completion
            items.append(item(file, bin: bin, reason: "你已将原件加入待清理"))
        }

        for file in files where !seen.contains(file.path) {
            guard !kept.contains(file.path), !file.reuseDismissed, !file.reuseResolved,
                  !generatedArtifacts.contains(file.path)
            else { continue }
            if let reason = completionReason(file) {
                seen.insert(file.path)
                items.append(item(file, bin: .completion, reason: reason))
            } else if let reason = optimizationReason(file) {
                seen.insert(file.path)
                items.append(item(file, bin: .optimization, reason: reason))
            }
        }

        let order: [JunkBin: Int] = [.duplicate: 0, .completion: 1, .optimization: 2]
        return items.sorted {
            let ao = order[$0.bin] ?? 9
            let bo = order[$1.bin] ?? 9
            if ao != bo { return ao < bo }
            if $0.groupID != $1.groupID { return ($0.groupID ?? "") < ($1.groupID ?? "") }
            if $0.suggestedOriginal != $1.suggestedOriginal { return $0.suggestedOriginal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func keep(_ paths: [String]) {
        do {
            let database = try AppDatabase.open()
            for path in paths { try database.setPreference(path: path, name: "kept", value: true) }
        } catch { AppDatabase.failed(error) }
    }

    static func chooseOriginal(_ path: String, among members: [String]) {
        do {
            let database = try AppDatabase.open()
            for member in members {
                try database.setPreference(path: member, name: "kept", value: member == path)
            }
        } catch { AppDatabase.failed(error) }
    }

    static func queueCleanup(_ paths: [String], queued: Bool) {
        do {
            let database = try AppDatabase.open()
            for path in paths { try database.setPreference(path: path, name: "cleanup", value: queued) }
        } catch { AppDatabase.failed(error) }
    }

    private static func item(
        _ file: IndexedFile, bin: JunkBin, reason: String,
        groupID: String? = nil, suggestedOriginal: Bool = false
    ) -> JunkItem {
        JunkItem(
            path: file.path, name: file.name, relative: file.relative,
            kind: file.kind, ext: file.ext, thumbPath: file.thumbPath,
            bin: bin, reason: reason, snippet: clip(file.preview),
            uploadedToCloud: file.uploadedToCloud,
            groupID: groupID, suggestedOriginal: suggestedOriginal
        )
    }

    private static func completionReason(_ file: IndexedFile) -> String? {
        guard supportedForReuse(file), imageCanBeRecreated(file) else { return nil }
        let name = file.name.lowercased()
        if containsStrongIncompleteMarker(name) { return "文件名明确标记为未完成" }

        let state = file.completionState.lowercased()
        guard ["unfinished", "incomplete"].contains(state),
              file.completionConfidence >= 0.82,
              !file.completionEvidence.isEmpty
        else { return nil }
        return file.completionEvidence.first ?? "本机模型发现明确缺失部分"
    }

    private static func optimizationReason(_ file: IndexedFile) -> String? {
        guard supportedForReuse(file), imageCanBeRecreated(file) else { return nil }
        let name = file.name.lowercased()
        if name.contains("草稿") || name.contains("待改写") {
            return "这是一份草稿，可继续打磨"
        }
        let action = file.reuseAction.lowercased()
        if file.kind == .image,
           file.completionState.lowercased() == "complete",
           file.completionConfidence >= 0.82,
           action == "complete",
           file.reuseConfidence >= 0.78 {
            let description = "\(file.contentType) \(file.preview)".lowercased()
            guard ["素描", "线稿", "草图", "手绘", "sketch", "line art", "drawing"]
                .contains(where: description.contains)
            else { return nil }
            if ["素描", "线稿", "草图", "sketch", "line art"].contains(where: description.contains) {
                return "这是一幅完整素描，可继续上色或调整风格"
            }
            return "这是一幅完整手绘，可尝试新的配色或表现风格"
        }
        guard ["polish", "recreate"].contains(action),
              file.reuseConfidence >= 0.78,
              !file.reuseReason.isEmpty
        else { return nil }
        return file.reuseReason
    }

    private static func supportedForReuse(_ file: IndexedFile) -> Bool {
        if file.kind == .image { return true }
        return ["txt", "md", "rtf", "pdf", "ppt", "pptx"].contains(file.ext)
    }

    private static func imageCanBeRecreated(_ file: IndexedFile) -> Bool {
        guard file.kind == .image else { return true }
        guard !file.isScreenshot else { return false }
        let evidence = ([file.contentType, file.reuseReason]
            + file.completionEvidence + file.missingParts)
            .joined(separator: " ").lowercased()
        let allowed = [
            "插画", "绘画", "线稿", "设计", "白板", "图表", "示意图", "草图", "手绘",
            "illustration", "drawing", "line art", "design", "whiteboard", "diagram", "sketch",
        ]
        return allowed.contains { evidence.contains($0) }
    }

    private static func containsStrongIncompleteMarker(_ name: String) -> Bool {
        if ["未完成", "没画完", "未写完", "半成品"].contains(where: name.contains) {
            return true
        }
        return name.range(of: #"(^|[^a-z])wip([^a-z]|$)"#, options: .regularExpression) != nil
    }

    /// New outputs carry provenance. This sibling check keeps outputs created before
    /// provenance existed from being offered as drafts again.
    private static func generatedArtifactPaths(in files: [IndexedFile]) -> Set<String> {
        let sourceStems = Set(files.map { URL(fileURLWithPath: $0.path).deletingPathExtension().path })
        return Set(files.compactMap { file in
            if file.isGeneratedArtifact { return file.path }
            let url = URL(fileURLWithPath: file.path)
            let stem = url.deletingPathExtension().lastPathComponent
            guard let range = stem.range(of: #"\s补全(?:\s\d+)?$"#, options: .regularExpression) else {
                return nil
            }
            let sourceStem = String(stem[..<range.lowerBound])
            guard !sourceStem.isEmpty else { return nil }
            let source = url.deletingLastPathComponent()
                .appendingPathComponent(sourceStem)
                .path
            return sourceStems.contains(source) ? file.path : nil
        })
    }

    private struct DuplicateGroup {
        let id: String
        let members: [IndexedFile]
    }

    private static func duplicateGroups(in files: [IndexedFile], kept: Set<String>) -> [DuplicateGroup] {
        var groups: [String: [IndexedFile]] = [:]
        for file in files {
            guard let hash = file.contentHash, !hash.isEmpty else { continue }
            groups[hash, default: []].append(file)
        }
        return groups.compactMap { hash, members in
            guard members.count > 1 else { return nil }
            let sorted = members.sorted {
                let leftKept = kept.contains($0.path)
                let rightKept = kept.contains($1.path)
                if leftKept != rightKept { return leftKept }
                let left = originalPenalty($0)
                let right = originalPenalty($1)
                if left != right { return left < right }
                if $0.mtime != $1.mtime { return $0.mtime < $1.mtime }
                return $0.relative.localizedStandardCompare($1.relative) == .orderedAscending
            }
            return DuplicateGroup(id: "duplicate:\(hash)", members: sorted)
        }
    }

    private static func originalPenalty(_ file: IndexedFile) -> Int {
        let base = (file.name as NSString).deletingPathExtension
        var penalty = 0
        if base.range(
            of: #"(\s*\(\d+\)|[-_ ]copy|副本)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil { penalty += 4 }
        let path = file.path.lowercased()
        if path.contains("/downloads/") || path.contains("/tmp/") { penalty += 2 }
        return penalty
    }

    private static func suggestedOriginalReason(_ file: IndexedFile, explicitlyKept: Bool) -> String {
        if explicitlyKept { return "建议保留 · 你之前选择保留这份" }
        if originalPenalty(file) == 0 { return "建议保留 · 文件名无副本标记且时间更早" }
        return "建议保留 · 时间更早"
    }

    private static func clip(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 88 { return compact }
        return String(compact.prefix(88)) + "…"
    }
}
