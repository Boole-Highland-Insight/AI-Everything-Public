import Foundation

struct ReuseSlide: Equatable {
    let title: String
    let bullets: [String]
}

/// Writes a small, standards-based OOXML deck. Every title and bullet remains editable.
enum ReusePPTX {
    static func render(slides input: [ReuseSlide], fallbackMarkdown: String, to destination: URL) -> Bool {
        let slides = input.isEmpty ? slidesFromMarkdown(fallbackMarkdown) : input
        guard !slides.isEmpty else { return false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("aie-pptx-\(UUID().uuidString)")
        let package = work.appendingPathComponent("package")
        let archive = work.appendingPathComponent("result.pptx")
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            try writePackage(slides: slides, at: package)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = ["-q", "-r", archive.path, "."]
            zip.currentDirectoryURL = package
            zip.standardOutput = FileHandle.nullDevice
            zip.standardError = FileHandle.nullDevice
            try zip.run()
            zip.waitUntilExit()
            guard zip.terminationStatus == 0, fm.fileExists(atPath: archive.path) else { return false }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: archive, to: destination)
            return true
        } catch {
            return false
        }
    }

    static func slidesFromMarkdown(_ markdown: String) -> [ReuseSlide] {
        var slides: [ReuseSlide] = []
        var title = "概览"
        var bullets: [String] = []
        func flush() {
            let clean = bullets.filter { !$0.isEmpty }
            if !title.isEmpty || !clean.isEmpty {
                slides.append(ReuseSlide(title: title.isEmpty ? "内容" : title, bullets: Array(clean.prefix(8))))
            }
            bullets = []
        }
        for raw in markdown.split(whereSeparator: \.isNewline).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if !bullets.isEmpty || title != "概览" { flush() }
                title = line.drop(while: { $0 == "#" || $0 == " " }).description
            } else {
                let clean = line.replacingOccurrences(
                    of: #"^[-*+]\s+|^\d+[.)]\s+"#, with: "", options: .regularExpression
                )
                if !clean.hasPrefix("![") { bullets.append(String(clean.prefix(260))) }
            }
        }
        flush()
        return Array(slides.filter { !$0.title.isEmpty || !$0.bullets.isEmpty }.prefix(40))
    }

    private static func writePackage(slides: [ReuseSlide], at root: URL) throws {
        let fm = FileManager.default
        let directories = [
            "_rels", "docProps", "ppt/_rels", "ppt/slides", "ppt/slides/_rels",
            "ppt/slideMasters", "ppt/slideMasters/_rels", "ppt/slideLayouts",
            "ppt/slideLayouts/_rels", "ppt/theme",
        ]
        for directory in directories {
            try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try put(contentTypes(slideCount: slides.count), "[Content_Types].xml", root)
        try put(rootRels, "_rels/.rels", root)
        try put(appProps(slideCount: slides.count), "docProps/app.xml", root)
        try put(coreProps, "docProps/core.xml", root)
        try put(presentation(slideCount: slides.count), "ppt/presentation.xml", root)
        try put(presentationRels(slideCount: slides.count), "ppt/_rels/presentation.xml.rels", root)
        try put(slideMaster, "ppt/slideMasters/slideMaster1.xml", root)
        try put(slideMasterRels, "ppt/slideMasters/_rels/slideMaster1.xml.rels", root)
        try put(slideLayout, "ppt/slideLayouts/slideLayout1.xml", root)
        try put(slideLayoutRels, "ppt/slideLayouts/_rels/slideLayout1.xml.rels", root)
        try put(theme, "ppt/theme/theme1.xml", root)
        for (index, slide) in slides.enumerated() {
            try put(slideXML(slide, number: index + 1), "ppt/slides/slide\(index + 1).xml", root)
            try put(slideRels, "ppt/slides/_rels/slide\(index + 1).xml.rels", root)
        }
    }

    private static func put(_ text: String, _ relative: String, _ root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(relative), options: .atomic)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func contentTypes(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\(slides)</Types>
        """
    }

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    private static func appProps(slideCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>AI Everything</Application><PresentationFormat>宽屏</PresentationFormat><Slides>\(slideCount)</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides><ScaleCrop>false</ScaleCrop><AppVersion>1.0</AppVersion></Properties>
        """
    }

    private static var coreProps: String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>咔哒生成的演示文稿</dc:title><dc:creator>AI Everything</dc:creator><cp:lastModifiedBy>AI Everything</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified></cp:coreProperties>
        """
    }

    private static func presentation(slideCount: Int) -> String {
        let ids = (1...slideCount).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle/></p:presentation>
        """
    }

    private static func presentationRels(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(slides)</Relationships>
        """
    }

    private static let slideMaster = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="简洁"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
    """

    private static let slideMasterRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
    """

    private static let slideLayout = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="空白"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """

    private static let slideLayoutRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
    """

    private static let slideRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
    """

    private static func slideXML(_ slide: ReuseSlide, number: Int) -> String {
        let title = escape(slide.title)
        let bullets = slide.bullets.prefix(8).map { bullet in
            "<a:p><a:pPr marL=\"342900\" indent=\"-285750\"><a:buChar char=\"•\"/></a:pPr><a:r><a:rPr lang=\"zh-CN\" sz=\"2200\"/><a:t>\(escape(bullet))</a:t></a:r><a:endParaRPr lang=\"zh-CN\" sz=\"2200\"/></a:p>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F7F8FA"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="标题 \(number)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="762000" y="685800"/><a:ext cx="10668000" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square"/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="3000" b="1"><a:solidFill><a:srgbClr val="172033"/></a:solidFill></a:rPr><a:t>\(title)</a:t></a:r><a:endParaRPr lang="zh-CN" sz="3000"/></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="正文 \(number)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="762000" y="1828800"/><a:ext cx="10668000" cy="4114800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" rIns="0" tIns="0" bIns="0"/><a:lstStyle/>\(bullets)<a:p><a:endParaRPr lang="zh-CN" sz="2200"/></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="AI Everything"><a:themeElements><a:clrScheme name="Neutral"><a:dk1><a:srgbClr val="172033"/></a:dk1><a:lt1><a:srgbClr val="F7F8FA"/></a:lt1><a:dk2><a:srgbClr val="334155"/></a:dk2><a:lt2><a:srgbClr val="E8EDF3"/></a:lt2><a:accent1><a:srgbClr val="75A7D9"/></a:accent1><a:accent2><a:srgbClr val="87BFA5"/></a:accent2><a:accent3><a:srgbClr val="A8B4C4"/></a:accent3><a:accent4><a:srgbClr val="B8A8CE"/></a:accent4><a:accent5><a:srgbClr val="D1A781"/></a:accent5><a:accent6><a:srgbClr val="8CB9C5"/></a:accent6><a:hlink><a:srgbClr val="4B78A8"/></a:hlink><a:folHlink><a:srgbClr val="765A91"/></a:folHlink></a:clrScheme><a:fontScheme name="System"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface="PingFang SC"/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface="PingFang SC"/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Clean"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
}

enum ReusePPTXDiagnostics {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--verify-reuse-pptx" else { return false }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("aie-reuse-pptx-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: output) }
        precondition(ReusePPTX.render(
            slides: [
                ReuseSlide(title: "方案概览", bullets: ["保留原始事实", "生成可编辑页面"]),
                ReuseSlide(title: "下一步", bullets: ["确认内容", "继续修改"]),
            ],
            fallbackMarkdown: "",
            to: output
        ))
        let document = PresentationReader.read(path: output.path)
        precondition(document?.total == 2)
        precondition(document?.text.contains("方案概览") == true)
        precondition(document?.text.contains("继续修改") == true)
        print("Reuse PPTX checks passed: valid package, two editable text slides.")
        return true
    }
}
