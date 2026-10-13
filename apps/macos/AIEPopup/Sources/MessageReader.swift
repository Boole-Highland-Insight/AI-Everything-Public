import Foundation

/// Reads only the top-level MAPI streams of a user-selected .msg file.
/// Embedded attachments, external links and live mail stores are never opened.
enum MessageReader {
    static func text(_ data: Data) -> String? {
        guard let compound = Compound(data) else { return nil }
        func field(_ property: String) -> String {
            if let bytes = compound.stream("__substg1.0_" + property + "001F") {
                return (String(data: bytes, encoding: .utf16LittleEndian) ?? "").trimmingCharacters(in: .controlCharacters)
            }
            if let bytes = compound.stream("__substg1.0_" + property + "001E") {
                return (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? "").trimmingCharacters(in: .controlCharacters)
            }
            return ""
        }
        var body = field("1000")
        if body.isEmpty, let html = compound.stream("__substg1.0_10130102"), let raw = String(data: html, encoding: .utf8) {
            body = raw.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</?(p|div|br|tr|li)[^>]*>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let headers = [("主题",field("0037")),("发件人",field("0C1A")),("收件人",field("0E04"))]
            .filter { !$0.1.isEmpty }.map { $0.0 + "：" + $0.1 }
        return (headers + ["正文：\n" + body]).joined(separator: "\n")
    }
    private struct Compound {
        let data: Data, sectorSize: Int, fat: [UInt32], directory: Data, mini: Data, miniFAT: [UInt32]
        let names: [String: Int]
        init?(_ input: Data) {
            guard input.count >= 512, input.count <= 32 * 1024 * 1024,
                  Array(input.prefix(8)) == [0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1],
                  input.u16(28) == 0xfffe, [9,12].contains(input.u16(30)), input.u16(32) == 6 else { return nil }
            let width = 1 << Int(input.u16(30)), count = input.count / width - 1
            guard count > 0 else { return nil }
            func sector(_ id: UInt32) -> Data? {
                guard Int(id) < count else { return nil }; return input.subdata(in: (Int(id)+1)*width..<(Int(id)+2)*width)
            }
            var ids = (0..<109).map { input.u32(76+$0*4) }.filter { $0 < 0xfffffffa }
            var next = input.u32(68), seen = Set<UInt32>()
            while next < 0xfffffffa {
                guard seen.insert(next).inserted, seen.count <= count, let part = sector(next) else { return nil }
                ids += (0..<(width/4-1)).map { part.u32($0*4) }.filter { $0 < 0xfffffffa }
                next = part.u32(width-4)
            }
            guard ids.count >= Int(input.u32(44)), ids.count <= count else { return nil }
            var table: [UInt32] = []
            for id in ids.prefix(Int(input.u32(44))) { guard let part = sector(id) else { return nil }; table += (0..<width/4).map { part.u32($0*4) } }
            func chain(_ start: UInt32) -> Data? {
                var id = start, seen = Set<UInt32>(), bytes = Data()
                while id < 0xfffffffa {
                    guard Int(id) < table.count, seen.insert(id).inserted, let part = sector(id) else { return nil }
                    bytes.append(part); id = table[Int(id)]
                }
                return id == 0xfffffffe ? bytes : nil
            }
            guard let dir = chain(input.u32(48)), dir.count >= 128, dir[66] == 5,
                  let small = chain(dir.u32(116)), let miniFatBytes = chain(input.u32(60)) else { return nil }
            var mapping: [String: Int] = [:], pending = [dir.u32(76)], visited = Set<UInt32>()
            while let id = pending.popLast(), id != 0xffffffff {
                guard Int(id) < dir.count/128, visited.insert(id).inserted else { return nil }
                let offset = Int(id)*128, length = Int(dir.u16(offset+64))
                if length >= 2, length <= 64, dir[offset+66] == 2,
                   let name = String(data: dir.subdata(in: offset..<offset+length-2), encoding: .utf16LittleEndian) { mapping[name] = offset }
                for link in [dir.u32(offset+68),dir.u32(offset+72)] where link != 0xffffffff { pending.append(link) }
            }
            self.data=input; sectorSize=width; fat=table; directory=dir; mini=small
            miniFAT=(0..<miniFatBytes.count/4).map { miniFatBytes.u32($0*4) }; names=mapping
        }
        func stream(_ name: String) -> Data? {
            guard let offset=names[name] else { return nil }
            let size=Int(directory.u32(offset+120))
            guard size <= 16 * 1024 * 1024 else { return nil }
            if size == 0 { return Data() }
            let isMini=size < 4096, width=isMini ? 64 : sectorSize, table=isMini ? miniFAT : fat
            let source=isMini ? mini : data
            var id=directory.u32(offset+116), seen=Set<UInt32>(), output=Data()
            while output.count < size {
                let base=(Int(id)+(isMini ? 0 : 1))*width
                guard id < 0xfffffffa, Int(id)<table.count, seen.insert(id).inserted,
                      base>=0, base+width<=source.count else { return nil }
                output.append(source.subdata(in: base..<base+width)); id=table[Int(id)]
            }
            return Data(output.prefix(size))
        }
    }
}
private extension Data {
    func u16(_ offset: Int) -> UInt16 { guard offset >= 0, offset+2 <= count else { return 0xffff }; return UInt16(self[offset]) | UInt16(self[offset+1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { guard offset >= 0, offset+4 <= count else { return 0xffffffff }; return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset+$1]) << ($1*8) } }
}
