import Foundation

/// Reciprocal rank fusion. Each source contributes once per file; scores need no shared scale.
public enum RankFusion {
    public static func fuse(_ lists: [[String]], limit: Int = 40, constant: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        var order: [String: Int] = [:]
        for list in lists {
            var seen = Set<String>(), position = 0
            for id in list where seen.insert(id).inserted {
                position += 1
                if order[id] == nil { order[id] = order.count }
                scores[id, default: 0] += 1 / (max(1, constant) + Double(position))
            }
        }
        return Array(scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0, default: 0] > scores[$1, default: 0] }
            return order[$0, default: 0] < order[$1, default: 0]
        }.prefix(max(0, limit)))
    }
}
