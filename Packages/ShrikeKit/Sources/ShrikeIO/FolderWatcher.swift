//
//  FolderWatcher.swift
//  ShrikeIO
//
//  Watches ONE directory (non-recursive) with FSEvents and publishes
//  debounced, coalesced changes as an `AsyncStream<FolderChange>`.
//  Files added, removed or
//  renamed by Finder / a camera import / another app now reach the UI.
//
//  Design notes
//  ------------
//  * FSEvents is always recursive. We filter to direct children of the
//    watched folder; anything deeper is ignored. Hidden names (leading ".")
//    are treated as "outside" the folder unless `includeHiddenFiles` is set,
//    so `.DS_Store` churn never reaches the main actor.
//  * FSEvents flags are unreliable on their own: the kernel coalesces
//    history, so a file created and later modified can arrive with both
//    `ItemCreated` and `ItemModified`. We therefore keep a snapshot of the
//    child names we know about and classify each touched name by
//    "known before?" x "exists now?" — the flags are only used to pair
//    renames and to spot root changes / dropped events.
//  * Renames: FSEvents reports both halves as `ItemRenamed`. With
//    `UseExtendedData` each event carries the file ID (inode), so the two
//    halves are paired by inode. Unpaired halves become added / removed.
//    An atomic save (write temp file, rename over the original) arrives as
//    a rename onto an already-known name; that is reported as `modified`.
//  * Debounce: events accumulate on a private serial queue. A batch is
//    flushed after `debounce` of quiet, but never later than `maxLatency`
//    after its first event, so a 1,000-file copy lands as one (or a few)
//    `FolderChange` values instead of 1,000 main-actor hops.
//  * Root changes: `WatchRoot` tells us when the folder itself is deleted,
//    moved or renamed. We emit one final change with `folderEvent` set and
//    finish the stream. The consumer decides where to navigate.
//  * Dropped events (`MustScanSubDirs`, user/kernel dropped): we re-list
//    the directory and diff against the snapshot, so consumers never have
//    to handle a "rescan" special case.
//

import Foundation
import CoreServices
import Darwin

// MARK: - Public model

/// One debounced batch of changes in a watched folder. URLs are built from
/// the folder URL the watcher was created with (same form the caller used
/// for its own directory listing), not from the canonical `/private/...`
/// paths FSEvents reports.
public struct FolderChange: Sendable, Equatable {

    /// A rename that stayed inside the watched folder.
    public struct Rename: Sendable, Equatable, Hashable {
        public let from: URL
        public let to: URL
        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    /// What happened to the watched folder itself.
    public enum FolderEvent: Sendable, Equatable {
        /// The folder was deleted or moved to the Trash.
        case deleted
        /// The folder was renamed or moved. `to` is the new location.
        case moved(to: URL)
    }

    /// New children (created, copied in, moved in, or renamed from a
    /// hidden / outside name).
    public var added: [URL]
    /// Children that no longer exist (deleted, moved out, trashed).
    public var removed: [URL]
    /// Children renamed within the folder.
    public var renamed: [Rename]
    /// Children whose content or metadata changed — including our own
    /// saves (atomic replace) and Finder tag / xattr writes.
    public var modified: [URL]
    /// Set on the last change before the stream finishes, when the watched
    /// folder itself went away.
    public var folderEvent: FolderEvent?

    public init(
        added: [URL] = [],
        removed: [URL] = [],
        renamed: [Rename] = [],
        modified: [URL] = [],
        folderEvent: FolderEvent? = nil
    ) {
        self.added = added
        self.removed = removed
        self.renamed = renamed
        self.modified = modified
        self.folderEvent = folderEvent
    }

    /// True when the batch carries nothing.
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && renamed.isEmpty
            && modified.isEmpty && folderEvent == nil
    }
}

public enum FolderWatcherError: Error, Equatable, Sendable {
    /// The URL is not a file URL pointing at an existing directory.
    case notADirectory(URL)
    /// `FSEventStreamCreate` returned NULL.
    case streamCreationFailed
    /// `FSEventStreamStart` returned false.
    case streamStartFailed
}

// MARK: - FolderWatcher

/// Watches one directory and publishes debounced `FolderChange` batches.
///
/// ```swift
/// let watcher = try FolderWatcher(folder: url)
/// for await change in watcher.changes { ... }   // on any actor
/// ```
///
/// `changes` is a single-consumer stream. It finishes after `stop()`,
/// after the watcher is deinitialised, or after the folder itself is
/// deleted / moved (the final element then has `folderEvent` set).
/// Cancelling the consuming task also stops the watcher.
public final class FolderWatcher: Sendable {

    public struct Options: Sendable, Equatable {
        /// Quiet period before a batch is flushed.
        public var debounce: Duration
        /// Upper bound between a batch's first event and its flush, so a
        /// long-running copy still produces periodic updates.
        public var maxLatency: Duration
        /// FSEvents coalescing latency (passed to `FSEventStreamCreate`).
        public var fsEventsLatency: Duration
        /// Report names starting with "." (e.g. `.DS_Store`). Off by default.
        public var includeHiddenFiles: Bool

        public init(
            debounce: Duration = .milliseconds(200),
            maxLatency: Duration = .seconds(1),
            fsEventsLatency: Duration = .milliseconds(100),
            includeHiddenFiles: Bool = false
        ) {
            self.debounce = debounce
            self.maxLatency = maxLatency
            self.fsEventsLatency = fsEventsLatency
            self.includeHiddenFiles = includeHiddenFiles
        }
    }

    /// The folder being watched, exactly as passed to `init`.
    public let folder: URL
    /// Debounced change batches. Single consumer.
    public let changes: AsyncStream<FolderChange>

    private let core: FolderWatcherCore

    /// Starts watching immediately. Throws if `folder` is not an existing
    /// directory or FSEvents refuses the stream.
    public init(folder: URL, options: Options = Options()) throws {
        var isDirectory: ObjCBool = false
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw FolderWatcherError.notADirectory(folder) }

        let (stream, continuation) = AsyncStream<FolderChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        let core = FolderWatcherCore(folder: folder, options: options, continuation: continuation)
        try core.start()
        continuation.onTermination = { [weak core] _ in
            core?.requestStopAfterTermination()
        }
        self.folder = folder
        self.changes = stream
        self.core = core
        // So FileOps can suppress Shrike's own writes in every open watcher.
        FolderWatcherRegistry.shared.register(self)
    }

    /// Suppresses changes to these files for `duration`, so Shrike's own
    /// writes, renames and deletes do not come back as folder changes.
    /// Call it just before the file operation. Only the
    /// file name is matched, and only for files directly in `folder`;
    /// other URLs are skipped. Safe from any thread.
    public func ignore(paths: [URL], for duration: Duration = .seconds(1)) {
        core.ignore(paths: paths, for: duration)
    }

    /// Stops watching and finishes `changes`. Idempotent; safe from any
    /// thread.
    public func stop() {
        core.stop()
    }

    /// Whether the underlying FSEvents stream is still running.
    public var isRunning: Bool {
        core.isRunning
    }

    #if DEBUG
    /// Test-only access to the real queue and registered termination callback.
    /// Allows a bounded lock-order regression without blocking an XCTest task.
    func enqueueOnQueueForTesting(_ body: @escaping @Sendable () -> Void) {
        core.enqueueOnQueueForTesting(body)
    }

    func invokeTerminationForTesting() {
        core.invokeTerminationForTesting()
    }
    #endif

    deinit {
        core.stop()
    }
}

// MARK: - Core (queue-confined)

/// All mutable state — including the `FSEventStreamRef` — is read and
/// written only on `queue` (FSEvents delivers callbacks there; `start()` /
/// `stop()` hop onto it), which is what makes the unchecked conformance
/// sound.
private final class FolderWatcherCore: @unchecked Sendable {

    private struct RawEvent {
        let path: String
        let flags: FSEventStreamEventFlags
        let fileID: UInt64?
    }

    private let folder: URL
    private let options: Options
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    /// Canonical (symlink-resolved) path FSEvents reports, e.g.
    /// `/private/var/folders/...` for `/var/folders/...`.
    private let canonicalRoot: String

    typealias Options = FolderWatcher.Options

    // Queue-confined state.
    private var stream: FSEventStreamRef?
    private var known: Set<String> = []
    private var pending: [RawEvent] = []
    /// Lowercased child name -> end of its ignore window.
    private var ignoredUntil: [String: DispatchTime] = [:]
    /// Names in `pending` that arrived inside an ignore window.
    private var suppressedInBatch: Set<String> = []
    private var firstPendingAt: DispatchTime?
    private var lastPendingAt: DispatchTime?
    private var flushScheduled = false
    private var finished = false
    private var rootFD: Int32 = -1
    private var rootIdentity: (dev: dev_t, ino: ino_t)?

    init(folder: URL, options: Options, continuation: AsyncStream<FolderChange>.Continuation) {
        self.folder = folder
        self.options = options
        self.continuation = continuation
        self.queue = DispatchQueue(label: "app.shrike.FolderWatcher", qos: .utility)
        self.canonicalRoot = Self.canonicalPath(folder.path)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        // `stop()` normally ran already (the stream retains us until then).
        if rootFD >= 0 { close(rootFD) }
    }

    var isRunning: Bool {
        onQueue { stream != nil }
    }

    func start() throws {
        try onQueue { try startOnQueue() }
    }

    func stop() {
        onQueue { stopOnQueue() }
    }

    /// AsyncStream may invoke termination while cancellation holds a Swift
    /// task-status lock. A concurrent yield on our queue can need that lock,
    /// so this callback must never synchronously join the queue. Enqueue even
    /// when already on it to avoid reentering finish(); retain the core until
    /// its idempotent teardown has run. Explicit stop()/deinit still drain.
    func requestStopAfterTermination() {
        queue.async { [self] in stopOnQueue() }
    }

    #if DEBUG
    func enqueueOnQueueForTesting(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    func invokeTerminationForTesting() {
        continuation.onTermination?(.cancelled)
    }
    #endif

    // MARK: Queue helpers

    func ignore(paths: [URL], for duration: Duration) {
        let names = paths.compactMap { url -> String? in
            let parent = Self.canonicalPath(url.deletingLastPathComponent().path)
            guard parent.caseInsensitiveCompare(canonicalRoot) == .orderedSame else { return nil }
            return url.lastPathComponent.lowercased()
        }
        guard !names.isEmpty else { return }
        let until = DispatchTime.now() + Self.seconds(duration)
        onQueue {
            for name in names { ignoredUntil[name] = until }
        }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    // MARK: Start / stop

    private func startOnQueue() throws {
        guard stream == nil, !finished else { return }

        known = listChildren()
        rootFD = open(canonicalRoot, O_EVTONLY)
        var st = stat()
        if rootFD >= 0, fstat(rootFD, &st) == 0 {
            rootIdentity = (st.st_dev, st.st_ino)
        }

        // The stream retains `self` via the context callbacks; `stop()`
        // releases the stream and thereby us.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FolderWatcherCore>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatcherCore>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagUseExtendedData
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            [canonicalRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.seconds(options.fsEventsLatency),
            flags
        ) else {
            throw FolderWatcherError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            throw FolderWatcherError.streamStartFailed
        }
        stream = newStream
    }

    private func stopOnQueue() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)   // releases our context retain
            self.stream = nil
        }
        pending.removeAll()
        if !finished {
            finished = true
            continuation.finish()
        }
    }

    // MARK: Ingest (called on `queue` by the FSEvents callback)

    fileprivate func ingest(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard stream != nil, !finished else { return }
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        let now = DispatchTime.now()
        for index in 0..<count {
            guard index < array.count else { break }
            let path: String
            var fileID: UInt64?
            if let dict = array[index] as? NSDictionary {
                guard let p = dict[kFSEventStreamEventExtendedDataPathKey as String] as? String
                else { continue }
                path = p
                fileID = (dict[kFSEventStreamEventExtendedFileIDKey as String] as? NSNumber)?.uint64Value
            } else if let p = array[index] as? String {
                path = p
            } else {
                continue
            }
            pending.append(RawEvent(path: path, flags: flags[index], fileID: fileID))
            if !ignoredUntil.isEmpty, let name = childName(of: path)?.lowercased(),
               let until = ignoredUntil[name], now < until {
                suppressedInBatch.insert(name)
            }
        }
        if firstPendingAt == nil { firstPendingAt = now }
        lastPendingAt = now
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.seconds(options.debounce)) { [weak self] in
            self?.flushIfQuiet()
        }
    }

    private func flushIfQuiet() {
        flushScheduled = false
        guard !finished, let first = firstPendingAt, let last = lastPendingAt else { return }
        let now = DispatchTime.now()
        let quietFor = Self.seconds(between: last, and: now)
        let age = Self.seconds(between: first, and: now)
        let debounce = Self.seconds(options.debounce)
        let maxLatency = Self.seconds(options.maxLatency)
        if quietFor + 0.001 < debounce && age + 0.001 < maxLatency {
            // Still busy: wait for the remaining quiet time, capped by the
            // max-latency deadline.
            let wait = min(debounce - quietFor, maxLatency - age)
            flushScheduled = true
            queue.asyncAfter(deadline: now + max(wait, 0.005)) { [weak self] in
                self?.flushIfQuiet()
            }
            return
        }
        flush()
    }

    // MARK: Classification

    private func flush() {
        let events = pending
        pending.removeAll(keepingCapacity: true)
        firstPendingAt = nil
        lastPendingAt = nil
        let suppressed = suppressedInBatch
        suppressedInBatch.removeAll()
        if !ignoredUntil.isEmpty {
            let now = DispatchTime.now()
            ignoredUntil = ignoredUntil.filter { $0.value > now }
        }
        guard !events.isEmpty else { return }

        var change = FolderChange()

        // 1. Root changed (deleted / moved / renamed / ancestor changed)?
        if events.contains(where: { $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }),
           let folderEvent = checkRoot() {
            change.folderEvent = folderEvent
            change.removed = known.sorted().map { folder.appendingPathComponent($0) }
            known.removeAll()
            continuation.yield(change)
            stopOnQueue()
            return
        }

        // 2. Dropped events → full diff against the snapshot. Names
        //    settled here are skipped by the per-event passes below.
        var reported = Set<String>()
        if events.contains(where: needsRescan) {
            let now = listChildren()
            let added = now.subtracting(known)
            let removed = known.subtracting(now)
            change.added = added.sorted().map { folder.appendingPathComponent($0) }
            change.removed = removed.sorted().map { folder.appendingPathComponent($0) }
            reported.formUnion(added)
            reported.formUnion(removed)
            known = now
        }

        // 3. Pair renames by file ID. Each pair consumes both halves.
        let renamedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        var renameHalves: [UInt64: [Int]] = [:]
        for (i, event) in events.enumerated()
        where event.flags & renamedFlag != 0 && event.fileID != nil {
            renameHalves[event.fileID!, default: []].append(i)
        }
        var consumed = Set<Int>()
        var addedNames: [String] = []
        var removedNames: [String] = []
        var modifiedNames: [String] = []
        var renames: [(String, String)] = []

        // Deterministic order: by first appearance.
        let pairs = renameHalves.values
            .filter { indices in Set(indices.map { events[$0].path }).count >= 2 }
            .sorted { $0[0] < $1[0] }
        for indices in pairs {
            let fromPath = events[indices.first!].path
            // Last half that differs from the source path is the destination.
            guard let toIndex = indices.last(where: { events[$0].path != fromPath }) else { continue }
            let toPath = events[toIndex].path
            // A rename chain inside one batch (a→b→c) collapses to a→c.
            // If the "from" still exists and the "to" doesn't, the order
            // was reversed (b→a); swap.
            var from = fromPath
            var to = toPath
            if lstatExists(from) && !lstatExists(to) { swap(&from, &to) }
            indices.forEach { consumed.insert($0) }

            let fromName = childName(of: from)
            let toName = childName(of: to)
            switch (fromName, toName) {
            case let (f?, t?):
                let fromKnown = known.contains(f)
                let toKnown = known.contains(t)
                let toExists = lstatExists(to)
                if toKnown {
                    // Atomic replace onto an existing name (our own saves).
                    if toExists { modifiedNames.append(t) } else { removedNames.append(t); known.remove(t) }
                    if fromKnown && f != t { removedNames.append(f); known.remove(f) }
                } else if !fromKnown {
                    // Temp file created and renamed within this batch.
                    if toExists { addedNames.append(t); known.insert(t) }
                } else if toExists {
                    renames.append((f, t))
                    known.remove(f)
                    known.insert(t)
                } else {
                    // Renamed and then deleted before we looked.
                    removedNames.append(f)
                    known.remove(f)
                }
            case let (f?, nil):
                // Moved out of the folder (or to a hidden / nested name).
                if known.contains(f) { removedNames.append(f); known.remove(f) }
            case let (nil, t?):
                // Moved in from elsewhere.
                if lstatExists(to) {
                    if known.contains(t) { modifiedNames.append(t) } else { addedNames.append(t); known.insert(t) }
                }
            case (nil, nil):
                break
            }
        }

        // 4. Everything else: dedupe by name, classify by known x exists.
        var seen = Set<String>()
        var ordered: [String] = []
        for (i, event) in events.enumerated() where !consumed.contains(i) {
            guard let name = childName(of: event.path) else { continue }
            if seen.insert(name).inserted { ordered.append(name) }
        }
        reported.formUnion(addedNames)
        reported.formUnion(removedNames)
        reported.formUnion(modifiedNames)
        reported.formUnion(renames.map(\.0))
        reported.formUnion(renames.map(\.1))
        for name in ordered where !reported.contains(name) {
            let exists = lstatExists(canonicalRoot + "/" + name)
            let wasKnown = known.contains(name)
            switch (wasKnown, exists) {
            case (true, true):   modifiedNames.append(name)
            case (true, false):  removedNames.append(name); known.remove(name)
            case (false, true):  addedNames.append(name); known.insert(name)
            case (false, false): break   // created and deleted inside the window
            }
        }

        // Shrike's own operations (`ignore(paths:for:)`): `known` is already
        // up to date, only the report is dropped.
        if !suppressed.isEmpty {
            let isOwn: (String) -> Bool = { suppressed.contains($0.lowercased()) }
            addedNames.removeAll(where: isOwn)
            removedNames.removeAll(where: isOwn)
            modifiedNames.removeAll(where: isOwn)
            renames.removeAll { isOwn($0.0) || isOwn($0.1) }
        }

        change.added += addedNames.map { folder.appendingPathComponent($0) }
        change.removed += removedNames.map { folder.appendingPathComponent($0) }
        change.modified += modifiedNames.map { folder.appendingPathComponent($0) }
        change.renamed = renames.map {
            FolderChange.Rename(from: folder.appendingPathComponent($0.0), to: folder.appendingPathComponent($0.1))
        }
        if !change.isEmpty {
            continuation.yield(change)
        }
    }

    /// Returns the folder event if the watched folder is really gone or
    /// moved; nil when the root is still where it was (an ancestor
    /// changed and changed back, or a spurious flag).
    private func checkRoot() -> FolderChange.FolderEvent? {
        var st = stat()
        if lstat(canonicalRoot, &st) == 0, let identity = rootIdentity,
           st.st_dev == identity.dev, st.st_ino == identity.ino {
            return nil
        }
        guard rootFD >= 0 else { return .deleted }
        // Where does our open descriptor point now?
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var fdStat = stat()
        guard fcntl(rootFD, F_GETPATH, &buffer) != -1,
              fstat(rootFD, &fdStat) == 0, fdStat.st_nlink > 0
        else { return .deleted }
        let newPath = String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        if newPath.contains("/.Trash/") || newPath.hasSuffix("/.Trash") || newPath == canonicalRoot {
            return .deleted
        }
        guard lstatExists(newPath) else { return .deleted }
        return .moved(to: URL(fileURLWithPath: newPath, isDirectory: true))
    }

    // MARK: Path helpers

    /// Name of a direct, visible child of the watched folder, else nil.
    private func childName(of path: String) -> String? {
        guard path.count > canonicalRoot.count + 1 else { return nil }
        let prefixEnd = path.index(path.startIndex, offsetBy: canonicalRoot.count)
        guard path[path.startIndex..<prefixEnd].caseInsensitiveCompare(canonicalRoot) == .orderedSame,
              path[prefixEnd] == "/"
        else { return nil }
        let name = path[path.index(after: prefixEnd)...]
        guard !name.isEmpty, !name.contains("/") else { return nil }
        if !options.includeHiddenFiles && name.hasPrefix(".") { return nil }
        return String(name)
    }

    /// Dropped events always force a re-list; `MustScanSubDirs` only when
    /// it names the watched folder or one of its ancestors (a deeper
    /// subfolder cannot change our direct children).
    private func needsRescan(_ event: RawEvent) -> Bool {
        let dropped = FSEventStreamEventFlags(
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        )
        if event.flags & dropped != 0 { return true }
        guard event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
        else { return false }
        let path = event.path.hasSuffix("/") ? String(event.path.dropLast()) : event.path
        if path.caseInsensitiveCompare(canonicalRoot) == .orderedSame { return true }
        return canonicalRoot.lowercased().hasPrefix(path.lowercased() + "/")
    }

    private func listChildren() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: canonicalRoot) else {
            return []
        }
        if options.includeHiddenFiles { return Set(names) }
        return Set(names.lazy.filter { !$0.hasPrefix(".") })
    }

    private func lstatExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (secs, attos) = duration.components
        return Double(secs) + Double(attos) / 1e18
    }

    private static func seconds(between start: DispatchTime, and end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1e9
    }
}

// MARK: - C callback

/// FSEvents C callback. Runs on the core's serial queue (set via
/// `FSEventStreamSetDispatchQueue`), so calling into the queue-confined
/// core is safe.
private func folderWatcherCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let core = Unmanaged<FolderWatcherCore>.fromOpaque(info).takeUnretainedValue()
    core.ingest(count: count, paths: paths, flags: flags)
}
