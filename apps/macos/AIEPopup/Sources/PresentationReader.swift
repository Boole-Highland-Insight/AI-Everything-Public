import Foundation

/// Local, per-slide evidence. No model calls and no extraction onto the filesystem.
enum PresentationReader {
    static let version = "1"

    struct Slide {
        let number: Int
        let member: String
        let text: String
        let tags: [String]
        let evidence: [String]
        let pictureCount: Int
        let textTruncated: Bool
        var record: [String: Any] {
            ["page": number, "member": member, "text": text, "tags": tags,
             "evidence": evidence, "pictureCount": pictureCount, "textTruncated": textTruncated]
        }
        var searchableText: String { (["第 \(number) 页"] + tags + [text]).joined(separator: "\n") }
    }

    struct Document {
        let slides: [Slide]
        let total: Int
        var record: [String: Any] {
            ["parserVersion": version, "slideCount": total, "indexedSlideCount": slides.count,
             "coverage": slides.count == total && !slides.contains(where: \.textTruncated) ? "all_slide_text_and_shapes" : "partial",
             "imageTextRecognized": false, "slides": slides.map(\.record)]
        }
        var text: String { slides.map(\.searchableText).joined(separator: "\n\n") }
        /// Distribute the cloud preview across slides instead of spending its budget on the cover.
        func preview(limit: Int) -> String {
            guard !slides.isEmpty else { return "" }
            let perSlide = max(1, limit / slides.count - 20)
            return String(slides.map { "第 \($0.number) 页：" + String(($0.tags.joined(separator: " ") + " " + $0.text).prefix(perSlide)) }
                .joined(separator: "\n").prefix(limit))
        }
    }

    static func read(path: String) -> Document? {
        guard let members = ArchiveEntryReader.members(path: path) else { return nil }
        let available = Set(members)
        var ordered: [String] = []
        if let presentation = parse(path: path, member: "ppt/presentation.xml"),
           let rels = parse(path: path, member: "ppt/_rels/presentation.xml.rels") {
            ordered = presentation.slideIDs.compactMap { id in
                guard let target = rels.relationships[id], !target.hasPrefix("/") else { return nil }
                let member = "ppt/" + target
                return available.contains(member) && member.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil ? member : nil
            }
        }
        if ordered.isEmpty {
            ordered = members.filter { $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        guard !ordered.isEmpty else { return nil }
        var slides: [Slide] = []
        for (index, member) in ordered.prefix(500).enumerated() {
            guard let xml = parse(path: path, member: member) else { continue }
            let text = xml.paragraphs.joined(separator: "\n")
            let procedural = text.range(of: "流程|步骤|审批|提交|process|workflow", options: [.regularExpression, .caseInsensitive]) != nil
            var tags: [String] = []
            var evidence: [String] = []
            // Connector-shaped numbered badges alone are not a flowchart.
            if xml.flowShapes > 0 || (procedural && (xml.arrows > 0 || xml.connectors >= 3)) {
                tags = ["流程图", "流程示意图", "flowchart"]
                evidence = ["流程形状 \(xml.flowShapes)，箭头形状 \(xml.arrows)，连接线 \(xml.connectors)；结构推断"]
            } else if xml.connectors >= 3 {
                tags = ["连接关系图"]
                evidence = ["连接线 \(xml.connectors)；结构推断"]
            }
            slides.append(Slide(number: index + 1, member: member, text: String(text.prefix(32000)),
                                tags: tags, evidence: evidence, pictureCount: xml.pictures, textTruncated: text.count > 32000))
        }
        guard !slides.isEmpty else { return nil }
        return Document(slides: slides, total: ordered.count)
    }

    private static func parse(path: String, member: String) -> SlideXML? {
        guard let data = ArchiveEntryReader.data(path: path, member: member) else { return nil }
        let reader = SlideXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        return parser.parse() ? reader : nil
    }

    private final class SlideXML: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        var paragraph = ""
        var inText = false
        var flowShapes = 0
        var arrows = 0
        var connectors = 0
        var pictures = 0
        var slideIDs: [String] = []
        var relationships: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "t": inText = true
            case "br": paragraph += "\n"
            case "cxnSp": connectors += 1
            case "pic": pictures += 1
            case "sldId": if let id = attributes["r:id"] { slideIDs.append(id) }
            case "Relationship":
                if attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"] {
                    relationships[id] = target
                }
            case "prstGeom":
                let shape = attributes["prst"] ?? ""
                if shape.hasPrefix("flowChart") && shape != "flowChartConnector" && shape != "flowChartOfflineStorage" { flowShapes += 1 }
                if shape.lowercased().contains("arrow") { arrows += 1 }
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { paragraph += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "t" { inText = false }
            if local == "p" {
                let clean = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { paragraphs.append(clean) }
                paragraph = ""
            }
        }
    }
}
