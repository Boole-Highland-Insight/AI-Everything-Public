import CoreServices
import Foundation

/// macOS 上对应 Linux inotify 的是 FSEvents：一次盯整棵目录树，不必给每个子目录加 watch。
final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "aie.fsevents", qos: .utility)
    private var debounce: DispatchWorkItem?
    private var roots: [URL]
    var onChange: (() -> Void)?

    init(roots: [URL]) {
        self.roots = roots
    }

    func start() {
        stop()
        let paths = roots.map(\.path)
        guard !paths.isEmpty else { return }
        let cfPaths = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                Unmanaged<LibraryWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .handle(count: Int(count), paths: paths, flags: flags)
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func handle(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var interesting = false
        for i in 0..<count {
            let path = arr[i] as? String ?? ""
            let flag = flags[i]
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                interesting = true
                break
            }
            if shouldIgnore(path) { continue }
            // 创建 / 改名 / 写入都算：Finder 丢进来的新文件走这条，不靠 inotify。
            interesting = true
            break
        }
        guard interesting else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func shouldIgnore(_ path: String) -> Bool {
        if path.contains("/scanner/") { return true }
        if path.contains("/.git/") { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasPrefix(".") { return true }
        if name.hasPrefix("vision-probe-report") { return true }
        return false
    }
}
