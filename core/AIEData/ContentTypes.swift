import Foundation
import CryptoKit

public enum ContentIdentity {
    public static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func root(_ path: String) -> String { digest(URL(fileURLWithPath: path).standardizedFileURL.path) }
    public static func version(fileID: String, contentHash: String) -> String { digest(fileID + ":" + contentHash) }
    public static func chunk(versionID: String, key: String) -> String { digest(versionID + ":" + key) }
}

public struct ContentBlock: Codable, Sendable {
    public var key: String
    public var parentKey: String?
    public var kind: String
    public var page: Int?
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var locationJSON: String?
    public var text: String
    public var tags: [String]
    public var summary: String
    public var summaryMethod: String
    public var parserVersion: String
    public init(key: String, parentKey: String? = "document", kind: String, page: Int? = nil,
                startSeconds: Double? = nil, endSeconds: Double? = nil, locationJSON: String? = nil,
                text: String, tags: [String] = [], summary: String = "", summaryMethod: String = "extractive", parserVersion: String = "1") {
        self.key = key; self.parentKey = parentKey; self.kind = kind; self.page = page
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.locationJSON = locationJSON
        self.text = text; self.tags = tags; self.summary = summary; self.summaryMethod = summaryMethod; self.parserVersion = parserVersion
    }
}

public struct ScanStage: Codable, Sendable {
    public var stage: String
    public var status: String
    public var error: String?
    public var attemptedAt: String?
    public init(_ stage: String, status: String, error: String? = nil, attemptedAt: String? = nil) {
        self.stage = stage; self.status = status; self.error = error; self.attemptedAt = attemptedAt
    }
}

/// A derived claim about a version or one of its evidence units. Native text/OCR/transcripts
/// stay in ContentBlock/unit_contents; model and system classifications live here.
public struct ContentObservation: Codable, Sendable {
    public var subjectBlockKey: String?
    public var type: String
    public var valueText: String?
    public var valueNumber: Double?
    public var valueJSON: String?
    public var confidence: Double?
    public var producerJobType: String?
    public var state: String

    public init(subjectBlockKey: String? = nil, type: String, valueText: String? = nil,
                valueNumber: Double? = nil, valueJSON: String? = nil, confidence: Double? = nil,
                producerJobType: String? = nil, state: String = "current") {
        self.subjectBlockKey = subjectBlockKey; self.type = type; self.valueText = valueText
        self.valueNumber = valueNumber; self.valueJSON = valueJSON; self.confidence = confidence
        self.producerJobType = producerJobType; self.state = state
    }
}

/// Durable provenance projected from a completed or failed processor attempt.
public struct ProcessorRun: Codable, Sendable {
    public var jobType: String
    public var processorKey: String
    public var processorVersion: String
    public var modelKey: String?
    public var modelRevision: String?
    public var promptVersion: String?
    public var inputFingerprint: String
    public var parametersJSON: String?
    public var startedAt: Double
    public var finishedAt: Double?
    public var durationMS: Int?
    public var outcome: String
    public var errorCode: String?

    public init(jobType: String, processorKey: String, processorVersion: String,
                modelKey: String? = nil, modelRevision: String? = nil, promptVersion: String? = nil,
                inputFingerprint: String, parametersJSON: String? = nil, startedAt: Double,
                finishedAt: Double? = nil, durationMS: Int? = nil, outcome: String,
                errorCode: String? = nil) {
        self.jobType = jobType; self.processorKey = processorKey; self.processorVersion = processorVersion
        self.modelKey = modelKey; self.modelRevision = modelRevision; self.promptVersion = promptVersion
        self.inputFingerprint = inputFingerprint; self.parametersJSON = parametersJSON
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.durationMS = durationMS
        self.outcome = outcome; self.errorCode = errorCode
    }
}

public struct SourceDocument: Codable, Sendable {
    public var id: String
    public var rootPath: String
    public var path: String
    public var relativePath: String
    public var kind: String
    public var ext: String
    public var contentHash: String
    public var size: Int64
    public var modifiedAt: Double
    public var blocks: [ContentBlock]
    public var stages: [ScanStage]
    public var fileSummary: String
    public var fileKeywords: [String]
    public var summaryModel: String
    public var summaryVersion: String
    public var coverage: String
    public var observations: [ContentObservation]
    public var processorRuns: [ProcessorRun]
    public var versionID: String { ContentIdentity.version(fileID: id, contentHash: contentHash) }
    public init(id: String, rootPath: String, path: String, relativePath: String, kind: String, ext: String,
                contentHash: String, size: Int64, modifiedAt: Double, blocks: [ContentBlock],
                stages: [ScanStage] = [], fileSummary: String = "", fileKeywords: [String] = [],
                summaryModel: String = "legacy", summaryVersion: String = "legacy", coverage: String = "partial",
                observations: [ContentObservation] = [], processorRuns: [ProcessorRun] = []) {
        self.id = id; self.rootPath = rootPath; self.path = path; self.relativePath = relativePath
        self.kind = kind; self.ext = ext; self.contentHash = contentHash; self.size = size; self.modifiedAt = modifiedAt
        self.blocks = blocks; self.stages = stages; self.fileSummary = fileSummary; self.fileKeywords = fileKeywords
        self.summaryModel = summaryModel; self.summaryVersion = summaryVersion; self.coverage = coverage
        self.observations = observations; self.processorRuns = processorRuns
    }
}

public struct ChunkResult: Codable, Sendable {
    public let contentHash: String
    public let id: String
    public let fileID: String
    public let versionID: String
    public let path: String
    public let relativePath: String
    public let kind: String
    public let page: Int?
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let locationJSON: String?
    public let text: String
    public let summary: String
    public let tags: [String]
    public let score: Double
    public let retrievalChannel: String?

    public init(contentHash: String, id: String, fileID: String, versionID: String,
                path: String, relativePath: String, kind: String, page: Int?,
                startSeconds: Double?, endSeconds: Double?, locationJSON: String?,
                text: String, summary: String, tags: [String], score: Double,
                retrievalChannel: String? = nil) {
        self.contentHash = contentHash; self.id = id; self.fileID = fileID
        self.versionID = versionID; self.path = path; self.relativePath = relativePath
        self.kind = kind; self.page = page; self.startSeconds = startSeconds
        self.endSeconds = endSeconds; self.locationJSON = locationJSON; self.text = text
        self.summary = summary; self.tags = tags; self.score = score
        self.retrievalChannel = retrievalChannel
    }

    public func from(_ channel: String) -> ChunkResult {
        ChunkResult(contentHash: contentHash, id: id, fileID: fileID, versionID: versionID,
                    path: path, relativePath: relativePath, kind: kind, page: page,
                    startSeconds: startSeconds, endSeconds: endSeconds, locationJSON: locationJSON,
                    text: text, summary: summary, tags: tags, score: score, retrievalChannel: channel)
    }

    public func withScore(_ score: Double) -> ChunkResult {
        ChunkResult(
            contentHash: contentHash, id: id, fileID: fileID, versionID: versionID,
            path: path, relativePath: relativePath, kind: kind, page: page,
            startSeconds: startSeconds, endSeconds: endSeconds, locationJSON: locationJSON,
            text: text, summary: summary, tags: tags, score: score
        )
    }
}

public struct DataStatistics: Codable, Sendable {
    public let files: Int
    public let versions: Int
    public let chunks: Int
    public let semantics: Int
    public let embeddings: Int
    public let failedStages: Int
}

public struct IndexCapacity: Codable, Sendable {
    public let usedBytes: Int64
    public let softLimitBytes: Int64
    public let semanticVectorBytes: Int64
    public let semanticUsage: [SemanticIndexUsage]

    /// Full-text and metadata remain available when this limit is reached. Only new vectors pause.
    public var reachedSoftLimit: Bool { semanticVectorBytes >= softLimitBytes }
}

public enum SemanticContentClass: String, CaseIterable, Codable, Sendable {
    case image
    case pagedDocument = "paged_document"
    case textDocument = "text_document"
    case media
    case other

    public var budgetShare: Double {
        switch self {
        case .image: 0.20
        case .pagedDocument: 0.30
        case .textDocument: 0.25
        case .media: 0.20
        case .other: 0.05
        }
    }
}

public struct SemanticIndexUsage: Codable, Sendable {
    public let contentClass: SemanticContentClass
    public let bytes: Int64
    public let targetBytes: Int64
}

public struct VectorIndexBenchmark: Codable, Sendable {
    public let backend: String
    public let spaceID: String
    public let dimensions: Int
    public let candidateCount: Int
    public let queryCount: Int
    public let topK: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let databaseBytes: Int64
    public let vectorBytes: Int64
}

public struct UnderstandingStatistics: Codable, Sendable {
    public let sources: Int
    public let items: Int
    public let contentUnits: Int
    public let unitContents: Int
    public let observations: Int
    public let features: Int
    public let relations: Int
    public let jobs: Int
    public let modelRuns: Int
    public let searchDocuments: Int
}

public struct DurableJob: Codable, Equatable, Sendable {
    public let id: String
    public let subjectType: String
    public let subjectID: String
    public let jobType: String
    public let priority: Int
    public let state: String
    public let attemptCount: Int
    public let maxAttempts: Int
    public let notBefore: Double
    public let leaseOwner: String?
    public let leaseExpiresAt: Double?
    public let inputHash: String
    public let checkpointJSON: String?
    public let errorCode: String?
}

public enum DataLayerError: Error {
    case invalidDocument(String), unauthorizedRoot, staleVersion, invalidEmbedding, missingChunk
}
