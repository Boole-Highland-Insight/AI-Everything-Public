import Foundation

enum JunkClassifierDiagnostics {
    static func runIfRequested() -> Bool {
        guard let command = CommandLine.arguments.dropFirst().first,
              ["--verify-junk-classifier", "--evaluate-reuse-classifier"].contains(command)
        else { return false }
        if command == "--evaluate-reuse-classifier" {
            evaluateCurrentLibrary()
            return true
        }

        func file(
            _ name: String, kind: FileKind = .image, size: Int = 100,
            hash: String? = nil, screenshot: Bool = false, modified: TimeInterval = 100,
            contentType: String = "", completion: String = "", completionConfidence: Double = 0,
            evidence: [String] = [], reuseAction: String = "", reuseReason: String = "",
            reuseConfidence: Double = 0, dismissed: Bool = false
        ) -> IndexedFile {
            var value = IndexedFile(
                path: "/fixture/\(name)", name: name, relative: name,
                kind: kind, ext: (name as NSString).pathExtension.lowercased(),
                mtime: Date(timeIntervalSince1970: modified),
                haystack: name, preview: name, thumbPath: nil, rootPath: "/fixture",
                size: size, hasBarcode: false, isScreenshot: screenshot,
                llmLine: name, llmCard: name, uploadedToCloud: false,
                contentHash: hash
            )
            value.contentType = contentType
            value.completionState = completion
            value.completionConfidence = completionConfidence
            value.completionEvidence = evidence
            value.reuseAction = reuseAction
            value.reuseReason = reuseReason
            value.reuseConfidence = reuseConfidence
            value.reuseDismissed = dismissed
            return value
        }

        let files = [
            file("Screenshot 2026.png", hash: "screen", screenshot: true,
                 completion: "incomplete", completionConfidence: 0.99, evidence: ["右侧为空"]),
            file("ordinary-photo.jpg", hash: "photo", completion: "incomplete",
                 completionConfidence: 0.99, evidence: ["主体不完整"]),
            file("test.md", kind: .document, hash: "test"),
            file("report.pdf", kind: .document, hash: "same", modified: 10),
            file("report copy.pdf", kind: .document, hash: "same", modified: 20),
            file("周记未完成.md", kind: .document, hash: "draft"),
            file("未完成速写.png", hash: "drawing", contentType: "手绘速写"),
            file("未完成速写 补全.png", hash: "generated", contentType: "绘画"),
            file("项目续写.md", kind: .document, hash: "continued"),
            file("产品草稿.md", kind: .document, hash: "polish"),
            file("方案.md", kind: .document, hash: "strong", completion: "incomplete",
                 completionConfidence: 0.93, evidence: ["结尾停在未闭合句子"]),
            file("弱证据.md", kind: .document, hash: "weak", completion: "incomplete",
                 completionConfidence: 0.55, evidence: ["可能缺少结尾"]),
            file("海报线稿.png", hash: "line", contentType: "插画线稿",
                 reuseAction: "polish", reuseReason: "可以完善配色", reuseConfidence: 0.91),
            file("小猫素描.jpg", hash: "cat", contentType: "插画", completion: "complete",
                 completionConfidence: 1, reuseAction: "complete",
                 reuseReason: "画面已经完整", reuseConfidence: 1),
            file("小猫素描 补全 3.png", hash: "cat-generated", contentType: "插画",
                 completion: "complete", completionConfidence: 1, reuseAction: "complete",
                 reuseReason: "画面已经完整", reuseConfidence: 1),
            file("湖景.jpg", hash: "landscape", contentType: "插画", completion: "complete",
                 completionConfidence: 1, reuseAction: "complete",
                 reuseReason: "画面已经完整", reuseConfidence: 1),
            file("不再推荐.md", kind: .document, hash: "dismissed", completion: "incomplete",
                 completionConfidence: 0.99, evidence: ["缺少结尾"], dismissed: true),
        ]
        let items = JunkClassifier.classify(files)
        let duplicates = items.filter { $0.groupID == "duplicate:same" }
        precondition(duplicates.count == 2)
        precondition(duplicates.filter(\.suggestedOriginal).map(\.name) == ["report.pdf"])
        precondition(items.contains { $0.name == "周记未完成.md" && $0.bin == .completion })
        precondition(items.contains { $0.name == "未完成速写.png" && $0.bin == .completion })
        precondition(!items.contains { $0.name == "未完成速写 补全.png" })
        precondition(!items.contains { $0.name == "项目续写.md" })
        precondition(items.contains { $0.name == "方案.md" && $0.bin == .completion })
        precondition(items.contains { $0.name == "产品草稿.md" && $0.bin == .optimization })
        precondition(items.contains { $0.name == "海报线稿.png" && $0.bin == .optimization })
        precondition(items.contains { $0.name == "小猫素描.jpg" && $0.bin == .optimization })
        precondition(!items.contains { $0.name == "小猫素描 补全 3.png" })
        precondition(!items.contains { ["Screenshot 2026.png", "ordinary-photo.jpg", "湖景.jpg", "test.md", "弱证据.md", "不再推荐.md"].contains($0.name) })
        print("Junk classifier checks passed: exact groups, high-confidence completion, conservative optimization.")
        return true
    }

    private static func evaluateCurrentLibrary() {
        let requested = CommandLine.arguments.dropFirst(2).filter { $0.hasPrefix("/") }.map(URL.init(fileURLWithPath:))
        let roots = requested.isEmpty ? LibraryRoots.load() : requested
        let files = LibraryGateway.load(roots: roots)
        let items = JunkClassifier.classify(files)
        let supported = Set(["txt", "md", "rtf", "pdf", "ppt", "pptx", "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "avif"])
        func explicitIncomplete(_ file: IndexedFile) -> Bool {
            guard supported.contains(file.ext), !file.isGeneratedArtifact else { return false }
            let name = file.name.lowercased()
            return ["未完成", "没画完", "未写完", "半成品"].contains(where: name.contains)
                || name.range(of: #"(^|[^a-z])wip([^a-z]|$)"#, options: .regularExpression) != nil
        }
        func explicitOptimization(_ file: IndexedFile) -> Bool {
            guard supported.contains(file.ext), !file.isGeneratedArtifact else { return false }
            let name = file.name.lowercased()
            return name.contains("草稿") || name.contains("待改写")
        }
        let expectedCompletion = Set(files.filter(explicitIncomplete).map(\.path))
        let expectedOptimization = Set(files.filter(explicitOptimization).map(\.path))
        let predictedCompletion = Set(items.filter { $0.bin == .completion }.map(\.path))
        let predictedOptimization = Set(items.filter { $0.bin == .optimization }.map(\.path))
        let expectedDuplicateGroups = Dictionary(grouping: files.filter { $0.contentHash?.isEmpty == false }, by: { $0.contentHash! })
            .filter { $0.value.count > 1 }
        let predictedDuplicateGroups = Dictionary(grouping: items.filter { $0.bin == .duplicate }, by: { $0.groupID ?? "" })
        let result: [String: Any] = [
            "files": files.count,
            "deepScanned": files.filter { !$0.completionState.isEmpty }.count,
            "evidenceScanned": files.filter { !$0.completionEvidence.isEmpty || !$0.reuseReason.isEmpty }.count,
            "explicitCompletion": [
                "expected": expectedCompletion.count,
                "hit": expectedCompletion.intersection(predictedCompletion).count,
                "miss": expectedCompletion.subtracting(predictedCompletion).map { relative($0, files: files) }.sorted(),
                "unreviewedModelCandidates": predictedCompletion.subtracting(expectedCompletion).map { relative($0, files: files) }.sorted(),
            ],
            "explicitOptimization": [
                "expected": expectedOptimization.count,
                "hit": expectedOptimization.intersection(predictedOptimization).count,
                "miss": expectedOptimization.subtracting(predictedOptimization).map { relative($0, files: files) }.sorted(),
                "unreviewedModelCandidates": predictedOptimization.subtracting(expectedOptimization).map { relative($0, files: files) }.sorted(),
            ],
            "exactDuplicates": [
                "expectedGroups": expectedDuplicateGroups.count,
                "predictedGroups": predictedDuplicateGroups.count,
                "expectedFiles": expectedDuplicateGroups.values.reduce(0) { $0 + $1.count },
                "predictedFiles": predictedDuplicateGroups.values.reduce(0) { $0 + $1.count },
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }

    private static func relative(_ path: String, files: [IndexedFile]) -> String {
        files.first(where: { $0.path == path })?.relative ?? path
    }
}
