import Foundation

@main
enum ArchiveEntryReaderChecks {
    static func main() {
        let archive = CommandLine.arguments[1]
        let expected = Data(repeating: 65, count: 2 * 1024 * 1024)
        precondition(ArchiveEntryReader.data(path: archive, member: "ppt/slides/slide1.xml") == expected)
        precondition(ArchiveEntryReader.data(path: archive, member: "ppt/slides/slide1.xml", maxBytes: 1024) == nil)
        precondition(ArchiveEntryReader.data(path: archive, member: "missing.xml") == nil)
        precondition(ArchiveEntryReader.data(path: archive + ".missing", member: "ppt/slides/slide1.xml") == nil)
        print("Archive reader checks passed: 2 MiB entry, missing entry and missing archive.")
    }
}
