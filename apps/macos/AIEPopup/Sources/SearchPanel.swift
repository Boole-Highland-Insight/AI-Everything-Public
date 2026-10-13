import AppKit
import PDFKit
import SwiftUI
import QuickLookThumbnailing

final class SearchModel: ObservableObject {
    @Published var files: [IndexedFile] = [] {
        didSet { if !isPreview { rebuildAITabIndex() } }
    }
    @Published var query = "" {
        didSet {
            guard !isPreview else { return }
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if submittedQuery != normalized {
                submittedQuery = nil
            }
            if dismissedTabQuery != query { dismissedTabQuery = nil }
            refreshTabSuggestions()
            ScanControl.shared.noteInteractiveWork()
            refresh()
        }
    }
    @Published var hits: [FileHit] = []
    @Published private(set) var lastSearchTrace: SearchTrace?
    @Published private(set) var tabSuggestions: [AITabSuggestion] = []
    @Published private(set) var tabSuggestionIndex = 0
    @Published private(set) var tabLookupMilliseconds = 0.0
    @Published var selected: String?

    var directHits: [FileHit] { hits.filter { $0.confidenceTier == .direct } }
    var possibleHits: [FileHit] { hits.filter { $0.confidenceTier == .possible } }
    var hasActiveQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @Published var status = "正在加载资料库…"
    @Published var roots: [URL] = []
    @Published var isLoading = false
    @Published var fastSearching = false
    @Published var reranking = false
    @Published var deepSearching = false
    @Published var precisionSearching = false
    @Published var remoteReady = false
    @Published var remoteSettingsError: String?
    @Published var recycleMode = false
    @Published var junk: [JunkItem] = []
    @Published var junkFilter: JunkBin?
    @Published var junkPicked: Set<String> = []
    @Published var recycleBusy = false
    @Published var showingTrash = false
    @Published var trash: [TrashItem] = []
    @Published var reusePhase: ReusePhase = .idle
    @Published var reuseOther = ""
    @Published var reusePicks: [String: String] = [:]
    @Published var reuseSummary: String?
    @Published var reuseSummarizing = false
    @Published var reuseFollowUp = ""
    @Published var reuseFollowUpError: String?
    @Published var reuseRevising = false
    @Published var reuseOriginalQueued = false

    private var watcher: LibraryWatcher?
    private var loading = false
    private var started = false
    private var indexReloading = false
    private var indexReloadQueued = false
    private var tokenChecking = false
    private var scanConfigurationObserver: NSObjectProtocol?
    private var photoObserver: NSObjectProtocol?
    private var filesystemReload: DispatchWorkItem?
    private var reloadQueued = false
    private var queuedReloadProminent = false
    private var rerankTask: Task<Void, Never>?
    private var localSearchTask: Task<Void, Never>?
    private var submittedQuery: String?
    private var searchGeneration = 0
    private static let searchQueue = DispatchQueue(label: "aie.search", qos: .userInitiated)
    private var rerankToken = 0
    private var automaticJevSignature: String?
    private var automaticJevHits: [FileHit] = []
    private var reuseTask: Task<Void, Never>?
    private var reuseAnchor: String?
    private var didRestoreReuseSession = false
    private var rootsGeneration = 0
    private var databaseTimer: Timer?
    private var databaseToken: Int64 = -1
    private var aiTabIndex = AITabIndex()
    private var aiTabGeneration = 0
    private var dismissedTabQuery: String?
    let isPreview: Bool

    deinit {
        databaseTimer?.invalidate()
        if let scanConfigurationObserver { NotificationCenter.default.removeObserver(scanConfigurationObserver) }
        if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) }
    }

    init(previewFiles: [IndexedFile]? = nil) {
        isPreview = previewFiles != nil
        if let previewFiles {
            files = previewFiles
            roots = previewFiles.first.map { [URL(fileURLWithPath: $0.rootPath)] } ?? []
            reuseAnchor = previewFiles.first?.path
            status = "示例资料"
            return
        }
        remoteReady = GroqRerank.hasKey
        roots = LibraryRoots.load()
        LibraryGateway.selectRoots(roots)
        photoObserver = NotificationCenter.default.addObserver(forName: .aiePhotoSnapshotsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload(prominent: false)
        }
        scanConfigurationObserver = NotificationCenter.default.addObserver(forName: ScanConfiguration.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            if ScanConfiguration.semanticEnabled() { self.reload(prominent: false) }
        }
        databaseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.started, !self.tokenChecking, !self.loading, !self.indexReloading else { return }
            self.tokenChecking = true
            DispatchQueue.global(qos: .utility).async {
                let token = try? AppDatabase.open().changeToken()
                DispatchQueue.main.async {
                    self.tokenChecking = false
                    guard let token, token != self.databaseToken else { return }
                    self.databaseToken = token
                    self.reloadIndexOnly()
                }
            }
        }
    }

    var rootsLabel: String {
        if roots.isEmpty { return "选择资料夹" }
        if roots.count == 1 { return roots[0].lastPathComponent }
        return "\(roots.count) 个资料夹"
    }

    var demoAvailable: Bool {
        LibraryRoots.demoExists && !roots.contains(where: { $0.path == LibraryRoots.demoURL.path })
    }

    var tabSuggestion: AITabSuggestion? {
        guard tabSuggestions.indices.contains(tabSuggestionIndex) else { return nil }
        return tabSuggestions[tabSuggestionIndex]
    }

    var tabSuggestionStatus: String? {
        guard let suggestion = tabSuggestion else { return nil }
        return "Tab 接受 · ↑↓ 切换 · \(suggestion.kind.rawValue) · 来源 \(suggestion.sourceLabel)"
    }

    @discardableResult
    func acceptTabSuggestion() -> Bool {
        guard let suggestion = tabSuggestion else { return false }
        query = suggestion.value
        return true
    }

    @discardableResult
    func moveTabSuggestion(_ delta: Int) -> Bool {
        guard !tabSuggestions.isEmpty else { return false }
        tabSuggestionIndex = (tabSuggestionIndex + delta + tabSuggestions.count) % tabSuggestions.count
        return true
    }

    @discardableResult
    func dismissTabSuggestion() -> Bool {
        guard !tabSuggestions.isEmpty else { return false }
        dismissedTabQuery = query
        tabSuggestions = []
        tabSuggestionIndex = 0
        return true
    }

    private func rebuildAITabIndex() {
        aiTabGeneration += 1
        let generation = aiTabGeneration
        let snapshot = files
        DispatchQueue.global(qos: .userInitiated).async {
            let index = AITabIndex(files: snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.aiTabGeneration else { return }
                self.aiTabIndex = index
                self.refreshTabSuggestions()
            }
        }
    }

    private func refreshTabSuggestions() {
        guard dismissedTabQuery != query else { return }
        let started = ProcessInfo.processInfo.systemUptime
        tabSuggestions = aiTabIndex.suggestions(for: query)
        tabLookupMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        tabSuggestionIndex = 0
    }

    func loadAsync() {
        guard !started else { return }
        started = true
        startWatching()
        Task { @MainActor in
            PhotoLibrarySync.shared.resumeIfNeeded()
            DeviceSetup.shared.resumeInstallationIfNeeded()
        }
        if roots.isEmpty {
            status = "未选择资料夹"
            files = []
            refresh()
            return
        }
        reload(prominent: true)
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard !roots.isEmpty else { return }
        let watcher = LibraryWatcher(roots: roots)
        watcher.onChange = { [weak self] in
            guard let self, self.filesystemReload == nil else { return }
            // Batch imports while continuing to publish partial results every few seconds.
            let work = DispatchWorkItem { [weak self] in
                self?.filesystemReload = nil
                self?.reload(prominent: false)
            }
            self.filesystemReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
        watcher.start()
        self.watcher = watcher
    }

    func addFolders(from window: NSWindow?) {
        LibraryRoots.pickFolders(from: window) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.setRoots(LibraryRoots.merge(existing: self.roots, adding: urls))
        }
    }

    func configureInitialSources(_ urls: [URL]) {
        setRoots(urls)
    }

    func addDemoLibrary() {
        setRoots(LibraryRoots.merge(existing: roots, adding: [LibraryRoots.demoURL]))
    }

    @MainActor func addPhotos() {
        PhotoLibrarySync.shared.connect { [weak self] url in
            guard let self else { return }
            self.setRoots(LibraryRoots.merge(existing: self.roots, adding: [url]))
        }
    }

    func removeRoot(_ url: URL) {
        setRoots(roots.filter { $0.path != url.path })
    }

    private func setRoots(_ urls: [URL]) {
        started = true
        Task { @MainActor in
            if PhotoLibrarySync.shared.connected,
               !urls.contains(where: { $0.standardizedFileURL == PhotoImport.directory.standardizedFileURL }) {
                PhotoLibrarySync.shared.disconnect()
            }
        }
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
        }
        roots = urls
        rootsGeneration += 1
        Task { await LocalRerank.invalidatePlanCache() }
        LibraryGateway.selectRoots(urls)
        Task { await LocalSemanticIndex.shared.update(roots: urls.map(\.path)) }
        LibraryRoots.save(urls)
        startWatching()
        files = []
        junk = []
        selected = nil
        refresh()
        if urls.isEmpty {
            status = "未选择资料夹"
            isLoading = false
            refresh()
            return
        }
        reload(prominent: true)
    }

    private func reload(prominent: Bool = false) {
        if roots.isEmpty {
            files = []
            isLoading = false
            refresh()
            return
        }
        if loading || indexReloading {
            reloadQueued = true
            queuedReloadProminent = queuedReloadProminent || prominent
            return
        }
        loading = true
        isLoading = true
        let roots = self.roots
        let generation = rootsGeneration
        let showProgress = prominent
        DispatchQueue.global(qos: .userInitiated).async {
            let files = LibraryGateway.load(
                roots: roots,
                catalogReady: { catalog in
                    DispatchQueue.main.async {
                        guard self.rootsGeneration == generation else { return }
                        self.files = catalog
                        ScanProgress.shared.setCatalogReady(count: catalog.count)
                        ScanProgress.shared.beginIndexing(total: catalog.count)
                        self.refreshAfterIndexUpdate()
                        if self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.status = "已发现 \(catalog.count) 个文件 · 正在建立内容索引…"
                        }
                    }
                },
                indexProgress: { completed, total in
                    DispatchQueue.main.async {
                        guard self.rootsGeneration == generation else { return }
                        ScanProgress.shared.updateIndexing(completed: completed, total: total)
                    }
                }
            )
            DispatchQueue.main.async {
                self.loading = false
                guard self.rootsGeneration == generation else {
                    self.files = []
                    self.reloadQueued = false
                    self.reload(prominent: true)
                    return
                }
                self.files = files
                if let error = LibraryGateway.lastError {
                    DeviceSetup.shared.markIndexFailed(error)
                } else {
                    DeviceSetup.shared.markIndexReady(fileCount: files.count)
                    ScanProgress.shared.setCatalogReady(count: files.count)
                }
                ScanProgress.shared.finishIndexing(completed: LibraryGateway.lastError == nil)
                ScanProgress.shared.setProminent(showProgress)
                self.updateSemanticIndex()
                self.isLoading = false
                self.junk = JunkClassifier.classify(files)
                self.trash = TrashBin.load()
                self.restoreReuseSessionIfNeeded()
                self.refreshAfterIndexUpdate()
                guard LibraryGateway.lastError == nil else { return }
                VisionEnricher.enqueueMissing(
                    files: files,
                    tick: { [weak self] in self?.onScanIdle() },
                    done: { [weak self] in
                        guard let self, self.rootsGeneration == generation else { return }
                        let roots = self.roots
                        DispatchQueue.global(qos: .utility).async {
                            let latest = LibraryGateway.load(roots: roots)
                            DispatchQueue.main.async {
                                guard self.rootsGeneration == generation else { return }
                                self.files = latest
                                self.updateSemanticIndex()
                                self.junk = JunkClassifier.classify(latest)
                                self.trash = TrashBin.load()
                                self.refreshAfterIndexUpdate()
                                QuickScanner.enqueueMissing(files: latest) { [weak self] in
                                    self?.onScanIdle()
                                }
                            }
                        }
                    }
                )
                if self.reloadQueued {
                    self.reloadQueued = false
                    let queuedProminent = self.queuedReloadProminent
                    self.queuedReloadProminent = false
                    self.reload(prominent: queuedProminent)
                }
            }
        }
    }

    private func onScanIdle() {
        reloadIndexOnly()
    }

    func repairSummaries() {
        guard !VisionEnricher.isBusy, !QuickScanner.isBusy,
              remoteReady || LocalQuickScan.isInstalled
        else { return }
        ScanProgress.shared.setProminent(true)
        QuickScanner.enqueueMissing(files: files, repairSummaries: true) { [weak self] in self?.onScanIdle() }
    }

    func rescanAllLocally() {
        guard LocalQuickScan.isInstalled, !VisionEnricher.isBusy, !QuickScanner.isBusy else { return }
        ScanProgress.shared.setProminent(true)
        QuickScanner.enqueueMissing(files: files, forceLocalDeepScan: true) { [weak self] in self?.onScanIdle() }
    }

    func retryScanning() {
        guard !VisionEnricher.isBusy, !QuickScanner.isBusy else { return }
        _ = try? AppDatabase.open().retryFailedJobs(jobTypes: ["local", "deep", "quick"])
        reload(prominent: true)
    }

    func toggleScanning() {
        if ScanControl.shared.isPaused {
            ScanControl.shared.setPaused(false)
            ScanProgress.shared.resumeByUser()
            Task { @MainActor in PhotoLibrarySync.shared.startSync() }
            reload(prominent: true)
        } else {
            ScanControl.shared.setPaused(true)
            ScanProgress.shared.pauseByUser()
        }
    }

    private func reloadIndexOnly() {
        guard started else { return }
        if loading || indexReloading { indexReloadQueued = true; return }
        indexReloading = true
        indexReloadQueued = false
        let roots = self.roots
        let generation = rootsGeneration
        DispatchQueue.global(qos: .utility).async {
            let files = LibraryGateway.load(roots: roots)
            DispatchQueue.main.async {
                self.indexReloading = false
                if self.rootsGeneration == generation {
                    self.files = files
                    self.updateSemanticIndex()
                    self.junk = JunkClassifier.classify(files)
                    self.trash = TrashBin.load()
                    self.refreshAfterIndexUpdate()
                }
                if self.reloadQueued {
                    self.reloadQueued = false
                    let prominent = self.queuedReloadProminent
                    self.queuedReloadProminent = false
                    self.reload(prominent: prominent)
                } else if self.indexReloadQueued { self.reloadIndexOnly() }
            }
        }
    }

    func updateSemanticIndex(force: Bool = false) {
        guard LibraryGateway.lastError == nil else { return }
        let paths = roots.map(\.path)
        Task { await LocalSemanticIndex.shared.update(roots: paths, force: force) }
    }

    func refreshAfterIndexUpdate() {
        guard !hasActiveQuery || !searchInProgress else { return }
        refresh()
    }

    @discardableResult
    func saveRemoteKey(_ key: String) -> Bool {
        guard GroqRerank.saveKey(key) else {
            remoteSettingsError = GroqClient.lastError
            return false
        }
        remoteSettingsError = nil
        remoteReady = GroqRerank.hasKey
        if remoteReady {
            refresh()
            if !VisionEnricher.isBusy {
                let files = self.files
                QuickScanner.enqueueMissing(files: files) { [weak self] in
                    self?.onScanIdle()
                }
            }
        }
        return true
    }

    @discardableResult
    func clearRemoteKey() -> Bool {
        guard GroqRerank.clearKey() else {
            remoteSettingsError = GroqClient.lastError
            return false
        }
        remoteSettingsError = nil
        rerankTask?.cancel()
        remoteReady = GroqRerank.hasKey
        refresh()
        return true
    }

    func refresh() {
        guard !isPreview else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let request = SearchRequestVersion(generation: generation, query: query)
        localSearchTask?.cancel()
        fastSearching = false
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rerankTask?.cancel()
        reranking = false
        deepSearching = false
        precisionSearching = false
        if q.isEmpty {
            hits = files
                .sorted { $0.mtime > $1.mtime }
                .prefix(20)
                .map {
                    FileHit(
                        path: $0.path, name: $0.name, relative: $0.relative,
                        kind: $0.kind, ext: $0.ext, mtime: $0.mtime,
                        reason: "最近", score: 0,
                        snippet: LibraryIndex.recentSnippet($0),
                        highlights: [],
                        thumbPath: $0.thumbPath,
                        uploadedToCloud: $0.uploadedToCloud
                    )
                }
            status = files.isEmpty
                ? (isLoading ? "正在索引…" : (roots.isEmpty ? "未选择资料夹" : "这个资料夹是空的"))
                : "已索引 \(files.count) 个文件"
        } else {
            let snapshot = files
            let trace = SearchTraceSession()
            trace.recordRouting(SearchRouter.route(q))
            fastSearching = true
            status = "正在搜索…"
            localSearchTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 120_000_000) }
                catch { return }
                let local = await withCheckedContinuation { continuation in
                    Self.searchQueue.async {
                        continuation.resume(returning: trace.measure(
                            "fast_retrieval",
                            operation: { LibraryGateway.searchCandidates(query: q, in: snapshot) },
                            candidates: \.count
                        ))
                    }
                }
                guard let self, !Task.isCancelled,
                      request.matches(generation: self.searchGeneration, query: self.query) else { return }
                self.fastSearching = false
                let localHits = local.map(\.hit)
                self.hits = localHits
                self.status = self.statusLine(count: local.count, query: q, remote: false)
                if let error = LibraryGateway.lastError { self.status += " · " + error }
                if self.selected == nil || !localHits.contains(where: { $0.id == self.selected }) {
                    self.selected = localHits.first?.id
                }
                self.scheduleRerank(query: q, local: localHits, trace: trace)
            }
        }
        if let databaseError = LibraryGateway.lastError { status += " · " + databaseError }
        if recycleMode {
            syncJunkSelection()
            return
        }
        if let selected, hits.contains(where: { $0.id == selected }) { return }
        selected = hits.first?.id
    }

    var searchInProgress: Bool {
        fastSearching || reranking || deepSearching || precisionSearching
    }

    var jevPrecisionReady: Bool { JevRerank.usesLocalEndpoint || JevRerank.hasKey }

    /// Search is live and Jev automatically refines settled queries. Return only commits the
    /// current query; explicit precision search remains a separate, wider second pass.
    @MainActor
    func handleReturn() -> Bool {
        if recycleMode { return openSelected() }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        submittedQuery = q
        if fastSearching {
            status = jevPrecisionReady ? "正在搜索，Jev 将自动整理结果…" : "正在搜索…"
        }
        return false
    }

    @MainActor
    func startPrecisionSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard jevPrecisionReady else {
            status = "未配置 OpenRouter API Key，无法使用 Jev 精搜"
            return
        }
        let compiled = LibraryIndex.compile(q)
        guard !compiled.tokens.isEmpty || !compiled.anyOf.isEmpty else { return }
        rerankTask?.cancel()
        rerankToken += 1
        let token = rerankToken
        let snapshot = files
        let rootSnapshot = roots.map(\.path)
        let current = hits
        let trace = SearchTraceSession()
        trace.recordRouting(SearchRouter.route(q))
        reranking = false
        deepSearching = false
        precisionSearching = true
        status = "精搜 · 正在召回候选…"
        rerankTask = Task { @MainActor in
            func stillCurrent() -> Bool {
                !Task.isCancelled && token == rerankToken && query.trimmingCharacters(in: .whitespacesAndNewlines) == q
            }
            defer {
                if token == rerankToken,
                   query.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                    precisionSearching = false
                    lastSearchTrace = trace.finish(hits: hits)
                }
            }
            let semanticStarted = ProcessInfo.processInfo.systemUptime
            let semantic = await LocalSemanticIndex.shared.search(
                query: q, roots: rootSnapshot, minScore: LocalRerank.precisionWideMinScore)
            trace.record("precision_semantic", startedAt: semanticStarted, candidates: semantic.count)
            guard stillCurrent() else { return }
            let initial = await withCheckedContinuation { continuation in
                Self.searchQueue.async {
                    continuation.resume(returning: LibraryGateway.fallbackCandidates(
                        query: q,
                        in: snapshot,
                        semantic: semantic,
                        limit: JevRerank.candidateLimit
                    ))
                }
            }
            guard stillCurrent() else { return }
            let candidates = Self.precisionPool(
                current: current, widened: initial, limit: JevRerank.candidateLimit)
            guard !candidates.isEmpty else {
                status = statusLine(count: hits.count, query: q, remote: false) + " · 精搜没有找到新候选"
                return
            }
            status = "精搜 · Jev 正在判断 \(candidates.count) 条候选…"
            let judgeStarted = ProcessInfo.processInfo.systemUptime
            let outcome = await JevRerank.rerank(
                query: q, hits: candidates, files: snapshot, dropSeriouslyIrrelevant: true)
            trace.record("precision_jev", startedAt: judgeStarted, candidates: outcome.requests)
            guard stillCurrent() else { return }
            hits = outcome.hits
            if selected == nil || !hits.contains(where: { $0.id == selected }) {
                selected = hits.first?.id
            }
            let base = statusLine(count: hits.count, query: q, remote: false)
            if outcome.requests == 0 {
                status = base + " · " + (JevRerank.lastError ?? "Jev 没有返回判断")
            } else if outcome.errors > 0 {
                status = base + " · Jev 有 \(outcome.errors) 条没判完" + droppedNote(outcome.dropped)
            } else {
                status = base + " · Jev 精搜完成" + droppedNote(outcome.dropped)
            }
        }
    }

    private func droppedNote(_ count: Int) -> String {
        count > 0 ? " · 已从可能结果去掉 \(count) 条严重不相关" : ""
    }

    private static func precisionPool(current: [FileHit], widened: [FileHit], limit: Int) -> [FileHit] {
        var seen = Set<String>()
        var pool: [FileHit] = []
        for hit in current.prefix(min(current.count, 12)) where seen.insert(hit.path).inserted {
            pool.append(hit)
        }
        for hit in widened where seen.insert(hit.path).inserted {
            pool.append(hit)
            if pool.count >= limit { break }
        }
        return pool
    }

    private func scheduleRerank(query q: String, local: [FileHit], trace: SearchTraceSession) {
        let routing = SearchRouter.route(q)
        guard routing.uses(.semantic) else {
            lastSearchTrace = trace.finish(hits: local)
            return
        }
        rerankToken += 1
        let token = rerankToken
        let snapshot = files
        let rootSnapshot = roots.map(\.path)
        reranking = true
        status = statusLine(count: local.count, query: q, remote: false)
            + (jevPrecisionReady && !local.isEmpty ? " · Jev 正在整理…" : " · 正在补充语义结果…")
        rerankTask = Task { @MainActor in
            defer {
                if token == rerankToken,
                   query.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                    lastSearchTrace = trace.finish(hits: hits)
                }
            }
            // Treat a short pause as query commitment. This avoids sending every Pinyin
            // composition update to Jev while still refining every settled query.
            try? await Task.sleep(nanoseconds: 450_000_000)
            let still = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, token == rerankToken, still == q else { return }

            var rankedLocal = local
            var automaticNote = ""
            if jevPrecisionReady, !local.isEmpty {
                status = statusLine(count: local.count, query: q, remote: false) + " · Jev 正在整理…"
                let judgeStarted = ProcessInfo.processInfo.systemUptime
                let ranked = await automaticallyRank(query: q, candidates: local, files: snapshot)
                if let outcome = ranked.outcome {
                    trace.record("automatic_jev", startedAt: judgeStarted, candidates: outcome.requests)
                }
                guard !Task.isCancelled, token == rerankToken,
                      query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                rankedLocal = ranked.hits
                hits = rankedLocal
                automaticNote = automaticJevNote(ranked.outcome)
                status = statusLine(count: hits.count, query: q, remote: false) + automaticNote
                if selected == nil || !hits.contains(where: { $0.id == selected }) {
                    selected = hits.first?.id
                }
            }

            let semanticStarted = ProcessInfo.processInfo.systemUptime
            let semantic = local.isEmpty
                ? await LocalSemanticIndex.shared.search(query: q, roots: rootSnapshot)
                : []
            if local.isEmpty {
                trace.record("semantic_retrieval", startedAt: semanticStarted, candidates: semantic.count)
            }
            guard !Task.isCancelled, token == rerankToken, query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            let retrieved: [FileHit]
            if semantic.isEmpty { retrieved = local }
            else {
                retrieved = await withCheckedContinuation { continuation in
                    Self.searchQueue.async {
                        continuation.resume(returning: LibraryGateway.searchCandidates(
                            query: q, in: snapshot, semantic: semantic).map(\.hit))
                    }
                }
            }
            guard !Task.isCancelled, token == rerankToken, query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            let candidates: [FileHit]
            if local.isEmpty {
                candidates = retrieved
            } else {
                let localIDs = Set(local.map(\.id))
                candidates = rankedLocal + retrieved.filter { !localIDs.contains($0.id) }
            }
            hits = candidates
            status = statusLine(count: hits.count, query: q, remote: false)
            if selected == nil || !hits.contains(where: { $0.id == selected }) { selected = hits.first?.id }

            if jevPrecisionReady, local.isEmpty, !candidates.isEmpty {
                status = statusLine(count: hits.count, query: q, remote: false) + " · Jev 正在整理…"
                let judgeStarted = ProcessInfo.processInfo.systemUptime
                let ranked = await automaticallyRank(query: q, candidates: candidates, files: snapshot)
                if let outcome = ranked.outcome {
                    trace.record("automatic_jev", startedAt: judgeStarted, candidates: outcome.requests)
                }
                guard !Task.isCancelled, token == rerankToken,
                      query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                hits = ranked.hits
                if selected == nil || !hits.contains(where: { $0.id == selected }) {
                    selected = hits.first?.id
                }
                automaticNote = automaticJevNote(ranked.outcome)
            }
            status = statusLine(count: hits.count, query: q, remote: false) + automaticNote
            reranking = false
            let cloudCandidates = hits
            guard remoteReady, APIConfiguration.cloudRerankEnabled, !cloudCandidates.isEmpty else { return }
            reranking = true
            status = statusLine(count: hits.count, query: q, remote: true)
            let ranked = await GroqRerank.rank(query: q, files: snapshot, evidence: cloudCandidates) { [self] in
                // A response confirms the request reached the service, including rejected requests.
                // Persist independently of query cancellation, and do not refresh/re-send the query.
                let uploaded = Set(cloudCandidates.prefix(20).map(\.path))
                for file in snapshot where uploaded.contains(file.path) {
                    CloudUpload.mark(file, purpose: "search.rerank")
                }
                for i in files.indices where uploaded.contains(files[i].path) { files[i].uploadedToCloud = true }
                for i in hits.indices where uploaded.contains(hits[i].path) { hits[i].uploadedToCloud = true }
                junk = JunkClassifier.classify(files)
            }
            let after = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, token == rerankToken, after == q else { return }
            reranking = false
            if let ranked {
                hits = GroqRerank.merge(ranked: ranked, local: cloudCandidates, files: snapshot, query: q)
                let uploaded = Set(files.filter(\.uploadedToCloud).map(\.path))
                for i in hits.indices where uploaded.contains(hits[i].path) { hits[i].uploadedToCloud = true }
                status = statusLine(count: hits.count, query: q, remote: false, done: true)
                if selected == nil || !hits.contains(where: { $0.id == selected }) {
                    selected = hits.first?.id
                }
            } else if let err = GroqRerank.lastError {
                status = statusLine(count: hits.count, query: q, remote: false) + " · \(err)"
            }
        }
    }

    private static func automaticJevSignature(query: String, hits: [FileHit]) -> String {
        ([query] + hits.prefix(JevRerank.candidateLimit).map(\.id).sorted()).joined(separator: "\u{1F}")
    }

    @MainActor private func automaticallyRank(
        query: String, candidates: [FileHit], files: [IndexedFile]
    ) async -> (hits: [FileHit], outcome: JevRerank.Outcome?) {
        let signature = Self.automaticJevSignature(query: query, hits: candidates)
        if automaticJevSignature == signature {
            return (automaticJevHits, nil)
        }
        let outcome = await JevRerank.rerank(
            query: query, hits: candidates, files: files, dropSeriouslyIrrelevant: true)
        automaticJevSignature = signature
        automaticJevHits = outcome.hits
        return (outcome.hits, outcome)
    }

    private func automaticJevNote(_ outcome: JevRerank.Outcome?) -> String {
        guard let outcome else { return " · Jev 已整理" }
        if outcome.requests == 0 {
            return " · " + (JevRerank.lastError ?? "Jev 没有返回判断")
        }
        if outcome.errors > 0 {
            return " · Jev 已整理，\(outcome.errors) 条未判断" + droppedNote(outcome.dropped)
        }
        return " · Jev 已整理" + droppedNote(outcome.dropped)
    }

    private func statusLine(count: Int, query: String, remote: Bool, done: Bool = false) -> String {
        let base: String
        if count == 0, ScanProgress.shared.running {
            base = "暂未找到 · 部分内容仍在分析"
        } else {
            base = count == 0 ? "没有找到相关内容" : "找到 \(count) 个"
        }
        if remote { return base + " · 正在重排…" }
        if done { return base + " · 已重排" }
        return base
    }

    var visibleJunk: [JunkItem] {
        guard let junkFilter else { return junk }
        return junk.filter { $0.bin == junkFilter }
    }

    func toggleRecycle() {
        recycleMode.toggle()
        if recycleMode {
            query = ""
            junkPicked = []
            junkFilter = nil
            showingTrash = false
            trash = TrashBin.load()
            syncJunkSelection()
        } else {
            FilePreview.shared.close()
            refresh()
        }
    }

    func toggleJunkPicked(_ path: String) {
        if junkPicked.contains(path) { junkPicked.remove(path) }
        else { junkPicked.insert(path) }
        selected = path
    }

    func chooseDuplicateOriginal(_ path: String) {
        guard let item = junk.first(where: { $0.path == path }),
              let groupID = item.groupID
        else { return }
        let members = junk.filter { $0.groupID == groupID }
        junkPicked.subtract(members.map(\.path))
        junkPicked.formUnion(members.map(\.path).filter { $0 != path })
        JunkClassifier.chooseOriginal(path, among: members.map(\.path))
        selected = path
        junk = JunkClassifier.classify(files)
    }

    var canDismissPickedReuseSuggestions: Bool {
        !junkPicked.isEmpty && junkPicked.allSatisfy { path in
            junk.first(where: { $0.path == path })?.bin != .duplicate
        }
    }

    func dismissPickedReuseSuggestions() {
        guard canDismissPickedReuseSuggestions else { return }
        let paths = junkPicked
        for index in files.indices where paths.contains(files[index].path) {
            ReuseFeedback.markNotDraft(files[index])
            files[index].reuseDismissed = true
        }
        junkPicked.removeAll()
        if let selected, paths.contains(selected) { self.selected = nil }
        junk = JunkClassifier.classify(files)
        syncJunkSelection()
    }

    func setJunkFilter(_ bin: JunkBin?) {
        showingTrash = false
        junkFilter = bin
        junkPicked.removeAll()
        syncJunkSelection()
    }

    func showTrash() {
        showingTrash = true
        junkPicked.removeAll()
        syncJunkSelection()
    }

    func keepPicked() {
        guard !showingTrash else { return }
        let paths = Array(junkPicked)
        guard !paths.isEmpty else { return }
        JunkClassifier.keep(paths)
        junkPicked.removeAll()
        junk = JunkClassifier.classify(files)
        syncJunkSelection()
    }

    func trashPicked() {
        guard !showingTrash else { return }
        let paths = junk.filter { junkPicked.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else { return }
        recycleBusy = true
        let snapshot = files
        let roots = self.roots
        DispatchQueue.global(qos: .userInitiated).async {
            _ = TrashBin.ingest(paths: paths, files: snapshot, roots: roots)
            JunkClassifier.queueCleanup(paths, queued: false)
            let items = TrashBin.load()
            DispatchQueue.main.async {
                self.recycleBusy = false
                self.junkPicked.removeAll()
                self.trash = items
                self.reload()
            }
        }
    }

    func restorePicked() {
        guard showingTrash else { return }
        let ids = Array(junkPicked)
        guard !ids.isEmpty else { return }
        recycleBusy = true
        let roots = self.roots
        DispatchQueue.global(qos: .userInitiated).async {
            TrashBin.restore(ids: ids, roots: roots)
            let items = TrashBin.load()
            DispatchQueue.main.async {
                self.recycleBusy = false
                self.junkPicked.removeAll()
                self.trash = items
                self.reload()
            }
        }
    }

    func purgePicked() {
        guard showingTrash else { return }
        let ids = Array(junkPicked)
        guard !ids.isEmpty else { return }
        recycleBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            TrashBin.purge(ids: ids)
            let items = TrashBin.load()
            DispatchQueue.main.async {
                self.recycleBusy = false
                self.junkPicked.removeAll()
                self.trash = items
                self.syncJunkSelection()
            }
        }
    }

    func previewSelected() {
        guard let path = previewPath() else { return }
        let hit = hits.first(where: { $0.id == selected })
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
            || hit?.startSeconds != nil {
            PresentationOpener.open(
                path: path, page: hit?.page,
                startSeconds: hit?.startSeconds, endSeconds: hit?.endSeconds
            )
            return
        }
        FilePreview.shared.show(path: path)
    }

    func openSelectedFile() {
        guard let path = previewPath() else { return }
        if !recycleMode, let hit = hits.first(where: { $0.id == selected }),
           MediaOpenPolicy.shouldUseTimedPlayer(path: path, startSeconds: hit.startSeconds),
           let start = MediaOpenPolicy.seekSeconds(hit.startSeconds) {
            MediaTimeWindow.shared.pause()
            MediaExternalOpener.open(url: URL(fileURLWithPath: path), seconds: start, endSeconds: hit.endSeconds)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openSelected() -> Bool {
        if recycleMode {
            guard let selected else { return false }
            toggleJunkPicked(selected)
            return false
        }
        guard let selected, let hit = hits.first(where: { $0.id == selected }) else { return false }
        return PresentationOpener.open(
            path: hit.path, page: hit.page,
            startSeconds: hit.startSeconds, endSeconds: hit.endSeconds
        )
    }

    func revealSelected() {
        guard let path = previewPath() ?? junkPicked.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func moveSelection(_ delta: Int) {
        let ids = recycleMode
            ? (showingTrash ? trash.map(\.id) : visibleJunk.map(\.id))
            : (hasActiveQuery ? (directHits + possibleHits) : hits).map(\.id)
        guard !ids.isEmpty else { return }
        let idx = ids.firstIndex(of: selected ?? "") ?? 0
        let next = min(max(idx + delta, 0), ids.count - 1)
        selected = ids[next]
    }

    func selectRecycleItem(_ id: String) {
        selected = id
    }

    var reuseProgress: Double {
        if reuseSummarizing { return 0.9 }
        return reusePhase.progress
    }

    var reuseStageLabel: String {
        if reuseRevising { return "正在按你的要求继续修改…" }
        if reuseSummarizing { return "正在对照原图写修改…" }
        return reusePhase.stageLabel
    }

    var reuseOriginalPath: String? { reuseAnchor }

    var reuseResultPath: String? {
        guard case .done(_, let path) = reusePhase else { return nil }
        return path
    }

    var canReuse: Bool {
        !showingTrash && reuseTarget() != nil && !reusePhase.isActive
    }

    func startReuse() {
        guard !showingTrash else { return }
        let file: IndexedFile?
        if reusePhase.isActive, let reuseAnchor {
            file = files.first(where: { $0.path == reuseAnchor }) ?? reuseTarget()
        } else {
            file = reuseTarget()
        }
        guard let file else { return }
        FilePreview.shared.close()
        reuseTask?.cancel()
        reuseOther = ""
        reusePicks = [:]
        reuseSummary = nil
        reuseSummarizing = false
        reuseFollowUp = ""
        reuseFollowUpError = nil
        reuseRevising = false
        reuseOriginalQueued = false
        reuseAnchor = file.path
        ReuseFeedback.begin(file)
        if !GroqRerank.hasKey {
            reusePhase = .failed("先在右上角「API 设置」粘贴 OpenRouter API Key")
            return
        }
        reusePhase = .proposing
        let snapshot = file
        reuseTask = Task { @MainActor in
            if snapshot.kind == .image {
                let ask = await ImageReuse.inspect(file: snapshot)
                guard !Task.isCancelled else { return }
                if let ask {
                    reusePicks = [:]
                    noteCloudUpload([snapshot.path])
                    reusePhase = .ask(ask)
                } else {
                    reusePhase = .failed(GroqClient.lastError ?? "看不出这张图能怎么补")
                }
                return
            }
            if TextReuse.shouldHandle(snapshot) {
                let ask = await TextReuse.inspect(file: snapshot)
                guard !Task.isCancelled else { return }
                if let ask {
                    reusePicks = [:]
                    noteCloudUpload([snapshot.path])
                    reusePhase = .ask(ask)
                } else {
                    reusePhase = .failed(GroqClient.lastError ?? "看不出这篇能怎么补")
                }
                return
            }
            let proposal = await GroqReuse.propose(file: snapshot)
            guard !Task.isCancelled else { return }
            if let proposal {
                noteCloudUpload([snapshot.path])
                reusePhase = .choose(proposal)
            } else {
                reusePhase = .failed(GroqClient.lastError ?? "没有给出可用方向")
            }
        }
    }

    func pickReuse(_ option: ReuseOption) {
        guard case .choose(let proposal) = reusePhase else { return }
        if option.id == "D" {
            let custom = reuseOther.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !custom.isEmpty else { return }
        }
        runGenerate(proposal: proposal, option: option)
    }

    func toggleReuseChoice(_ choice: String) {
        if reusePicks["direction"] == choice {
            reusePicks.removeAll()
        } else {
            reusePicks = ["direction": choice]
            reuseOther = ""
        }
    }

    func submitImageReuse(skip: Bool) {
        guard case .ask(let ask) = reusePhase else { return }
        guard let file = files.first(where: { $0.path == ask.path }) else {
            reusePhase = .failed("原文件不在资料库里了")
            return
        }
        let picks = skip ? [:] : reusePicks
        let extra = skip ? "" : reuseOther
        let isImage = file.kind == .image
        reuseTask?.cancel()
        reusePhase = .writing(isImage ? "补全这张图" : "补全这份稿")
        reuseSummary = nil
        reuseSummarizing = true
        reuseTask = Task { @MainActor in
            let dest: URL?
            if isImage {
                dest = await ImageReuse.complete(
                    file: file, ask: ask, picks: picks, extra: extra
                )
            } else {
                dest = await TextReuse.complete(
                    file: file, ask: ask, picks: picks, extra: extra
                )
            }
            guard !Task.isCancelled else { return }
            guard let dest else {
                reusePhase = .failed(GroqClient.lastError ?? "没有补出来")
                return
            }
            noteCloudUpload([file.path])
            LibraryGateway.recordArtifact(source: file, path: dest.path)
            ReuseFeedback.markResolved(file, resultPath: dest.path)
            reusePhase = .done(name: dest.lastPathComponent, path: dest.path)
            reloadIndexOnly()
            let text: String
            if isImage {
                text = await ImageReuse.summarize(original: file, result: dest.path)
            } else {
                text = await TextReuse.summarize(original: file, result: dest.path)
            }
            guard !Task.isCancelled else { return }
            noteCloudUpload([file.path, dest.path])
            reloadIndexOnly()
            if case .done(_, let path) = reusePhase, path == dest.path {
                reuseSummary = text
                reuseSummarizing = false
            }
        }
    }

    func cancelReuse() {
        reuseTask?.cancel()
        reuseTask = nil
        if let reuseAnchor, let file = files.first(where: { $0.path == reuseAnchor }) {
            ReuseFeedback.close(file)
        }
        reusePhase = .idle
        reuseOther = ""
        reusePicks = [:]
        reuseSummary = nil
        reuseSummarizing = false
        reuseFollowUp = ""
        reuseFollowUpError = nil
        reuseRevising = false
        reuseOriginalQueued = false
        reuseAnchor = nil
    }

    func finishReuse() {
        FilePreview.shared.close()
        cancelReuse()
        reload()
    }

    func openReuseResult() {
        guard case .done(_, let path) = reusePhase else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealReuseResult() {
        guard case .done(_, let path) = reusePhase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func submitReuseFollowUp() {
        guard case .done(_, let currentPath) = reusePhase,
              let originalPath = reuseAnchor,
              let file = files.first(where: { $0.path == originalPath })
        else { return }
        let instruction = reuseFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !reuseRevising else { return }
        reuseTask?.cancel()
        reuseRevising = true
        reuseSummarizing = false
        reuseFollowUpError = nil
        reuseTask = Task { @MainActor in
            let resultPath: String?
            if file.kind == .image {
                resultPath = await ImageReuse.revise(
                    file: file, currentPath: currentPath, instruction: instruction
                )?.path
            } else {
                let draft = await GroqReuse.revise(
                    file: file, currentPath: currentPath, instruction: instruction
                )
                resultPath = draft.flatMap { GroqReuse.write($0, nextTo: currentPath) }
            }
            guard !Task.isCancelled else { return }
            guard let resultPath else {
                reuseRevising = false
                reuseFollowUpError = GroqClient.lastError ?? "这次修改没有生成新版本"
                return
            }
            LibraryGateway.recordArtifact(source: file, path: resultPath)
            ReuseFeedback.markCurrentResult(file, resultPath: resultPath, detail: instruction)
            reuseFollowUp = ""
            reusePhase = .done(
                name: URL(fileURLWithPath: resultPath).lastPathComponent,
                path: resultPath
            )
            reuseRevising = false
            reuseSummary = "已按要求修改：\(instruction)"
            reloadIndexOnly()
        }
    }

    func addReuseOriginalToCleanup() {
        guard let path = reuseAnchor else { return }
        if let file = files.first(where: { $0.path == path }) {
            ReuseFeedback.record(file, action: "queued_original_cleanup")
        }
        JunkClassifier.queueCleanup([path], queued: true)
        reuseOriginalQueued = true
        junk = JunkClassifier.classify(files)
        junkPicked.insert(path)
    }

    private func restoreReuseSessionIfNeeded() {
        guard !didRestoreReuseSession, !reusePhase.isActive else { return }
        didRestoreReuseSession = true
        guard let file = files
            .filter(\.reuseSessionActive)
            .max(by: { ($0.reuseFeedbackUpdatedAt ?? .distantPast) < ($1.reuseFeedbackUpdatedAt ?? .distantPast) })
        else { return }
        reuseAnchor = file.path
        reuseOriginalQueued = ((try? AppDatabase.open().preferencePaths("cleanup")) ?? []).contains(file.path)
        if let path = file.reuseResultPath, FileManager.default.fileExists(atPath: path) {
            reuseSummary = "已恢复上次未关闭的咔哒对比。"
            reusePhase = .done(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        } else {
            reusePhase = .failed("上次生成被中断，原文件没有变化。可以重新开始。")
        }
    }

    private func runGenerate(proposal: ReuseProposal, option: ReuseOption) {
        guard let file = files.first(where: { $0.path == proposal.path }) else {
            reusePhase = .failed("原文件不在资料库里了")
            return
        }
        reuseTask?.cancel()
        reusePhase = .writing(option.title)
        let other = reuseOther
        reuseTask = Task { @MainActor in
            let draft = await GroqReuse.generate(file: file, option: option, other: other)
            guard !Task.isCancelled else { return }
            guard let draft else {
                reusePhase = .failed(GroqClient.lastError ?? "没有写出新版本")
                return
            }
            noteCloudUpload([file.path])
            guard let path = GroqReuse.write(draft, nextTo: file.path) else {
                reusePhase = .failed(GroqClient.lastError ?? "无法保存新文件")
                return
            }
            LibraryGateway.recordArtifact(source: file, path: path)
            ReuseFeedback.markResolved(file, resultPath: path)
            reusePhase = .done(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
            reloadIndexOnly()
        }
    }

    private func noteCloudUpload(_ paths: [String]) {
        let set = Set(paths)
        var changed = false
        for i in files.indices where set.contains(files[i].path) && !files[i].uploadedToCloud {
            files[i].uploadedToCloud = true
            changed = true
        }
        guard changed else { return }
        junk = JunkClassifier.classify(files)
        refresh()
    }

    private func reuseTarget() -> IndexedFile? {
        if recycleMode {
            if showingTrash { return nil }
            if let selected, let item = visibleJunk.first(where: { $0.id == selected }) {
                return files.first { $0.path == item.path }
            }
            if let path = junkPicked.first {
                return files.first { $0.path == path }
            }
            return nil
        }
        guard let selected else { return nil }
        return files.first { $0.path == selected }
    }

    private func previewPath() -> String? {
        guard let selected else { return nil }
        if showingTrash {
            return trash.first { $0.id == selected }?.storedPath
        }
        if recycleMode {
            return visibleJunk.first { $0.id == selected }?.path ?? selected
        }
        return hits.first { $0.id == selected }?.path ?? selected
    }

    private func syncJunkSelection() {
        if showingTrash {
            if let selected, trash.contains(where: { $0.id == selected }) { return }
            self.selected = trash.first?.id
            return
        }
        if let selected, visibleJunk.contains(where: { $0.id == selected }) { return }
        self.selected = visibleJunk.first?.id
    }
}

struct SearchPanelView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var semantic = SemanticProgress.shared
    var onDismiss: () -> Void
    @State private var showRoots = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.recycleMode {
                    Image(systemName: "arrow.3.trianglepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("咔哒一下，旧文件有了去处。")
                        .font(.system(size: 17, weight: .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    SearchInput(
                        text: $model.query,
                        suggestion: model.tabSuggestion,
                        acceptSuggestion: model.acceptTabSuggestion,
                        moveSuggestion: model.moveTabSuggestion,
                        dismissSuggestion: model.dismissTabSuggestion
                    ) {
                        if model.handleReturn() { onDismiss() }
                    }
                    .frame(height: 26)
                }
                RecycleHeaderButton(model: model)
                Button {
                    showRoots = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("资料夹")
                .popover(isPresented: $showRoots, arrowEdge: .bottom) {
                    RootsPopover(model: model)
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .help("设置 · 查看本机扫描进度与配置云端功能")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    APISettingsView(model: model)
                        .frame(height: 480)
                        .onExitCommand { showSettings = false }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            Group {
                if model.roots.isEmpty {
                    EmptyRootsView(
                        demoAvailable: model.demoAvailable,
                        onPick: { model.addFolders(from: NSApp.keyWindow) },
                        onDemo: { model.addDemoLibrary() }
                    )
                } else if model.recycleMode {
                    RecycleListView(model: model)
                } else if model.hits.isEmpty {
                    EmptyHitsView(model: model)
                } else {
                    SearchResultsList(model: model, onDismiss: onDismiss)
                }
            }

            HStack(spacing: 8) {
                if model.recycleMode {
                    if model.showingTrash {
                        Text(model.junkPicked.isEmpty
                             ? (model.trash.isEmpty ? "垃圾桶是空的" : "\(model.trash.count) 项 · 30 天后清除")
                             : "已选 \(model.junkPicked.count)")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    } else {
                        Text(model.junkPicked.isEmpty
                             ? (model.isLoading && model.junk.isEmpty
                                ? "正在整理候选…"
                                : (model.visibleJunk.isEmpty ? "没有需要处理的项" : "\(model.visibleJunk.count) 项"))
                             : "已选 \(model.junkPicked.count)")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                    Spacer()
                    if model.showingTrash {
                        Button("预览") { model.previewSelected() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(model.selected == nil)
                        Button("还原") { model.restorePicked() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(model.junkPicked.isEmpty || model.recycleBusy)
                        Button(model.recycleBusy ? "正在清除…" : "立即清除") {
                            model.purgePicked()
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.medium)
                        .foregroundStyle(model.junkPicked.isEmpty ? .tertiary : .primary)
                        .disabled(model.junkPicked.isEmpty || model.recycleBusy)
                    } else {
                        RecycleActionButton(title: "不再推荐", symbol: "eye.slash") {
                            model.dismissPickedReuseSuggestions()
                        }
                        .disabled(!model.canDismissPickedReuseSuggestions || model.recycleBusy)
                        RecycleActionButton(title: "咔哒一下", symbol: "sparkles") {
                            if model.reusePhase.isActive {
                                AppDelegate.shared.presentReuseWindow()
                            } else {
                                model.startReuse()
                            }
                        }
                            .help(model.reusePhase.isActive ? "查看咔哒进度" : "将选中的文件补全或生成新版本")
                            .disabled((!model.canReuse && !model.reusePhase.isActive) || model.recycleBusy)
                        RecycleActionButton(
                            title: model.recycleBusy ? "正在移入…" : "移入垃圾桶",
                            symbol: "trash"
                        ) {
                            model.trashPicked()
                        }
                        .disabled(model.junkPicked.isEmpty || model.recycleBusy)
                    }
                } else {
                    if model.searchInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.searchInProgress ? model.status : (model.tabSuggestionStatus ?? model.status))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    PrecisionSearchButton(model: model)
                    Button {
                        showRoots = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text(model.rootsLabel)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .onReceive(semantic.$revision.dropFirst()) { _ in
            if !model.query.isEmpty { model.refreshAfterIndexUpdate() }
        }
        .frame(width: 620, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onExitCommand(perform: onDismiss)
        .onAppear {
            guard !model.isPreview else { return }
            ScanControl.shared.noteInteractiveWork(settleAfter: 0.8)
            model.refresh()
        }
    }
}

struct BackgroundScanView: View {
    @ObservedObject var model: SearchModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("后台扫描")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭扫描面板")
            }

            ScrollView {
                IndexingStatusView(model: model)
                    .padding(.vertical, 8)
            }

            Text("隐藏窗口不会停止扫描。输入或检索时，后台队列会自动让路，空闲后继续。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onExitCommand(perform: onDismiss)
    }
}

private struct SearchResultsList: View {
    @ObservedObject var model: SearchModel
    let onDismiss: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.hasActiveQuery {
                        if !model.possibleHits.isEmpty {
                            HStack(spacing: 8) {
                                tierCount("直接命中", count: model.directHits.count, emphasized: true) {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        proxy.scrollTo("direct-results", anchor: .top)
                                    }
                                }
                                tierCount("你可能还在找", count: model.possibleHits.count, emphasized: false) {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        proxy.scrollTo("possible-results", anchor: .top)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        }
                        if model.directHits.isEmpty {
                            deepSearchPrompt
                        } else {
                            header("直接命中", detail: "有明确的文件名、原文、OCR 或编号证据")
                                .id("direct-results")
                            rows(model.directHits)
                        }
                        if !model.possibleHits.isEmpty {
                            header("你可能还在找", detail: "语义相关，但证据还不够确定")
                                .id("possible-results")
                                .padding(.top, model.directHits.isEmpty ? 0 : 8)
                            rows(model.possibleHits)
                        }
                    } else {
                        rows(model.hits)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .onChange(of: model.selected) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func tierCount(_ title: String, count: Int, emphasized: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(emphasized ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(emphasized ? 0.035 : 0.055))
            )
        }
        .buttonStyle(.plain)
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var deepSearchPrompt: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("没有足够确定的直接命中")
                    .font(.system(size: 12, weight: .medium))
                Text("扩大召回范围，再让 Jev 判断更多候选")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(model.precisionSearching ? "精搜中" : "开始精搜") {
                model.startPrecisionSearch()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .disabled(model.precisionSearching || model.deepSearching)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder private func rows(_ hits: [FileHit]) -> some View {
        ForEach(hits) { hit in
            HitRow(hit: hit, selected: model.selected == hit.id, onPlay: {
                model.selected = hit.id
                model.previewSelected()
            })
                .id(hit.id)
                .onTapGesture(count: 2) {
                    model.selected = hit.id
                    if model.openSelected() { onDismiss() }
                }
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.selected = hit.id
                }
                .contextMenu {
                    if let start = MediaOpenPolicy.seekSeconds(hit.startSeconds),
                       MediaOpenPolicy.shouldUseTimedPlayer(path: hit.path, startSeconds: start) {
                        Button("从 \(MediaOpenPolicy.clock(start)) 播放") {
                            model.selected = hit.id
                            model.previewSelected()
                        }
                        Button(MediaExternalOpener.title(url: URL(fileURLWithPath: hit.path), seconds: start)) {
                            model.selected = hit.id
                            model.openSelectedFile()
                        }
                        Divider()
                    }
                    Button("在 Finder 中显示") {
                        model.selected = hit.id
                        model.revealSelected()
                    }
                }
        }
    }
}

private struct RecycleActionButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 14, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled ? 0.06 : 0.03))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
    }
}

private struct PrecisionSearchButton: View {
    @ObservedObject var model: SearchModel

    private var visible: Bool {
        !model.recycleMode && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabled: Bool {
        model.jevPrecisionReady && !model.precisionSearching && !model.deepSearching
    }

    var body: some View {
        if visible {
            Button {
                model.startPrecisionSearch()
            } label: {
                Label(model.precisionSearching ? "精搜中" : "精搜", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                    .foregroundStyle(enabled ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(model.jevPrecisionReady ? "扩大召回范围并用 Jev 精排" : "未配置 OpenRouter API Key")
        }
    }
}

struct ReuseSessionView: View {
    @ObservedObject var model: SearchModel

    private var showingComparison: Bool {
        if case .done = model.reusePhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ReuseFlowMark(active: model.reusePhase.isActive && !showingComparison)
                Text("咔哒一下")
                    .font(.system(size: 22, weight: .medium))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if model.reusePhase.isActive, !showingComparison {
                VStack(alignment: .leading, spacing: 6) {
                    ReuseFlowProgress(value: model.reuseProgress)
                    Text(model.reuseStageLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            ReusePanel(model: model)

            HStack(spacing: 8) {
                footer
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(
            minWidth: showingComparison ? 800 : 480,
            idealWidth: showingComparison ? 1040 : 480,
            maxWidth: .infinity,
            minHeight: showingComparison ? 560 : 540,
            idealHeight: showingComparison ? 700 : 540,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.reusePhase {
        case .done(let name, _):
            Text(name)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button(model.reuseOriginalQueued ? "原件已在待清理" : "原件加入待清理") {
                model.addReuseOriginalToCleanup()
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.reuseOriginalQueued)
            Button("完成") { model.finishReuse() }
                .buttonStyle(.plain)
                .fontWeight(.medium)
        case .failed:
            Text("没写出来")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("再试") { model.startReuse() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button("取消") { model.cancelReuse() }
                .buttonStyle(.plain)
        case .ask:
            Text("原文不动。补全后放在旁边")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("取消") { model.cancelReuse() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button("咔哒一下") { model.submitImageReuse(skip: false) }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.reusePicks["direction"] == nil
                        && model.reuseOther.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        default:
            Text("原文不动")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("取消") { model.cancelReuse() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReuseFlowMark: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.045))
            if active {
                AngularGradient(
                    colors: [
                        Color.accentColor.opacity(0.45),
                        Color.green.opacity(0.30),
                        Color.accentColor.opacity(0.45),
                    ],
                    center: .center
                )
                .rotationEffect(.degrees(turning ? 360 : 0))
                .opacity(0.55)
                .mask {
                    Circle().stroke(lineWidth: 2)
                }
            }
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .frame(width: 30, height: 30)
        .onAppear { turning = !reduceMotion }
        .animation(
            reduceMotion ? nil : .linear(duration: 5).repeatForever(autoreverses: false),
            value: turning
        )
    }
}

private struct ReuseFlowProgress: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flowing = false

    var body: some View {
        GeometryReader { proxy in
            let amount = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.72),
                        Color.green.opacity(0.42),
                        Color.accentColor.opacity(0.72),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(proxy.size.width * 1.5, 80))
                .offset(x: flowing ? -proxy.size.width * 0.5 : 0)
                .mask(alignment: .leading) {
                    Capsule()
                        .frame(width: max(amount > 0 ? 5 : 0, proxy.size.width * amount))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .onAppear { flowing = !reduceMotion }
        .animation(
            reduceMotion ? nil : .linear(duration: 2.8).repeatForever(autoreverses: false),
            value: flowing
        )
    }
}

private struct ReusePanel: View {
    @ObservedObject var model: SearchModel
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.reusePhase {
            case .proposing:
                status("正在看这份材料…")
            case .writing(let title):
                status(title.hasPrefix("补全") ? "正在补全这张图…" : "正在写：\(title)")
            case .failed(let message):
                status(message)
            case .done:
                ReuseComparisonView(model: model)
            case .choose(let proposal):
                chooseView(proposal)
            case .ask(let ask):
                askView(ask)
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func chooseView(_ proposal: ReuseProposal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                FileNameLine(name: proposal.name)
                    .font(.system(size: 16, weight: .medium))
                Text(proposal.brief)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(proposal.options) { option in
                optionRow(letter: option.id, title: option.title) {
                    model.pickReuse(option)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text("自定义")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .leading)
                TextField("输入你想要的方向", text: $model.reuseOther)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($otherFocused)
                    .onSubmit { model.pickReuse(GroqReuse.other) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(otherFocused ? Color.primary.opacity(0.05) : Color.clear)
            )
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
    }

    private func askView(_ ask: ImageAsk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                FileNameLine(name: ask.name)
                    .font(.system(size: 16, weight: .medium))
                Text(ask.diagnosis)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !ask.anchors.isEmpty {
                    Text("必须用上：\(ask.anchors)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(ask.choices) { choice in
                    ReuseChoiceCard(
                        choice: choice,
                        selected: model.reusePicks["direction"] == choice.id
                    ) {
                        model.toggleReuseChoice(choice.id)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("自定义，例如：保留铅笔质感并轻轻上色", text: $model.reuseOther)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($otherFocused)
                    .onSubmit { model.submitImageReuse(skip: false) }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(otherFocused ? 0.055 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(otherFocused ? 0.14 : 0.07), lineWidth: 1)
                    }
            }
            .padding(.horizontal, 18)
            .onChange(of: model.reuseOther) { _, value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.reusePicks.removeAll()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func optionRow(letter: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(letter)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .leading)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

private struct ReuseChoiceCard: View {
    let choice: ImageAskChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Text(choice.id)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.65))
                Text(choice.title)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                selected ? Color.accentColor.opacity(0.34) : Color.primary.opacity(0.07),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ReuseComparisonView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ReusePreviewPane(label: "原版", path: model.reuseOriginalPath)
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                ReusePreviewPane(label: "当前版本", path: model.reuseResultPath)
                    .overlay {
                        if model.reuseRevising {
                            ZStack {
                                Rectangle().fill(.ultraThinMaterial)
                                VStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("正在继续修改…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
            }
            .frame(maxHeight: .infinity)

            if model.reuseSummarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在对照原版整理修改说明…")
                }
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            } else if let summary = model.reuseSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                TextField("继续修改当前版本，例如：第 3 页再简洁一点", text: $model.reuseFollowUp)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($followUpFocused)
                    .disabled(model.reuseRevising)
                    .onSubmit { model.submitReuseFollowUp() }
                Button {
                    model.submitReuseFollowUp()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            model.reuseFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    model.reuseRevising
                        || model.reuseFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
            if let error = model.reuseFollowUpError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

private struct ReusePreviewPane: View {
    let label: String
    let path: String?
    @State private var image: NSImage?
    @State private var text: String?

    private var fileExtension: String {
        guard let path else { return "" }
        return URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    private var isPDF: Bool { fileExtension == "pdf" }

    private var isText: Bool {
        ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log"].contains(fileExtension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let path {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let path {
                    Button("打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("打开\(label)")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("在 Finder 中显示")
                    .accessibilityLabel("在 Finder 中显示\(label)")
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.028))
                if isPDF, let path {
                    ReusePDFPreview(path: path)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .padding(1)
                } else if isText {
                    ScrollView {
                        Text(text ?? "正在读取…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else if let path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.075), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadPreview() }
        .onChange(of: path) { _, _ in loadPreview() }
    }

    private func loadPreview() {
        image = nil
        text = nil
        guard let path else { return }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "pdf" { return }
        if ["txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log"].contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                let preview = Self.loadText(path)
                DispatchQueue.main.async {
                    guard self.path == path else { return }
                    self.text = preview
                }
            }
            return
        }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(ext),
           let direct = NSImage(contentsOfFile: path) {
            image = direct
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 820, height: 560),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async {
                guard self.path == path else { return }
                self.image = representation?.nsImage
            }
        }
    }

    private static func loadText(_ path: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "无法读取这份文本"
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 160_000)) ?? Data()
        guard !data.isEmpty else { return "这份文本是空的" }
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "无法识别这份文本的编码"
        return data.count >= 160_000 ? decoded + "\n\n…仅显示前 160 KB" : decoded
    }
}

private struct ReusePDFPreview: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL?.path != path else { return }
        view.document = PDFDocument(url: URL(fileURLWithPath: path))
        view.layoutDocumentView()
    }
}

private struct RecycleHeaderButton: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        Button {
            model.toggleRecycle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.3.trianglepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.recycleMode ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(model.recycleMode ? Color.primary.opacity(0.08) : Color.clear)
                    )
                if !model.recycleMode, model.junk.count > 0 {
                    Text(model.junk.count > 9 ? "9+" : "\(model.junk.count)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.45)))
                        .offset(x: 3, y: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.recycleMode ? "返回搜索" : "回收")
        .help(model.recycleMode ? "返回搜索" : "回收")
        .disabled(model.roots.isEmpty)
    }
}

private struct RecycleListView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.junk.isEmpty || !model.trash.isEmpty {
                HStack(spacing: 4) {
                    if !model.junk.isEmpty {
                        chip(title: "全部", count: model.junk.count, active: !model.showingTrash && model.junkFilter == nil) {
                            model.setJunkFilter(nil)
                        }
                        ForEach(JunkBin.allCases, id: \.self) { bin in
                            let n = model.junk.filter { $0.bin == bin }.count
                            chip(title: bin.title, count: n, active: !model.showingTrash && model.junkFilter == bin) {
                                model.setJunkFilter(bin)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    chip(title: "垃圾桶", count: model.trash.count, active: model.showingTrash) {
                        model.showTrash()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }

            if model.showingTrash {
                trashBody
            } else if model.isLoading && model.junk.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在整理候选…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleJunk.isEmpty {
                VStack(spacing: 6) {
                    Text(model.junk.isEmpty ? "没有需要处理的项" : "这一类是空的")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    if model.junk.isEmpty {
                        Text("明确可补全、可优化和完全重复的文件会出现在这里")
                            .font(.system(size: 12))
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemList
            }
        }
    }

    private var trashBody: some View {
        Group {
            if model.trash.isEmpty {
                VStack(spacing: 6) {
                    Text("垃圾桶是空的")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text("移入的文件会在这里留 30 天")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                recycleScroll(ids: model.trash.map(\.id)) {
                    ForEach(model.trash) { item in
                        RecycleRow(
                            name: item.name,
                            reason: item.reason,
                            relative: item.relative,
                            snippet: "",
                            thumbPath: item.storedPath,
                            filePath: item.storedPath,
                            picked: model.junkPicked.contains(item.id),
                            selected: model.selected == item.id,
                            onSelect: { model.selectRecycleItem(item.id) },
                            onToggle: { model.toggleJunkPicked(item.id) },
                            onPreview: { model.selectRecycleItem(item.id); model.previewSelected() },
                            onOpen: { model.selectRecycleItem(item.id); model.openSelectedFile() }
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private var itemList: some View {
        recycleScroll(ids: model.visibleJunk.map(\.id)) {
            ForEach(model.visibleJunk) { item in
                if item.suggestedOriginal, let groupID = item.groupID {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                        Text("完全重复 · \(model.junk.filter { $0.groupID == groupID }.count) 份")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                }
                RecycleRow(
                    name: item.name,
                    reason: item.reason,
                    relative: item.relative,
                    snippet: item.snippet,
                    thumbPath: item.thumbPath ?? item.path,
                    filePath: item.path,
                    uploadedToCloud: item.uploadedToCloud,
                    picked: model.junkPicked.contains(item.id),
                    selected: model.selected == item.id,
                    actionTitle: item.bin == .duplicate ? "保留这份" : nil,
                    onSelect: { model.selectRecycleItem(item.id) },
                    onToggle: { model.toggleJunkPicked(item.path) },
                    onPreview: { model.selectRecycleItem(item.id); model.previewSelected() },
                    onOpen: { model.selectRecycleItem(item.id); model.openSelectedFile() },
                    onAction: item.bin == .duplicate
                        ? { model.chooseDuplicateOriginal(item.path) }
                        : nil
                )
                .id(item.id)
            }
        }
    }

    private func recycleScroll<Content: View>(
        ids: [String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rows = content()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    rows
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .onChange(of: model.selected) { _, id in
                if let id, ids.contains(id) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func chip(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(active ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct RecycleRow: View {
    let name: String
    let reason: String
    let relative: String
    let snippet: String
    let thumbPath: String
    let filePath: String
    var uploadedToCloud = false
    let picked: Bool
    let selected: Bool
    var actionTitle: String? = nil
    var onSelect: () -> Void
    var onToggle: () -> Void
    var onPreview: () -> Void
    var onOpen: () -> Void
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(picked ? Color.primary : Color.primary.opacity(0.22))
                .onTapGesture(perform: onToggle)
            VStack(alignment: .leading, spacing: 3) {
                FileNameLine(name: name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(snippet.isEmpty ? Color.secondary : Color.primary.opacity(0.45))
                    .lineLimit(1)
                Text(relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if uploadedToCloud {
                CloudUploadBadge()
            }
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                    )
            }
            FileThumb(thumbPath: thumbPath, filePath: filePath)
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "eye")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                            .padding(4)
                    }
                }
                .help("预览")
                .onTapGesture(perform: onPreview)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
    }
}

private struct EmptyHitsView: View {
    @ObservedObject var model: SearchModel
    var body: some View {
        VStack(spacing: 12) {
            let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty {
                Text(model.isLoading ? "正在索引…" : "这个资料夹是空的")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else if model.fastSearching {
                ProgressView("正在搜索…")
                    .controlSize(.small)
            } else if model.precisionSearching {
                Text("正在用 Jev 精搜…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if model.deepSearching {
                Text("快速检索没找到，正在用 Jev 核对放宽候选…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if model.reranking {
                Text("正在检索，Jev 会自动整理结果…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if model.jevPrecisionReady {
                Text("快速检索没有找到确定结果")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("开始精搜") { model.startPrecisionSearch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if GroqRerank.shouldRun(query: model.query), !model.remoteReady {
                Text("没有找到相关文件。可换一个关键词，或在设置中安装本机模型。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("没有找到相关文件")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

}

private struct EmptyRootsView: View {
    let demoAvailable: Bool
    var onPick: () -> Void
    var onDemo: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("选择要搜索的资料夹")
                .font(.system(size: 15, weight: .medium))
            Text("只索引你选择的资料夹，文件留在原处。\n未配置 API Key 时，搜索和内容分析在本机完成。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onPick) {
                Text("选择文件夹…")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor.opacity(0.85))
            if demoAvailable {
                Button("使用演示资料库", action: onDemo)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct RootsPopover: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var photoLibrary = PhotoLibrarySync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资料夹")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if model.roots.isEmpty {
                Text("还没有选择")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.roots, id: \.path) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(
                                of: FileManager.default.homeDirectoryForCurrentUser.path,
                                with: "~"
                            ))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.removeRoot(url)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移出索引")
                    }
                }
            }
            Divider()
            Button {
                model.addFolders(from: NSApp.keyWindow)
            } label: {
                Label("添加文件夹…", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            Button { model.addPhotos() } label: {
                Label(photoLibrary.connected ? "同步照片图库" : "连接照片图库…", systemImage: "photo.on.rectangle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(photoLibrary.busy)
            if photoLibrary.connected {
                Toggle("允许从 iCloud 下载", isOn: $photoLibrary.downloadFromICloud)
                    .font(.system(size: 11))
                if photoLibrary.failed > 0 {
                    Button("重试 \(photoLibrary.failed) 项照片") { photoLibrary.retryFailed() }
                        .disabled(photoLibrary.busy)
                }
            }
            Text(photoLibrary.status.isEmpty
                 ? "一次授权后自动增量同步，最近拍摄的照片优先。分析副本不会改变图库原片。"
                 : photoLibrary.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.demoAvailable {
                Button("添加演示资料库") {
                    model.addDemoLibrary()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct FileNameLine: View {
    let name: String
    var highlighted: AttributedString? = nil

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                Text(name)
            }
        }
        .lineLimit(1)
    }
}

private struct HitRow: View {
    let hit: FileHit
    let selected: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    FileNameLine(
                        name: hit.name,
                        highlighted: highlightedSnippet(hit.name, terms: hit.highlights, size: 13.5, weight: .medium, base: .primary)
                    )
                    if MediaOpenPolicy.shouldUseTimedPlayer(path: hit.path, startSeconds: hit.startSeconds),
                       let start = MediaOpenPolicy.seekSeconds(hit.startSeconds) {
                        Button(action: onPlay) {
                            Label(MediaOpenPolicy.clock(start), systemImage: "play.fill")
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("从命中位置播放")
                        .accessibilityLabel("从 \(MediaOpenPolicy.clock(start)) 播放 \(hit.name)")
                    }
                }
                if !hit.snippet.isEmpty {
                    Text(highlightedSnippet(hit.snippet, terms: hit.highlights, size: 12, weight: .regular, base: .secondary))
                        .lineLimit(2)
                }
                Text(hit.relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if hit.uploadedToCloud {
                CloudUploadBadge()
            }
            FileThumb(
                thumbPath: hit.thumbPath ?? hit.path,
                filePath: hit.path
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct FileThumb: View {
    let thumbPath: String
    let filePath: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: filePath))
                    .resizable()
                    .interpolation(.high)
                    .padding(12)
            }
        }
        .frame(width: 76, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { ThumbCache.shared.fetch(thumbPath) { image = $0 } }
    }
}

private final class ThumbCache {
    static let shared = ThumbCache()
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func fetch(_ path: String, done: @escaping (NSImage?) -> Void) {
        lock.lock()
        if let cached = images[path] {
            lock.unlock()
            done(cached)
            return
        }
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Self.loadImage(path)
            self.store(path, img)
            DispatchQueue.main.async { done(img) }
        }
    }

    private static func loadImage(_ path: String) -> NSImage? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"].contains(ext) {
            return NSImage(contentsOfFile: path)
        }
        if ["csv", "tsv", "txt", "md", "json"].contains(ext) {
            if let drawn = drawTextPreview(path: path, ext: ext) {
                return drawn
            }
        }
        return qlThumbnail(path)
    }

    private static func drawTextPreview(path: String, ext: String) -> NSImage? {
        guard let raw = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline).prefix(6).map { line -> String in
            let s = String(line)
            return s.count > 42 ? String(s.prefix(42)) + "…" : s
        }
        guard !lines.isEmpty else { return nil }
        let size = NSSize(width: 176, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        var y = size.height - 16
        for line in lines {
            let str = line as NSString
            str.draw(
                at: NSPoint(x: 8, y: y),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            y -= 18
            if y < 6 { break }
        }
        image.unlockFocus()
        return image
    }

    private static func qlThumbnail(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 176, height: 128),
            scale: 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )
        let sem = DispatchSemaphore(value: 0)
        var image: NSImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            image = rep?.nsImage
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return image
    }

    private func store(_ path: String, _ image: NSImage?) {
        guard let image else { return }
        lock.lock()
        images[path] = image
        lock.unlock()
    }
}

private func highlightedSnippet(
    _ snippet: String,
    terms: [String],
    size: CGFloat,
    weight: Font.Weight,
    base: Color
) -> AttributedString {
    var attributed = AttributedString(snippet)
    attributed.foregroundColor = base
    attributed.font = .system(size: size, weight: weight)
    let sorted = terms.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
    for term in sorted {
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let found = snippet.range(of: term, options: .caseInsensitive, range: cursor..<snippet.endIndex) {
            if let attrRange = Range(found, in: attributed) {
                attributed[attrRange].backgroundColor = Color.primary.opacity(0.10)
                attributed[attrRange].foregroundColor = .primary
                attributed[attrRange].font = .system(size: size, weight: .semibold)
            }
            cursor = found.upperBound
        }
    }
    return attributed
}
