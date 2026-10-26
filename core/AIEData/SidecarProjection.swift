import Foundation

/// A compatibility adapter: source text and model summaries are separate records.
/// Model output never substitutes for the source block or its location.
public enum SidecarProjection {
    public static func metadataMatches(_ record: [String: Any], source: SourceDocument) -> Bool {
        guard let size = record["size"] as? NSNumber, let mtime = record["mtime"] as? NSNumber else { return false }
        return size.int64Value == source.size && abs(mtime.doubleValue - source.modifiedAt) <= 1
    }

    public static func apply(_ record: [String: Any], to original: SourceDocument) -> SourceDocument {
        var source = original
        let local = record["localScan"] as? [String: Any] ?? [:]
        let localHash = local["sourceHash"] as? String
        let metadataCurrent = metadataMatches(record, source: source)
        let localCurrent = localHash.map { $0 == source.contentHash } ?? metadataCurrent
        let quick = record["quickScan"] as? [String: Any] ?? [:]
        let quickParse = quick["parse"] as? [String: Any] ?? [:]
        let quickHash = quickParse["sourceHash"] as? String
        let quickCurrent = quickHash.map { $0 == source.contentHash } ?? metadataCurrent
        let deep = record["deepScan"] as? [String: Any] ?? [:]
        let deepParse = deep["parse"] as? [String: Any] ?? [:]
        let deepHash = deepParse["sourceHash"] as? String
        let deepCurrent = deepHash.map { $0 == source.contentHash } ?? metadataCurrent
        let deepSummary = deepCurrent ? (deep["blurb_zh"] as? String ?? "") : ""
        let quickSummary = quickCurrent ? (quick["blurb_zh"] as? String ?? "") : ""
        if !deepSummary.isEmpty {
            func strings(_ key: String) -> [String] { deep[key] as? [String] ?? [] }
            source.fileSummary = deepSummary
            source.fileKeywords = Array(Set(
                strings("keywords_zh") + strings("topics_zh") + strings("entities_zh")
                    + strings("objects_zh") + strings("actions_zh")
            )).sorted()
            source.summaryModel = deepParse["model"] as? String ?? "local-deep-scan"
            source.summaryVersion = deepParse["parserVersion"] as? String ?? "deep-scan-1"
        } else if !quickSummary.isEmpty {
            source.fileSummary = quickSummary
            source.fileKeywords = quick["keywords_zh"] as? [String] ?? []
            source.summaryModel = quickParse["model"] as? String ?? "legacy"
            source.summaryVersion = quickParse["parserVersion"] as? String ?? "legacy"
        }
        let rawSummary = source.fileSummary
        let summaryIssue = ContentQuality.summaryIssue(rawSummary, filename: URL(fileURLWithPath: source.path).lastPathComponent)
        if summaryIssue != nil { source.fileSummary = ""; source.fileKeywords = [] }
        var localError: String?
        if localCurrent {
            func appendVision(
                _ vision: [String: Any],
                keyPrefix: String,
                page: Int? = nil,
                startSeconds: Double? = nil,
                endSeconds: Double? = nil
            ) {
                guard vision["error"] == nil else { return }
                let ocrText = (vision["ocr"] as? [String] ?? []).joined(separator: "\n")
                let tagRows = vision["tags"] as? [[String: Any]] ?? []
                let tags = tagRows.flatMap { tag -> [String] in
                    (tag["zh"] as? [String] ?? []) + [tag["id"] as? String ?? ""]
                }.filter { !$0.isEmpty }
                let labelsKey = keyPrefix + "-labels"
                if !ocrText.isEmpty {
                    source.blocks.append(ContentBlock(
                        key: keyPrefix + "-ocr", kind: source.kind == "video" ? "frame_ocr" : "image_ocr",
                        page: page, startSeconds: startSeconds, endSeconds: endSeconds, text: ocrText,
                        summary: String(ocrText.prefix(180)), summaryMethod: "apple_vision_ocr"
                    ))
                }
                let labels = tags.joined(separator: " ")
                if !labels.isEmpty {
                    source.blocks.append(ContentBlock(
                        key: labelsKey, kind: "system_visual_labels",
                        page: page, startSeconds: startSeconds, endSeconds: endSeconds,
                        text: labels, tags: tags,
                        summary: String(labels.prefix(180)), summaryMethod: "apple_vision_classification"
                    ))
                }
                for tag in tagRows {
                    guard let identifier = tag["id"] as? String, !identifier.isEmpty else { continue }
                    source.observations.append(ContentObservation(
                        subjectBlockKey: labelsKey, type: "visual.classification",
                        valueText: identifier, confidence: (tag["confidence"] as? NSNumber)?.doubleValue,
                        producerJobType: "local"
                    ))
                }
                for animal in vision["animals"] as? [String] ?? [] {
                    source.observations.append(ContentObservation(
                        subjectBlockKey: labelsKey, type: "visual.animal",
                        valueText: animal, producerJobType: "local"
                    ))
                }
                if let people = (vision["peopleCount"] as? NSNumber)?.doubleValue, people > 0 {
                    source.observations.append(ContentObservation(
                        subjectBlockKey: labelsKey, type: "visual.people_count",
                        valueNumber: people, producerJobType: "local"
                    ))
                }
                for barcode in vision["barcodes"] as? [String] ?? [] {
                    source.observations.append(ContentObservation(
                        subjectBlockKey: labelsKey, type: "visual.barcode",
                        valueText: barcode, producerJobType: "local"
                    ))
                }
                if let canvas = vision["canvas"] as? [String: Any] {
                    for key in ["inkRatio", "paperRatio", "chroma", "edgeRatio"] {
                        if let number = (canvas[key] as? NSNumber)?.doubleValue {
                            source.observations.append(ContentObservation(
                                subjectBlockKey: labelsKey, type: "visual.canvas." + key,
                                valueNumber: number, producerJobType: "local"
                            ))
                        }
                    }
                    for key in ["mostlyBlank", "sparse", "sketchy"] {
                        if let value = canvas[key] as? Bool {
                            source.observations.append(ContentObservation(
                                subjectBlockKey: labelsKey, type: "visual.canvas." + key,
                                valueText: value ? "true" : "false", producerJobType: "local"
                            ))
                        }
                    }
                    if let layout = canvas["layout"] as? String {
                        source.observations.append(ContentObservation(
                            subjectBlockKey: labelsKey, type: "visual.canvas.layout",
                            valueText: layout, producerJobType: "local"
                        ))
                    }
                }
            }
            if let structured = local["structuredFile"] as? [String: Any] { source.coverage = structured["coverage"] as? String ?? "partial" }
            if let spreadsheet = local["spreadsheet"] as? [String: Any] {
                source.coverage = spreadsheet["coverage"] as? String ?? "partial"
            }
            for section in local.values {
                if let error = (section as? [String: Any])?["error"] as? String { localError = error }
            }
            if let presentation = local["presentation"] as? [String: Any],
               let slides = presentation["slides"] as? [[String: Any]], !slides.isEmpty {
                source.blocks.removeAll { $0.key != "document" }
                let version = presentation["parserVersion"] as? String ?? "legacy"
                for slide in slides {
                    guard let page = slide["page"] as? Int, page > 0 else { continue }
                    let text = slide["text"] as? String ?? ""
                    let tags = slide["tags"] as? [String] ?? []
                    let location = json(["member": slide["member"] as? String ?? "", "evidence": slide["evidence"] as? [String] ?? []])
                    source.blocks.append(contentsOf: StructuralChunker.page(text, key: "slide-\(page)", kind: "slide", page: page, tags: tags, locationJSON: location, parserVersion: "pptx-" + version))
                }
                source.coverage = presentation["coverage"] as? String ?? "partial"
            } else if let videoFrames = local["videoFrames"] as? [String: Any],
                      let frames = videoFrames["frames"] as? [[String: Any]] {
                for frame in frames {
                    guard let index = frame["index"] as? Int,
                          let start = (frame["startSeconds"] as? NSNumber)?.doubleValue,
                          let end = (frame["endSeconds"] as? NSNumber)?.doubleValue
                    else { continue }
                    source.blocks.append(ContentBlock(
                        key: "visual-frame-\(index)", kind: "visual_frame", startSeconds: start,
                        endSeconds: end, text: "", summaryMethod: "visual_anchor",
                        parserVersion: videoFrames["parserVersion"] as? String ?? "video-sample-1"
                    ))
                    if let vision = frame["vision"] as? [String: Any] {
                        appendVision(vision, keyPrefix: "vision-frame-\(index)", startSeconds: start, endSeconds: end)
                    }
                }
                source.coverage = frames.isEmpty ? "partial" : "sampled_video"
            } else if let vision = local["vision"] as? [String: Any] {
                appendVision(vision, keyPrefix: "vision", page: source.ext == "pdf" ? 1 : nil)
            }
            if let speech = local["speech"] as? [String: Any], speech["error"] == nil,
               let text = speech["searchableText"] as? String, !text.isEmpty {
                source.blocks.append(contentsOf: textBlocks(text, prefix: "speech", kind: "transcript_excerpt"))
            }
            // Keep legacy language analysis only when there is no direct source extraction.
            if source.blocks.count == 1, let nl = local["naturalLanguage"] as? [String: Any],
               let text = nl["searchableText"] as? String, !text.isEmpty {
                source.blocks.append(ContentBlock(key: "legacy-text", kind: "legacy_excerpt", text: text,
                                                  tags: nl["tokens"] as? [String] ?? [], summary: String(text.prefix(180)), summaryMethod: "legacy_keywords"))
            }
        }
        // Model-derived semantics remain a separate block and never replace source OCR/text chunks.
        if deepCurrent, !deepSummary.isEmpty {
            let evidence = deep["evidence_zh"] as? [String] ?? []
            let visibleText = deep["visible_text_zh"] as? [String] ?? []
            let scene = deep["scene_zh"] as? String ?? ""
            let semanticText = (evidence + visibleText + (scene.isEmpty ? [] : [scene])).joined(separator: "\n")
            let tags = source.fileKeywords
            let observationState = summaryIssue == nil ? "current" : "rejected"
            source.blocks.append(ContentBlock(
                key: "deep-scan",
                kind: "semantic_analysis",
                text: semanticText,
                tags: tags,
                summary: observationState == "current" ? deepSummary : "",
                summaryMethod: "local_multimodal_deep_scan",
                parserVersion: deepParse["parserVersion"] as? String ?? "deep-scan-1"
            ))
            for segment in deep["videoSegments"] as? [[String: Any]] ?? [] {
                guard segment["status"] as? String == "ready",
                      let index = segment["index"] as? Int,
                      let start = (segment["startSeconds"] as? NSNumber)?.doubleValue,
                      let end = (segment["endSeconds"] as? NSNumber)?.doubleValue
                else { continue }
                let blurb = segment["blurb_zh"] as? String ?? ""
                let evidence = segment["evidence_zh"] as? [String] ?? []
                let visibleText = segment["visible_text_zh"] as? [String] ?? []
                let scene = segment["scene_zh"] as? String ?? ""
                let text = ([blurb] + evidence + visibleText + (scene.isEmpty ? [] : [scene]))
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let tags = Array(Set(
                    (segment["keywords_zh"] as? [String] ?? [])
                        + (segment["objects_zh"] as? [String] ?? [])
                        + (segment["actions_zh"] as? [String] ?? [])
                )).sorted()
                if !text.isEmpty || !tags.isEmpty {
                    source.blocks.append(ContentBlock(
                        key: "video-segment-\(index)", kind: "video_segment_analysis",
                        startSeconds: start, endSeconds: end, text: text, tags: tags,
                        summary: String(blurb.prefix(180)),
                        summaryMethod: "local_multimodal_video_segment",
                        parserVersion: deepParse["parserVersion"] as? String ?? "video-deep-scan-2"
                    ))
                }
            }
            source.observations.append(ContentObservation(
                type: "summary.short", valueText: deepSummary, producerJobType: "deep",
                state: observationState
            ))
            func deepStrings(_ key: String, _ type: String) {
                for value in deep[key] as? [String] ?? [] where !value.isEmpty {
                    source.observations.append(ContentObservation(
                        type: type, valueText: value, producerJobType: "deep",
                        state: observationState
                    ))
                }
            }
            deepStrings("keywords_zh", "keyword")
            deepStrings("topics_zh", "topic")
            deepStrings("entities_zh", "entity")
            deepStrings("evidence_zh", "evidence")
            deepStrings("objects_zh", "visual.object")
            deepStrings("actions_zh", "visual.action")
            deepStrings("visible_text_zh", "visual.visible_text")
            if let value = deep["content_type_zh"] as? String, !value.isEmpty {
                source.observations.append(ContentObservation(
                    type: "content.type", valueText: value, producerJobType: "deep",
                    state: observationState
                ))
            }
            if let value = deep["completion_state"] as? String, !value.isEmpty {
                let confidence = (deep["completion_confidence"] as? NSNumber)?.doubleValue
                source.observations.append(ContentObservation(
                    type: "document.completeness", valueText: value, confidence: confidence,
                    producerJobType: "deep",
                    state: observationState
                ))
            }
            deepStrings("completion_evidence_zh", "document.completeness_evidence")
            deepStrings("missing_parts_zh", "document.missing_part")
            if let value = deep["reuse_action"] as? String, !value.isEmpty, value != "none" {
                source.observations.append(ContentObservation(
                    type: "reuse.opportunity", valueText: value,
                    confidence: (deep["reuse_confidence"] as? NSNumber)?.doubleValue,
                    producerJobType: "deep",
                    state: observationState
                ))
            }
            if let value = deep["reuse_reason_zh"] as? String, !value.isEmpty {
                source.observations.append(ContentObservation(
                    type: "reuse.opportunity_reason", valueText: value, producerJobType: "deep",
                    state: observationState
                ))
            }
            if let value = deep["scene_zh"] as? String, !value.isEmpty {
                source.observations.append(ContentObservation(
                    type: "visual.scene", valueText: value, producerJobType: "deep",
                    state: observationState
                ))
            }
        }
        // Transcription checkpoints carry their own source hash; unrelated local scans can be older.
        let transcript = local["mediaTranscript"] as? [String: Any] ?? [:]
        let transcriptCurrent = transcript["sourceHash"] as? String == source.contentHash
        if transcriptCurrent, let segments = transcript["segments"] as? [[String: Any]] {
            for segment in segments where segment["status"] as? String == "ready" {
                guard let index = segment["index"] as? Int, index >= 0,
                      let start = segment["startSeconds"] as? Double, let end = segment["endSeconds"] as? Double,
                      start.isFinite, end.isFinite, start >= 0, end > start,
                      let text = segment["text"] as? String, !text.isEmpty else { continue }
                source.blocks.append(ContentBlock(key: "transcript-\(index)", kind: "transcript", startSeconds: start, endSeconds: end,
                                                  text: text, summary: String(text.prefix(180)), summaryMethod: "local_transcript_excerpt",
                                                  parserVersion: transcript["parserVersion"] as? String ?? "media-transcript-1"))
            }
        }
        let attempt = record["quickScanAttempt"] as? [String: Any] ?? [:]
        let attemptHash = attempt["sourceHash"] as? String
        let attemptCurrent = attemptHash.map { $0 == source.contentHash } ?? metadataCurrent
        let deepAttempt = record["deepScanAttempt"] as? [String: Any] ?? [:]
        let deepAttemptHash = deepAttempt["sourceHash"] as? String
        let deepAttemptCurrent = deepAttemptHash.map { $0 == source.contentHash } ?? metadataCurrent
        let supportedQuick = ["jpg","jpeg","png","webp","heic","bmp","gif","tif","tiff","mp4","mov","m4v","pdf","txt","md","csv","tsv","json","docx","pptx","xlsx","xml","msg","rar","zip","7z","tar","gz","m4a","mp3","wav","aac","flac"].contains(source.ext)
        let supportedLocal = supportedQuick || ["m4a", "mp3", "wav", "aac", "flac"].contains(source.ext)
        source.stages = [
            ScanStage("local", status: !supportedLocal ? "unsupported" : (localError != nil ? "failed" : (localCurrent && !local.isEmpty ? "ready" : "pending")),
                      error: localError, attemptedAt: localCurrent ? record["scannedAt"] as? String : nil),
            ScanStage("deep", status: !supportedQuick ? "unsupported" : (!deepSummary.isEmpty ? "ready" : (deepAttemptCurrent && deepAttempt["status"] as? String == "failed" ? "failed" : "pending")),
                      error: deepAttemptCurrent ? deepAttempt["reason"] as? String : nil, attemptedAt: deepAttemptCurrent ? deepAttempt["attemptedAt"] as? String : nil),
            ScanStage("quick", status: !supportedQuick ? "unsupported" : (!quickSummary.isEmpty ? "ready" : (attemptCurrent && attempt["status"] as? String == "failed" ? "failed" : "pending")),
                      error: attemptCurrent ? attempt["reason"] as? String : nil, attemptedAt: attemptCurrent ? attempt["attemptedAt"] as? String : nil),
            ScanStage("index", status: "ready"),
        ]
        if transcriptCurrent {
            if source.kind == "audio" {
                source.stages[0] = ScanStage("local", status: transcript["status"] as? String ?? "pending", error: transcript["error"] as? String)
                source.coverage = transcript["status"] as? String == "ready" ? "full_audio_transcript" : "partial"
            }
            source.stages.append(ScanStage("transcript", status: transcript["status"] as? String ?? "pending",
                                           error: transcript["error"] as? String, attemptedAt: transcript["updatedAt"] as? String))
        }
        if localCurrent, !local.isEmpty {
            let started = timestamp(record["scannedAt"]) ?? source.modifiedAt
            source.processorRuns.append(ProcessorRun(
                jobType: "local", processorKey: "macos-local-analysis", processorVersion: "1",
                inputFingerprint: source.contentHash, startedAt: started, finishedAt: started,
                outcome: localError == nil ? "succeeded" : "failed", errorCode: localError
            ))
        }
        if deepCurrent, !deepSummary.isEmpty {
            let finished = timestamp(deepParse["parsedAt"]) ?? source.modifiedAt
            source.processorRuns.append(ProcessorRun(
                jobType: "deep", processorKey: "local-deep-scan",
                processorVersion: deepParse["parserVersion"] as? String ?? "deep-scan-1",
                modelKey: deepParse["model"] as? String,
                modelRevision: deepParse["modelDigest"] as? String,
                promptVersion: deepParse["parserVersion"] as? String ?? "deep-scan-1",
                inputFingerprint: deepHash ?? source.contentHash,
                startedAt: finished, finishedAt: finished, outcome: "succeeded"
            ))
        } else if deepAttemptCurrent, deepAttempt["status"] as? String == "failed" {
            let started = timestamp(deepAttempt["attemptedAt"]) ?? source.modifiedAt
            source.processorRuns.append(ProcessorRun(
                jobType: "deep", processorKey: "local-deep-scan", processorVersion: "deep-scan-1",
                inputFingerprint: deepAttemptHash ?? source.contentHash,
                startedAt: started, finishedAt: started, outcome: "failed",
                errorCode: deepAttempt["reason"] as? String
            ))
        }
        if quickCurrent, !quickSummary.isEmpty {
            let finished = timestamp(quickParse["parsedAt"]) ?? source.modifiedAt
            source.processorRuns.append(ProcessorRun(
                jobType: "quick", processorKey: "openrouter-quick-scan",
                processorVersion: quickParse["parserVersion"] as? String ?? "2",
                modelKey: quickParse["model"] as? String,
                inputFingerprint: quickHash ?? source.contentHash,
                startedAt: finished, finishedAt: finished, outcome: "succeeded"
            ))
        }
        let contentIssue = ContentQuality.contentIssue(source)
        let hasBody = source.blocks.contains { $0.key != "document" && (!$0.text.isEmpty || !$0.tags.isEmpty) }
        source.stages.append(ScanStage("summary_quality", status: rawSummary.isEmpty ? "missing" : (summaryIssue == nil ? "usable" : "needs_review"), error: summaryIssue))
        source.stages.append(ScanStage("content_quality", status: !hasBody ? "empty" : (contentIssue == nil ? "available" : "limited"), error: contentIssue))
        return source
    }

    /// Bound blocks without losing the middle of a long paragraph. Offsets refer to Swift characters.
    public static func textBlocks(_ text: String, prefix: String = "text", kind: String = "paragraph", limit: Int = 1600) -> [ContentBlock] {
        StructuralChunker.text(text, prefix: prefix, kind: kind, limit: limit)
    }

    private static func json(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func timestamp(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)?.timeIntervalSince1970
            ?? ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970
    }
}
