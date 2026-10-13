import Foundation

/// Lossless character ranges. Prefer headings/paragraphs, then sentences and whitespace;
/// only an oversized unbroken run falls back to a hard character boundary.
public enum StructuralChunker {
    public static func text(_ text: String, prefix: String = "text", parent: String = "document", kind: String = "paragraph", page: Int? = nil, limit: Int = 1600) -> [ContentBlock] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let maximum = max(1, limit), minimum = max(1, maximum / 3)
        var paragraphs = Set<Int>(), sentences = Set<Int>(), headings: [(Int, String)] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line), trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { paragraphs.insert(min(chars.count, offset + string.count + 1)) }
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil { headings.append((offset, trimmed)) }
            offset += string.count + 1
        }
        for index in chars.indices where "。！？!?；;\n".contains(chars[index]) || (chars[index] == "." && (index + 1 == chars.count || chars[index + 1].isWhitespace)) { sentences.insert(index + 1) }
        let paragraphEnds = paragraphs.sorted(), sentenceEnds = sentences.sorted()
        func lastBoundary(_ sorted: [Int], floor: Int, ceiling: Int) -> Int? {
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] <= ceiling { low = mid + 1 } else { high = mid }
            }
            return low > 0 && sorted[low - 1] >= floor ? sorted[low - 1] : nil
        }
        var cursor = 0, headingIndex = -1, blocks: [ContentBlock] = []
        while cursor < chars.count {
            let ceiling = min(chars.count, cursor + maximum)
            let floor = min(ceiling, cursor + minimum)
            while headingIndex + 1 < headings.count && headings[headingIndex + 1].0 <= cursor { headingIndex += 1 }
            let nextHeading = headingIndex + 1 < headings.count && headings[headingIndex + 1].0 <= ceiling ? headings[headingIndex + 1].0 : nil
            let end: Int
            if let nextHeading { end = nextHeading }
            else if ceiling == chars.count { end = ceiling }
            else if let boundary = lastBoundary(paragraphEnds, floor: floor, ceiling: ceiling) { end = boundary }
            else if let boundary = lastBoundary(sentenceEnds, floor: floor, ceiling: ceiling) { end = boundary }
            else if let space = (floor..<ceiling).last(where: { chars[$0].isWhitespace }) { end = space + 1 }
            else { end = ceiling }
            let part = String(chars[cursor..<end])
            var location: [String: Any] = ["characterStart": cursor, "characterEnd": end, "chunker": "structure-1"]
            if headingIndex >= 0 { location["section"] = headings[headingIndex].1 }
            let encoded = try? JSONSerialization.data(withJSONObject: location, options: [.sortedKeys])
            blocks.append(ContentBlock(key: "\(prefix)-\(blocks.count)", parentKey: parent, kind: kind, page: page,
                                       locationJSON: encoded.flatMap { String(data: $0, encoding: .utf8) }, text: part,
                                       summary: String(part.prefix(180)), parserVersion: "structure-1"))
            cursor = end
        }
        return blocks
    }

    public static func page(_ text: String, key: String, kind: String, page: Int, tags: [String] = [], locationJSON: String? = nil, parserVersion: String) -> [ContentBlock] {
        if text.count <= 1600 {
            return [ContentBlock(key: key, kind: kind, page: page, locationJSON: locationJSON, text: text, tags: tags,
                                 summary: String(text.prefix(180)), parserVersion: parserVersion)]
        }
        let parent = ContentBlock(key: key, kind: kind, page: page, locationJSON: locationJSON, text: "", tags: tags,
                                  summary: String(text.prefix(180)), parserVersion: parserVersion)
        return [parent] + self.text(text, prefix: key + "-part", parent: key, kind: kind + "_text", page: page)
    }
}
