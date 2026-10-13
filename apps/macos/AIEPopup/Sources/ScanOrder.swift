import Foundation

/// A snapshot of recency drives both local analysis and model scan queues.
/// Missing Spotlight metadata falls back to modification time; never use filesystem atime.
enum ScanOrder {
    static func precedes(_ lhs: IndexedFile, _ rhs: IndexedFile) -> Bool {
        let left = lhs.lastOpenedAt ?? lhs.mtime
        let right = rhs.lastOpenedAt ?? rhs.mtime
        if left != right { return left > right }
        return lhs.path < rhs.path
    }
}
