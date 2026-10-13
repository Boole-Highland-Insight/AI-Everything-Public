import Foundation

/// Stable on-disk vector representation. Model adapters may compute in Float32, while storage is
/// normalized Float16 so cosine search becomes a dot product and the BLOB remains compact.
enum VectorCodec {
    static let format = "f16-le-v1-normalized"
    private static let magic: [UInt8] = [0x41, 0x49, 0x45, 0x56] // AIEV
    private static let headerSize = 12

    static func encode(_ values: [Float]) throws -> Data {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw DataLayerError.invalidEmbedding
        }
        let squaredNorm = values.reduce(Double.zero) { $0 + Double($1) * Double($1) }
        guard squaredNorm > 0 else { throw DataLayerError.invalidEmbedding }
        let divisor = Float(sqrt(squaredNorm))
        var data = Data(capacity: headerSize + values.count * 2)
        data.append(contentsOf: magic)
        data.append(1) // format version
        data.append(1) // scalar type: IEEE-754 binary16
        data.append(1) // flags: L2-normalized
        data.append(0)
        append(UInt32(values.count), to: &data)
        for value in values {
            append(halfBits(value / divisor), to: &data)
        }
        return data
    }

    static func decode(_ data: Data, expectedDimensions: Int? = nil) throws -> [Float] {
        if data.count >= headerSize, Array(data.prefix(4)) == magic {
            guard data[4] == 1, data[5] == 1, data[6] & 1 == 1 else {
                throw DataLayerError.invalidEmbedding
            }
            let dimensions = Int(readUInt32(data, offset: 8))
            guard dimensions > 0, data.count == headerSize + dimensions * 2,
                  expectedDimensions == nil || expectedDimensions == dimensions else {
                throw DataLayerError.invalidEmbedding
            }
            var result: [Float] = []
            result.reserveCapacity(dimensions)
            for index in 0..<dimensions {
                let offset = headerSize + index * 2
                let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
                let value = floatValue(bits)
                guard value.isFinite else { throw DataLayerError.invalidEmbedding }
                result.append(value)
            }
            let norm = sqrt(result.reduce(Double.zero) { $0 + Double($1) * Double($1) })
            guard norm > 0 else { throw DataLayerError.invalidEmbedding }
            let divisor = Float(norm)
            return result.map { $0 / divisor }
        }

        // Read-only compatibility for the v1 JSON BLOB. New writes never use this branch.
        let legacy = try JSONDecoder().decode([Float].self, from: data)
        guard expectedDimensions == nil || legacy.count == expectedDimensions else {
            throw DataLayerError.invalidEmbedding
        }
        return legacy
    }

    static func isCurrent(_ data: Data) -> Bool {
        data.count >= headerSize && Array(data.prefix(4)) == magic
    }

    /// Appends the stored Float16 payload as Float32 without a second normalization.
    /// This matches `dotProduct`, so a cached workspace ranks identically to a streaming scan.
    static func appendPayload(_ data: Data, expectedDimensions: Int, to matrix: inout [Float]) throws {
        guard data.count == headerSize + expectedDimensions * 2,
              data.starts(with: magic),
              data[4] == 1, data[5] == 1, data[6] & 1 == 1,
              Int(readUInt32(data, offset: 8)) == expectedDimensions else {
            throw DataLayerError.invalidEmbedding
        }
        let start = matrix.count
        matrix.append(contentsOf: repeatElement(0, count: expectedDimensions))
        data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<expectedDimensions {
                let offset = headerSize + index * 2
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                matrix[start + index] = floatValue(bits)
            }
        }
    }

    /// Computes against the normalized Float16 payload without allocating a Float32 array for
    /// every candidate. Search validates the format namespace before entering this hot path.
    static func dotProduct(_ data: Data, query: [Float], expectedDimensions: Int) throws -> Double {
        guard expectedDimensions == query.count,
              data.count == headerSize + expectedDimensions * 2,
              data.count >= headerSize,
              Array(data.prefix(4)) == magic,
              data[4] == 1, data[5] == 1, data[6] & 1 == 1,
              Int(readUInt32(data, offset: 8)) == expectedDimensions else {
            throw DataLayerError.invalidEmbedding
        }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var dot = Double.zero
            for index in 0..<expectedDimensions {
                let offset = headerSize + index * 2
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                dot += Double(floatValue(bits)) * Double(query[index])
            }
            return dot
        }
    }

    @inline(__always) private static func halfBits(_ value: Float) -> UInt16 {
        #if arch(arm64)
        return Float16(value).bitPattern
        #else
        return Binary16.encode(value)
        #endif
    }

    @inline(__always) private static func floatValue(_ bits: UInt16) -> Float {
        #if arch(arm64)
        return Float(Float16(bitPattern: bits))
        #else
        return Binary16.decode(bits)
        #endif
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        let little = value.littleEndian
        withUnsafeBytes(of: little) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        let little = value.littleEndian
        withUnsafeBytes(of: little) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
