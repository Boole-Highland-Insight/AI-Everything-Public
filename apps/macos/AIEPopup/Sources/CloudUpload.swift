import SwiftUI

/// 源文件内容因再利用等明确操作发给云端大模型时，列表给出小云标。
/// QuickScan 不计入这个状态。
enum CloudUpload {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func isMarked(_ obj: [String: Any]?) -> Bool {
        guard let cloud = obj?["cloudUpload"] as? [String: Any] else { return false }
        if let at = cloud["uploadedAt"] as? String, !at.isEmpty { return true }
        if let purposes = cloud["purposes"] as? [String], !purposes.isEmpty { return true }
        return false
    }

    static func mark(_ file: IndexedFile, purpose: String) {
        write(root: URL(fileURLWithPath: file.rootPath), relative: ScanRecords.relative(for: file), purpose: purpose)
    }

    static func mark(path: String, like file: IndexedFile, purpose: String) {
        let root = URL(fileURLWithPath: file.rootPath, isDirectory: true)
        guard path.hasPrefix(file.rootPath + "/") else {
            mark(file, purpose: purpose)
            return
        }
        let rel = String(path.dropFirst(file.rootPath.count + 1))
        write(root: root, relative: rel, purpose: purpose)
    }

    private static func write(root: URL, relative: String, purpose: String) {
        ScanRecords.mutate(root: root, relative: relative) { record in
            var cloud = record["cloudUpload"] as? [String: Any] ?? [:]
            cloud["uploadedAt"] = iso.string(from: Date())
            var purposes = cloud["purposes"] as? [String] ?? []
            if !purposes.contains(purpose) { purposes.append(purpose) }
            cloud["purposes"] = purposes
            record["cloudUpload"] = cloud
            if record["sourceRelative"] == nil {
                record["sourceRelative"] = relative
            }
            return true
        }
    }
}

struct CloudUploadBadge: View {
    var body: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 0.18, green: 0.53, blue: 0.96))
            .frame(width: 24, height: 54)
            .accessibilityLabel("曾上传到云端模型")
            .help("这份文件的内容曾发给云端大模型，不是只在本机")
    }
}
