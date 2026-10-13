import Foundation
import AIEData

enum StructuredFileReader {
    static let version = "structured-file-1"
    static let extensions: Set<String> = ["msg", "xml", "rar", "zip", "7z", "tar", "gz"]
    struct Document {
        let blocks: [ContentBlock]
        let coverage: String
        var text: String { blocks.map(\.text).joined(separator: "\n\n") }
        var record: [String: Any] { ["parserVersion": version, "coverage": coverage, "blockCount": blocks.count] }
        func preview(limit: Int) -> String {
            let budget=max(1,limit/max(1,blocks.count)-1)
            return String(blocks.map { String($0.text.prefix(budget)) }.joined(separator: "\n").prefix(limit))
        }
    }
    static func read(path: String) -> Document? {
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        if ext == "msg" {
            guard let bytes=limitedFile(path, limit:32*1024*1024), let text=MessageReader.text(bytes) else { return nil }
            return Document(blocks: parts(text, key:"mail",kind:"message_body"),coverage:"message_body_without_attachments")
        }
        if ext == "xml" {
            guard let bytes=limitedFile(path,limit:4*1024*1024),let text=xmlText(bytes) else { return nil }
            return Document(blocks:parts(text,key:"xml",kind:"xml_text"),coverage:"xml_text_and_attributes")
        }
        guard extensions.contains(ext), let bytes=runTar(["-tf",path], limit:2*1024*1024), let list=String(data:bytes,encoding:.utf8) else { return nil }
        let names=list.split(separator:"\n").map(String.init)
        var blocks:[ContentBlock]=[], partial=names.count>200, totalBytes=0
        for (index,member) in names.prefix(200).enumerated() {
            guard !member.hasSuffix("/") else { continue }
            let kind=URL(fileURLWithPath:member).pathExtension.lowercased()
            // Unsupported members stay listed as uncovered; no recursive extraction or execution.
            guard ["md","txt","csv","tsv","json","xml"].contains(kind), !member.hasPrefix("/"),
                  !member.split(separator:"/").contains(".."), totalBytes<16*1024*1024,
                  let data=runTar(["-xOf",path,"--",member],limit:min(4*1024*1024,16*1024*1024-totalBytes)) else { partial=true;continue }
            totalBytes+=data.count
            guard let text=kind == "xml" ? xmlText(data) : String(data:data,encoding:.utf8) else { partial=true;continue }
            blocks += parts(text,key:"archive-\(index)",kind:"archive_text",member:member)
        }
        guard !blocks.isEmpty else { return nil }
        return Document(blocks:blocks,coverage:partial ? "partial" : "all_supported_member_text")
    }
    private static func parts(_ text:String,key:String,kind:String,member:String?=nil)->[ContentBlock] {
        StructuralChunker.text(text,prefix:key,kind:kind,limit:1400).map { part in
            var block=part;block.parserVersion=version
            if let member {
                var location=(part.locationJSON.flatMap { $0.data(using:.utf8) }.flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
                location["archiveMember"]=member
                block.locationJSON=(try? JSONSerialization.data(withJSONObject:location,options:[.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) }
                block.text="包内文件：\(member)\n"+part.text
                block.summary=String(block.text.prefix(180))
            }
            return block
        }
    }
    private static func limitedFile(_ path:String,limit:Int)->Data? {
        guard let file=FileHandle(forReadingAtPath:path) else{return nil};defer{try? file.close()}
        guard let bytes=try? file.read(upToCount:limit+1), bytes.count<=limit else{return nil};return bytes
    }
    private static func runTar(_ arguments:[String],limit:Int)->Data? {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/tar");process.arguments=arguments
        var env=ProcessInfo.processInfo.environment;env["LC_ALL"]="en_US.UTF-8";process.environment=env
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=FileHandle.nullDevice;process.standardInput=FileHandle.nullDevice
        do{try process.run()}catch{return nil}
        var bytes=Data(),exceeded=false
        while let chunk=try? pipe.fileHandleForReading.read(upToCount:65536), !chunk.isEmpty {
            if !exceeded && bytes.count+chunk.count>limit {exceeded=true;process.terminate()}
            if !exceeded {bytes.append(chunk)}
        }
        process.waitUntilExit();return !exceeded && process.terminationStatus==0 ? bytes:nil
    }
    private static func xmlText(_ data:Data)->String? {
        let reader=XMLText(),parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false;parser.delegate=reader
        guard parser.parse() else{return nil};return reader.lines.joined(separator:"\n")
    }
    private final class XMLText:NSObject,XMLParserDelegate {
        var lines:[String]=[],stack:[String]=[],value=""
        func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
            flush();stack.append(name)
            for key in attributes.keys.sorted() where !key.hasPrefix("xmlns") {lines.append(stack.joined(separator:"/")+" @"+key+"："+attributes[key]!)}
        }
        func parser(_ parser:XMLParser,foundCharacters text:String){value+=text}
        func parser(_ parser:XMLParser,foundCDATA data:Data){value+=String(data:data,encoding:.utf8) ?? ""}
        func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?){flush();if !stack.isEmpty{stack.removeLast()}}
        private func flush(){let text=value.trimmingCharacters(in:.whitespacesAndNewlines);if !text.isEmpty{lines.append(stack.joined(separator:"/")+"："+text)};value=""}
    }
}
