import Accelerate
import Foundation

public struct VectorIndexCandidate: Sendable {
    public let id: String
    public let vector: Data

    public init(id: String, vector: Data) {
        self.id = id
        self.vector = vector
    }
}

public struct VectorIndexMatch: Sendable {
    public let id: String
    public let score: Double
}

public struct VectorSearchDiagnostics: Sendable {
    public let scannedVectors: Int
    public let connectionWaitMilliseconds: Double
    public let metadataReadMilliseconds: Double
    public let candidateReadMilliseconds: Double
    public let cosineMilliseconds: Double
    public let detailReadMilliseconds: Double
    public let totalMilliseconds: Double
    public let highestScore: Double?
    public let lowestTopScore: Double?

    public init(
        scannedVectors: Int, connectionWaitMilliseconds: Double,
        metadataReadMilliseconds: Double, candidateReadMilliseconds: Double,
        cosineMilliseconds: Double, detailReadMilliseconds: Double,
        totalMilliseconds: Double, highestScore: Double?, lowestTopScore: Double?
    ) {
        self.scannedVectors = scannedVectors
        self.connectionWaitMilliseconds = connectionWaitMilliseconds
        self.metadataReadMilliseconds = metadataReadMilliseconds
        self.candidateReadMilliseconds = candidateReadMilliseconds
        self.cosineMilliseconds = cosineMilliseconds
        self.detailReadMilliseconds = detailReadMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.highestScore = highestScore
        self.lowestTopScore = lowestTopScore
    }
}

public struct VectorSearchOutput {
    public let matches: [ChunkResult]
    public let diagnostics: VectorSearchDiagnostics

    public init(matches: [ChunkResult], diagnostics: VectorSearchDiagnostics) {
        self.matches = matches
        self.diagnostics = diagnostics
    }
}

/// The storage layer streams authorized candidates into this boundary. A future ANN backend can
/// implement the same result contract while the exact backend remains the correctness fallback.
public protocol VectorIndex: Sendable {
    var identifier: String { get }
    func search(
        query: [Float],
        dimensions: Int,
        limit: Int,
        next: () throws -> VectorIndexCandidate?
    ) throws -> [VectorIndexMatch]
}

public struct ExactVectorIndex: VectorIndex {
    public let identifier = "sqlite-exact-cosine-v1"

    public init() {}

    public func search(
        query: [Float],
        dimensions: Int,
        limit: Int,
        next: () throws -> VectorIndexCandidate?
    ) throws -> [VectorIndexMatch] {
        let norm = sqrt(query.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0, dimensions == query.count, limit > 0 else {
            throw DataLayerError.invalidEmbedding
        }
        var top = BoundedVectorMatches(limit: limit)
        while let row = try next() {
            if Task.isCancelled { throw CancellationError() }
            let dot = try VectorCodec.dotProduct(row.vector, query: query, expectedDimensions: dimensions)
            top.insert(id: row.id, score: dot / norm)
        }
        return top.sorted()
    }

    /// One matrix-vector product over a decoded, already normalized workspace.
    /// `matrix` is row-major and contains `ids.count * dimensions` values.
    static func topMatches(
        query: [Float], ids: [String], matrix: [Float], dimensions: Int, limit: Int
    ) throws -> [VectorIndexMatch] {
        let rows = ids.count
        guard rows > 0, dimensions == query.count, matrix.count == rows * dimensions, limit > 0 else {
            throw DataLayerError.invalidEmbedding
        }
        let norm = sqrt(query.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0 else { throw DataLayerError.invalidEmbedding }
        var scores = [Float](repeating: 0, count: rows)
        matrix.withUnsafeBufferPointer { matrixBuffer in
            query.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    cblas_sgemv(
                        CblasRowMajor, CblasNoTrans,
                        Int32(rows), Int32(dimensions), 1,
                        matrixBuffer.baseAddress!, Int32(dimensions),
                        queryBuffer.baseAddress!, 1, 0,
                        scoreBuffer.baseAddress!, 1
                    )
                }
            }
        }
        let scale = 1 / norm
        var top = BoundedVectorMatches(limit: limit)
        for index in 0..<rows {
            if Task.isCancelled { throw CancellationError() }
            top.insert(id: ids[index], score: Double(scores[index]) * scale)
        }
        return top.sorted()
    }
}

private struct BoundedVectorMatches {
    let limit: Int
    private var heap: [VectorIndexMatch] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(id: String, score: Double) {
        let candidate = VectorIndexMatch(id: id, score: score)
        if heap.count < limit {
            heap.append(candidate)
            siftUp(from: heap.count - 1)
        } else if better(candidate, than: heap[0]) {
            heap[0] = candidate
            siftDown(from: 0)
        }
    }

    func sorted() -> [VectorIndexMatch] {
        heap.sorted { better($0, than: $1) }
    }

    private func better(_ lhs: VectorIndexMatch, than rhs: VectorIndexMatch) -> Bool {
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id
    }

    private func worse(_ lhs: VectorIndexMatch, than rhs: VectorIndexMatch) -> Bool {
        lhs.score != rhs.score ? lhs.score < rhs.score : lhs.id > rhs.id
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard worse(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var child = left
            if right < heap.count, worse(heap[right], than: heap[left]) { child = right }
            guard worse(heap[child], than: heap[parent]) else { return }
            heap.swapAt(parent, child)
            parent = child
        }
    }
}
