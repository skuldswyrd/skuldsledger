import Foundation
import CoreServices

/// Watches Records/<date>/inbox/ for TradingView screenshots (cmd+s drops).
///
/// FSEvents stream scheduled on a private serial queue. Every event — plus
/// `start()` and `rescan()` — triggers a full non-recursive scan of the
/// directory; files never reported before are handed to `onNewFiles` on the
/// main queue, oldest first.
///
/// Memory contract:
/// - The FSEventStream context carries `Unmanaged<InboxWatcher>` with real
///   retain/release callbacks, so the stream keeps the watcher alive for the
///   stream's whole lifetime. No dangling `info` pointer is possible: while
///   the stream can still fire, the watcher cannot have been deallocated.
/// - The resulting stream -> watcher retain is broken by `stop()`, which
///   stops, invalidates and releases the stream *on the event queue* — that
///   serializes teardown behind any in-flight callback, so after `stop()`
///   returns no callback is running or will ever run again.
/// - Consequence: `deinit` can only execute after `stop()` already released
///   the stream (or if the stream never started), so its cleanup branch is a
///   defensive no-op in practice.
final class InboxWatcher {

    private let directory: URL
    private let onNewFiles: ([URL]) -> Void

    /// Serial queue: FSEvents callbacks, scans and `seen` mutations all run here.
    private let queue = DispatchQueue(label: "skuldjournal.inboxwatcher", qos: .utility)

    /// Paths already reported through `onNewFiles`. Queue-confined.
    private var seen: Set<String> = []

    /// Live stream, nil when not started. Mutated only inside `queue`
    /// (start/stop hop onto it), read in deinit when no stream can be live.
    private var streamRef: FSEventStreamRef?

    init(directory: URL, onNewFiles: @escaping ([URL]) -> Void) {
        self.directory = directory
        self.onNewFiles = onNewFiles
    }

    deinit {
        // Unreachable while the stream is alive (it retains self via the
        // context retain callback); kept as a safety net for a stream that
        // was created but failed to start, or future refactors.
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    // MARK: - Public API

    /// Idempotent: a second call while running just triggers a rescan.
    func start() {
        // TradingView may not have saved anything yet on day one — the inbox
        // folder must exist before FSEvents can watch it.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        queue.sync {
            guard streamRef == nil else { return }
            createAndStartStreamOnQueue()
        }
        rescan()
    }

    /// Safe to call multiple times / when never started.
    func stop() {
        queue.sync {
            guard let stream = streamRef else { return }
            streamRef = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Drops the stream's retain on self via the context release callback.
            FSEventStreamRelease(stream)
        }
    }

    /// Manual "Rescan Inbox" — also the recovery path if an event was missed.
    func rescan() {
        queue.async { [weak self] in
            self?.scanAndReport()
        }
    }

    // MARK: - Stream

    /// Must run on `queue`.
    private func createAndStartStreamOnQueue() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<InboxWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<InboxWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            inboxWatcherEventCallback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // seconds of coalescing latency — screenshots are not bursty
            flags)
        else {
            NSLog("InboxWatcher: FSEventStreamCreate failed for \(directory.path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            NSLog("InboxWatcher: FSEventStreamStart failed for \(directory.path)")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream) // releases the context retain from create
            return
        }
        streamRef = stream
    }

    // MARK: - Scanning

    /// Must run on `queue`. Full directory diff against `seen`; the event's
    /// own paths are ignored on purpose — rescanning is cheaper than trusting
    /// coalesced/MustScanSubDirs flag semantics for a tiny folder.
    fileprivate func scanAndReport() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey, .isRegularFileKey]

        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return } // directory vanished mid-session — next event rescans

        // Entry submission moves files out of inbox/ into assets/; forget them
        // so `seen` tracks only what is really still sitting in the inbox.
        seen.formIntersection(Set(items.map(\.path)))

        let allowedExtensions: Set<String> = ["png", "jpg", "jpeg"]
        var candidates: [(url: URL, created: Date)] = []

        for url in items {
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile ?? false else { continue }
            // TradingView cmd+s may still be mid-write; a follow-up FSEvent
            // (or manual rescan) picks the file up once it has real content.
            guard (values.fileSize ?? 0) >= 1024 else { continue }
            candidates.append((url, values.creationDate ?? .distantPast))
        }

        let fresh = candidates
            .filter { !seen.contains($0.url.path) }
            .sorted {
                $0.created != $1.created
                    ? $0.created < $1.created
                    : $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            .map(\.url)

        guard !fresh.isEmpty else { return }
        for url in fresh { seen.insert(url.path) }

        let callback = onNewFiles
        DispatchQueue.main.async { callback(fresh) }
    }
}

/// C-convention FSEvents trampoline (capture-less closure). The `info`
/// pointer is guaranteed valid here: the stream retains the watcher, so a
/// firing callback implies a live object. Runs on the watcher's serial queue.
private let inboxWatcherEventCallback: FSEventStreamCallback = {
    _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<InboxWatcher>.fromOpaque(info).takeUnretainedValue().scanAndReport()
}
