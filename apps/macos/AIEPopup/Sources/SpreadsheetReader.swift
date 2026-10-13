import Foundation
import AIEData

/// Reads OOXML values locally. Never evaluates formulas, follows links, or modifies the workbook.
enum SpreadsheetReader {
    static let version = "xlsx-1"
    struct Row { let number: Int; let text: String }
    struct Sheet {
        let name: String
        let member: String
        let state: String
        let rows: [Row]
    }
    struct Document {
        let sheets: [Sheet]
        let total: Int
        let partial: Bool
        var record: [String: Any] {
            ["parserVersion": version, "sheetCount": total, "indexedSheetCount": sheets.count,
             "coverage": partial ? "partial" : "all_cell_values", "formulasEvaluated": false,
             "sheets": sheets.map { ["name": $0.name, "member": $0.member, "state": $0.state, "rowCount": $0.rows.count] }]
        }
        var text: String { sheets.map { "工作表：\($0.name)\n" + $0.rows.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n") }
        func preview(limit: Int) -> String {
            let budget = max(1, limit / max(1, sheets.count) - 30)
            return String(sheets.map { "工作表：\($0.name)\n" + String($0.rows.map(\.text).joined(separator: "\n").prefix(budget)) }.joined(separator: "\n\n").prefix(limit))
        }
        var blocks: [ContentBlock] {
            var result: [ContentBlock] = []
            for (sheetIndex, sheet) in sheets.enumerated() {
                // Repeat the first populated row as context, without assuming it is a formal header.
                let firstRow = sheet.rows.first.map { String($0.text.prefix(320)) } ?? "空工作表"
                var group: [Row] = []
                var length = 0
                func flush() {
                    guard let first = group.first, let last = group.last else { return }
                    let label = "工作表：\(sheet.name) · 第 \(first.number)–\(last.number) 行"
                    let context = first.number == sheet.rows.first?.number ? "" : "\n首个非空行：\(firstRow)"
                    let body = group.map(\.text).joined(separator: "\n")
                    let key = "sheet-\(sheetIndex + 1)-rows-\(first.number)-\(last.number)"
                    // A single oversized row is split without discarding any cell text.
                    let pieces = StructuralChunker.text(body, prefix: key, kind: "sheet_rows", limit: 1100)
                    for (part, piece) in pieces.enumerated() {
                        let location: [String: Any] = ["sheet": sheet.name, "member": sheet.member, "state": sheet.state,
                                                      "rowStart": first.number, "rowEnd": last.number, "part": part,
                                                      "bodyCharacterRange": piece.locationJSON ?? ""]
                        let encoded = try? JSONSerialization.data(withJSONObject: location, options: [.sortedKeys])
                        let text = label + context + "\n" + piece.text
                        result.append(ContentBlock(key: key + "-\(part)", kind: "sheet_rows",
                                                   locationJSON: encoded.flatMap { String(data: $0, encoding: .utf8) }, text: text,
                                                   tags: [sheet.name], summary: String(text.prefix(180)), parserVersion: version))
                    }
                    group.removeAll(); length = 0
                }
                for row in sheet.rows {
                    if !group.isEmpty && (length + row.text.count > 1000 || group.count >= 20) { flush() }
                    group.append(row); length += row.text.count + 1
                }
                flush()
                if sheet.rows.isEmpty {
                    result.append(ContentBlock(key: "sheet-\(sheetIndex + 1)-empty", kind: "sheet_rows", text: "工作表：\(sheet.name)（空工作表）", tags: [sheet.name], parserVersion: version))
                }
            }
            return result
        }
    }

    static func read(path: String) -> Document? {
        guard let names = ArchiveEntryReader.members(path: path) else { return nil }
        let available = Set(names)
        var remainingBytes = 64 * 1024 * 1024
        func readXML(_ member: String, shared: [String] = [], rowLimit: Int = 50_000, textLimit: Int = 4_000_000) -> BookXML? {
            guard remainingBytes > 0, let bytes = ArchiveEntryReader.data(path: path, member: member, maxBytes: min(32 * 1024 * 1024, remainingBytes)) else { return nil }
            remainingBytes -= bytes.count
            let reader = BookXML(shared: shared, rowLimit: rowLimit, textLimit: textLimit)
            let parser = XMLParser(data: bytes)
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            return parser.parse() ? reader : nil
        }
        guard let workbook = readXML("xl/workbook.xml"), let rels = readXML("xl/_rels/workbook.xml.rels"), !workbook.sheets.isEmpty else { return nil }
        var shared: [String] = []
        if available.contains("xl/sharedStrings.xml") {
            guard let strings = readXML("xl/sharedStrings.xml") else { return nil }
            shared = strings.strings
        }
        var sheets: [Sheet] = [], partial = workbook.sheets.count > 100, remainingRows = 50_000, remainingCharacters = 4_000_000
        for sheet in workbook.sheets.prefix(100) {
            guard let target = rels.relationships[sheet.id] else { partial = true; continue }
            let member = target.hasPrefix("/xl/") ? String(target.dropFirst()) : "xl/" + target
            // Read archive members only; no filesystem extraction, traversal, or external relationships.
            guard member.hasPrefix("xl/worksheets/"), !member.split(separator: "/").contains(".."), available.contains(member), remainingRows > 0, remainingCharacters > 0,
                  let xml = readXML(member, shared: shared, rowLimit: remainingRows, textLimit: remainingCharacters) else { partial = true; continue }
            remainingRows -= xml.rows.count
            remainingCharacters -= xml.characterCount
            partial = partial || xml.truncated
            sheets.append(Sheet(name: sheet.name, member: member, state: sheet.state, rows: xml.rows))
        }
        guard !sheets.isEmpty else { return nil }
        return Document(sheets: sheets, total: workbook.sheets.count, partial: partial)
    }

    private final class BookXML: NSObject, XMLParserDelegate {
        var sheets: [(name: String, id: String, state: String)] = []
        var relationships: [String: String] = [:]
        var strings: [String] = [], rows: [Row] = []
        var truncated = false
        private let shared: [String], rowLimit: Int, textLimit: Int
        var characterCount = 0
        private var rowNumber = 0, cells: [String] = [], cellAddress = "", cellType = ""
        private var value = "", inline = "", formula = "", sharedString = ""
        private var inShared = false, inCell = false, reading = "", phoneticDepth = 0
        init(shared: [String], rowLimit: Int, textLimit: Int) { self.shared = shared; self.rowLimit = rowLimit; self.textLimit = textLimit }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let tag = name.split(separator: ":").last.map(String.init) ?? name
            switch tag {
            case "sheet": if let name = attributes["name"], let id = attributes["r:id"] { sheets.append((name, id, attributes["state"] ?? "visible")) }
            case "Relationship": if attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"] { relationships[id] = target }
            case "si": inShared = true; sharedString = ""
            case "rPh": phoneticDepth += 1
            case "row": rowNumber = Int(attributes["r"] ?? "") ?? (rowNumber + 1); cells = []
            case "c": inCell = true; cellAddress = attributes["r"] ?? "行\(rowNumber)"; cellType = attributes["t"] ?? "n"; value = ""; inline = ""; formula = ""
            case "v", "t", "f": reading = tag
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard phoneticDepth == 0 else { return }
            if reading == "t" { if inShared { sharedString += string } else if inCell { inline += string } }
            else if inCell && reading == "v" { value += string }
            else if inCell && reading == "f" { formula += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let tag = name.split(separator: ":").last.map(String.init) ?? name
            switch tag {
            case "v", "t", "f": reading = ""
            case "rPh": phoneticDepth -= 1
            case "si": strings.append(sharedString); inShared = false
            case "c":
                var text = value
                if cellType == "s" {
                    if let index = Int(value), shared.indices.contains(index) { text = shared[index] }
                    else { text = "[共享字符串缺失]"; truncated = true }
                } else if cellType == "inlineStr" { text = inline }
                else if cellType == "b" { text = value == "1" ? "TRUE" : "FALSE" }
                if !formula.isEmpty { text = "\(text.isEmpty ? "无缓存结果" : "缓存值：" + text)（公式：=\(formula)）" }
                if !text.isEmpty {
                    let cell = "\(cellAddress)：\(text)"
                    let remaining = max(0, textLimit - characterCount)
                    if cell.count > remaining { truncated = true }
                    if remaining > 0 { cells.append(String(cell.prefix(remaining))); characterCount += min(remaining, cell.count) }
                }
                inCell = false
            case "row":
                if !cells.isEmpty {
                    if rows.count < rowLimit { rows.append(Row(number: rowNumber, text: cells.joined(separator: " | "))) }
                    else { truncated = true }
                }
            default: break
            }
        }
    }
}
