import Foundation

/// Identifier fragments are literal digit runs, never a semantic similarity decision.
public enum NumericSearch {
    private static let numbers = try! NSRegularExpression(pattern: "[0-9]{2,}")
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func term(_ text: String) -> String? {
        let value = normalized(text)
        return value.count >= 2 && value.utf8.allSatisfy { (48...57).contains($0) } ? value : nil
    }
    public static func runs(_ text: String) -> [String] {
        let text = normalized(text)
        return numbers.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    public static func grams(_ digits: String, width: Int) -> [String] {
        let bytes = Array(digits.utf8)
        guard bytes.count >= width else { return [] }
        return (0...(bytes.count - width)).map { String(decoding: bytes[$0..<($0 + width)], as: UTF8.self) }
    }
    public static func contains(_ term: String, in text: String) -> Bool {
        text.range(of: term, options: [.widthInsensitive]) != nil
    }
    /// Prefer an entire identifier, then its prefix, then an interior fragment.
    public static func strength(_ term: String, in text: String) -> Int {
        runs(text).map { $0 == term ? 3 : ($0.hasPrefix(term) ? 2 : ($0.contains(term) ? 1 : 0)) }.max() ?? 0
    }
}
