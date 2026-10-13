import Foundation

/// Deterministic structural checks, not a claim that model statements are factually correct.
public enum ContentQuality {
    public static func summaryIssue(_ summary: String, filename: String) -> String? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "没有文件摘要" }
        func normalized(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        }
        let name = normalized(filename), stem = normalized(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
        let clean = normalized(text)
        if clean == name || (!stem.isEmpty && clean == stem) { return "摘要只重复文件名" }
        for prefix in ["本地音频", "本地文件", "音频文件", "文件", "图片文件", "本地图片"] {
            if clean == normalized(prefix) + name || clean == normalized(prefix) + stem { return "摘要是文件名占位描述" }
        }
        if ["暂无摘要", "待生成摘要", "无有效内容", "无法读取文件", "无法分析该文件"].contains(text) { return "摘要是占位或错误提示" }
        return nil
    }

    public static func contentIssue(_ source: SourceDocument) -> String? {
        let body = source.blocks.filter { $0.key != "document" && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.tags.isEmpty) }
        if body.isEmpty { return "没有可检索的正文或识别结果" }
        switch source.ext {
        case "txt", "md", "csv", "tsv", "json":
            return source.size > 4 * 1024 * 1024 ? "文本仅提取前 4 MiB" : nil
        case "m4a", "mp3", "wav", "aac", "flac":
            return source.coverage == "full_audio_transcript" ? nil : "音频转写尚未覆盖完整时长"
        case "pptx": return "已索引页面文字和形状；嵌入图片、图表及备注未完整理解"
        case "pdf": return "已索引可提取文字及已有 OCR；未保证所有页面视觉内容覆盖"
        case "jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff": return "图片基于 OCR、标签和文件描述，未做区域级理解"
        case "mp4", "mov", "m4v": return "视频主要基于抽帧，未逐帧分析"
        case "msg": return "已提取邮件正文，不含附件"
        case "xlsx": return source.coverage == "partial" ? "工作表内容仅部分提取" : "已提取单元格值，不含图表、图片或批注"
        default: return source.coverage == "partial" ? "内容覆盖范围尚不完整或未核实" : nil
        }
    }
}
