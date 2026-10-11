//
//  ThumbnailCache.swift
//  ShrikeCore
//
//  Two-tier thumbnail cache
//  - Memory tier: `ThumbnailMemoryLRU`, least-recently-used, bounded by
//    bytes; readable synchronously from any thread (`cachedThumbnail`).
//  - Disk tier: HEIC at
//    `~/Library/Caches/app.shrike/thumbs/XX/XXXXXX_<size>.heic`
//    where `XX` is the first two hex chars of the content hash. Written
//    after the thumbnail is returned, off the decode slots, atomically.
//  - Content hash: `SHA256(path || mtime bits || fileSize bits)`.
//  - Disk eviction: periodic task every 60 s, delete by
//    `contentModificationDate` until under ceiling. 30 s cooldown.
//  - Fallback: `QLThumbnailGenerator` when the source throws `.unsupported`.
//  - One job per key; concurrent callers share it. Decode slots are sized
//    to the machine and served by priority (visible > nearby > prefetch).
//    Queued jobs nobody waits for any more are dropped before decoding.
//

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Stats

public struct ThumbStats: Sendable {
    public let memoryHits: Int
    public let diskHits: Int
    public let misses: Int
    public let diskBytesUsed: Int64

    public init(memoryHits: Int, diskHits: Int, misses: Int, diskBytesUsed: Int64) {
        self.memoryHits = memoryHits
        self.diskHits = diskHits
        self.misses = misses
        self.diskBytesUsed = diskBytesUsed
    }
}

// MARK: - Priority

/// Which thumbnails decode first when every decode slot is busy.
public enum ThumbnailPriority: Int, Sendable, Comparable, CaseIterable {
    /// Speculative work (rows about to scroll in, prefetch).
    case prefetch = 0
    /// Near the user's focus but not on screen (filmstrip neighbours).
    case nearby = 1
    /// On screen now (visible grid cells, the viewer's bridge image).
    case visible = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var taskPriority: TaskPriority {
        switch self {
        case .visible: return .userInitiated
        case .nearby: return .medium
        case .prefetch: return .utility
        }
    }
}

// MARK: - Errors

public enum ThumbnailCacheError: Error, Sendable {
    case sourceUnavailable
    case destinationFailed
    case diskWriteFailed
}

// MARK: - Actor

public actor ThumbnailCache {

    /// Default memory budget. Bounded by bytes, not count: each cached
    /// CGImage can pin IOSurfaces downstream and the system pool is finite
    /// (`e00002c2` / kIOReturnNoResources under filmstrip scrubbing).
    public static let defaultMemoryByteLimit = 128 * 1024 * 1024

    /// Decode slots sized to the machine. On macOS 15+ decodes run on
    /// their own queue (`ThumbnailDecodeExecutor`), so they may use every
    /// active core, capped at 8 (ImageIO stops scaling and its helper's
    /// IOSurface pool is finite). On macOS 14 they block the cooperative
    /// pool, so one core stays free for the rest of the app.
    public static var defaultMaxConcurrentDecodes: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if #available(macOS 15.0, *) { return max(2, min(cores, 8)) }
        return max(2, min(cores - 1, 6))
    }

    // Tiers
    private nonisolated let memory: ThumbnailMemoryLRU
    private nonisolated let disk: ThumbnailDiskStore
    private nonisolated let diskRoot: URL
    private var diskCeilingBytes: Int64

    // Stats — incremented on every request. `statistics()` snapshots.
    private var memoryHits: Int = 0
    private var diskHits: Int = 0
    private var misses: Int = 0

    // One job per cache key: callers for the same key share it.
    private final class Job {
        let id = UUID()
        let key: String
        var priority: ThumbnailPriority
        /// Callers currently awaiting the result.
        var interest = 0
        /// Created by `prefetch`: kept even with no caller waiting.
        var pinned = false
        /// Past the slot queue (decoding or reading disk): can't be dropped.
        var started = false
        /// The file was evicted while this job ran: hand the image to the
        /// callers but don't cache it (it shows the old file).
        var discardResult = false
        var task: Task<CGImage, any Error>?
        init(key: String, priority: ThumbnailPriority) {
            self.key = key
            self.priority = priority
        }
    }
    private var jobs: [String: Job] = [:]

    // MARK: - Decode slots
    //
    // ImageIO decodes are capped (`maxConcurrentDecodes`): past a point the
    // IOSurface pool and ImageIO's helper overflow (`Unable to obtain a
    // task name port right`, `IOSurface creation failed: e00002c2`).
    // Waiters are served by priority (visible > nearby > prefetch), FIFO
    // within a lane. A waiter whose job is cancelled is resumed with
    // `false` and never decodes.
    private struct Waiter {
        let key: String
        let jobID: UUID
        var priority: ThumbnailPriority
        let seq: UInt64
        let cont: CheckedContinuation<Bool, Never>
    }
    private let maxConcurrentDecodes: Int
    private var activeDecodes: Int = 0
    private var decodeWaiters: [Waiter] = []
    private var waiterSeq: UInt64 = 0

    // Eviction state
    private var lastEviction: Date = .distantPast
    private var evictionTicker: Task<Void, Never>?
    private var writesAtLastTrim = -1   // -1: the first tick always walks once
    private var trimRunning = false

    // MARK: Init

    /// - Parameters:
    ///   - maxConcurrentDecodes: nil = `defaultMaxConcurrentDecodes`.
    ///   - memoryByteLimit: memory-tier budget (LRU by bytes).
    public init(
        diskURL: URL,
        diskCeilingBytes: Int64 = 512 * 1024 * 1024,
        maxConcurrentDecodes: Int? = nil,
        memoryByteLimit: Int = ThumbnailCache.defaultMemoryByteLimit
    ) throws {
        self.diskRoot = diskURL
        self.diskCeilingBytes = diskCeilingBytes
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes ?? Self.defaultMaxConcurrentDecodes)
        self.memory = ThumbnailMemoryLRU(byteLimit: memoryByteLimit, countLimit: 1024)
        self.disk = ThumbnailDiskStore(root: diskURL)
        try FileManager.default.createDirectory(
            at: diskURL, withIntermediateDirectories: true
        )
        self.evictionTicker = nil
        // Start the eviction ticker asynchronously since `init` can't
        // call actor-isolated methods synchronously under Swift 6.
        Task { [weak self] in
            await self?.startEvictionTicker()
        }
    }

    // MARK: - Decode slot semaphore

    /// Queues for a slot (caller checked none is free). Returns false when
    /// the job was cancelled while waiting (the slot was not taken).
    private func acquireDecodeSlot(key: String, jobID: UUID, priority: ThumbnailPriority) async -> Bool {
        waiterSeq &+= 1
        let seq = waiterSeq
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            decodeWaiters.append(Waiter(key: key, jobID: jobID, priority: priority, seq: seq, cont: cont))
        }
        // `true`: `releaseDecodeSlot()` handed its slot over (activeDecodes unchanged).
    }

    /// Hands the slot to the best waiter (highest priority, oldest), else
    /// frees it.
    private func releaseDecodeSlot() {
        guard let index = bestWaiterIndex() else {
            activeDecodes -= 1
            return
        }
        let next = decodeWaiters.remove(at: index)
        jobs[next.key]?.started = true
        next.cont.resume(returning: true)
    }

    private func bestWaiterIndex() -> Int? {
        guard !decodeWaiters.isEmpty else { return nil }
        var best = 0
        for i in decodeWaiters.indices.dropFirst() {
            let w = decodeWaiters[i], b = decodeWaiters[best]
            if w.priority > b.priority || (w.priority == b.priority && w.seq < b.seq) { best = i }
        }
        return best
    }

    /// Test seam — observe current decode-slot occupancy.
    internal func activeDecodeSlotsForTesting() -> Int { activeDecodes }
    internal func decodeWaiterCountForTesting() -> Int { decodeWaiters.count }
    internal var maxConcurrentDecodesForTesting: Int { maxConcurrentDecodes }
    internal func jobCountForTesting() -> Int { jobs.count }

    // MARK: - Public API

    /// The thumbnail for `source`, from memory, disk or a fresh decode.
    ///
    /// Cancelling the calling task drops the queued decode when no other
    /// caller (and no `prefetch`) still wants it; the caller then gets
    /// `CancellationError`. Once the decode has started it finishes and
    /// lands in the cache.
    public func thumbnail(
        for source: any ImageSource,
        maxPixelSize: Int,
        priority: ThumbnailPriority = .visible
    ) async throws -> CGImage {
        let key = Self.cacheKey(for: source, maxPixelSize: maxPixelSize)
        let state = ShrikeSignposts.thumbnail.begin("thumbnail", "size=\(maxPixelSize)")

        if let hit = memory.get(key) {
            memoryHits += 1
            ShrikeSignposts.thumbnail.end("thumbnail", state, "hit=memory,size=\(maxPixelSize)")
            return hit
        }
        try Task.checkCancellation()

        let job = jobs[key] ?? startJob(key: key, source: source, maxPixelSize: maxPixelSize,
                                         priority: priority)
        raise(job, to: priority)
        job.interest += 1
        // A caller now waits for this job and owns it: if that caller goes
        // away (the cell scrolled off) the queued decode is dropped, even
        // when a prefetch had pinned it earlier.
        job.pinned = false
        let jobID = job.id
        guard let task = job.task else { throw CancellationError() }
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.loseInterest(key: key, jobID: jobID) }
            }
            if let current = jobs[key], current.id == jobID { current.interest -= 1 }
            ShrikeSignposts.thumbnail.end("thumbnail", state, "done,size=\(maxPixelSize)")
            return image
        } catch {
            if let current = jobs[key], current.id == jobID { current.interest -= 1 }
            ShrikeSignposts.thumbnail.end("thumbnail", state, "error,size=\(maxPixelSize)")
            throw error
        }
    }

    /// Synchronous memory-tier lookup, safe from any thread (the grid calls
    /// it on main when a cell is reused, so a cached thumbnail shows in the
    /// same frame). No disk access, no decode.
    public nonisolated func cachedThumbnail(for source: any ImageSource, maxPixelSize: Int) -> CGImage? {
        memory.get(Self.cacheKey(for: source, maxPixelSize: maxPixelSize))
    }

    /// Queues thumbnails at `priority` (default `.prefetch`) without
    /// waiting. They stay queued until decoded or cancelled with
    /// `cancel(for:maxPixelSize:)` / `cancelQueued(atOrBelow:)`.
    public func prefetch(_ sources: [any ImageSource], maxPixelSize: Int,
                         priority: ThumbnailPriority = .prefetch) {
        for source in sources {
            let key = Self.cacheKey(for: source, maxPixelSize: maxPixelSize)
            if memory.get(key) != nil { continue }
            let job = jobs[key] ?? startJob(key: key, source: source, maxPixelSize: maxPixelSize,
                                            priority: priority)
            job.pinned = true
            raise(job, to: priority)
        }
    }

    /// Drops the queued decode for this thumbnail (a cell scrolled away).
    /// Waiting callers get `CancellationError`. No effect once the decode
    /// has started or when nothing is queued.
    public func cancel(for source: any ImageSource, maxPixelSize: Int) {
        drop(key: Self.cacheKey(for: source, maxPixelSize: maxPixelSize))
    }

    /// Withdraws a prefetch request (the row left the prefetch window).
    /// The queued decode is dropped unless someone is waiting for it; one
    /// that already started finishes and is cached. No effect on a
    /// thumbnail that is already in memory.
    public func cancelPrefetch(_ sources: [any ImageSource], maxPixelSize: Int) {
        for source in sources {
            let key = Self.cacheKey(for: source, maxPixelSize: maxPixelSize)
            guard let job = jobs[key] else { continue }
            job.pinned = false
            if job.interest <= 0 { drop(key: key) }
        }
    }

    /// Drops every queued (not started) decode at `priority` or lower, e.g.
    /// `.prefetch` when a fast scroll makes the prefetched rows stale.
    public func cancelQueued(atOrBelow priority: ThumbnailPriority) {
        for waiter in decodeWaiters where waiter.priority <= priority { drop(key: waiter.key) }
    }

    /// Moves a queued thumbnail to another lane (a prefetched cell became
    /// visible, or a visible one left the screen but may come back).
    public func setPriority(_ priority: ThumbnailPriority, for source: any ImageSource, maxPixelSize: Int) {
        let key = Self.cacheKey(for: source, maxPixelSize: maxPixelSize)
        guard let job = jobs[key] else { return }
        job.priority = priority
        if let i = decodeWaiters.firstIndex(where: { $0.jobID == job.id }) {
            decodeWaiters[i].priority = priority
        }
    }

    /// Waits until every HEIC write queued so far is on disk (tests, and
    /// before "Reveal cache in Finder").
    public func waitForPendingDiskWrites() async {
        await disk.waitUntilIdle()
    }

    // MARK: - Jobs

    private func startJob(key: String, source: any ImageSource, maxPixelSize: Int,
                          priority: ThumbnailPriority) -> Job {
        let job = Job(key: key, priority: priority)
        let jobID = job.id
        let diskFile = diskURL(for: key)
        let body: @Sendable () async throws -> CGImage = { [weak self] in
            try await Self.runJob(self, key: key, jobID: jobID, source: source,
                                  maxPixelSize: maxPixelSize, diskFile: diskFile)
        }
        if #available(macOS 15.0, *) {
            job.task = Task(executorPreference: ThumbnailDecodeExecutor.shared,
                            priority: priority.taskPriority, operation: body)
        } else {
            job.task = Task.detached(priority: priority.taskPriority, operation: body)
        }
        jobs[key] = job
        return job
    }

    /// The job body. Not actor-isolated: disk read and decode run on the
    /// decode executor; only bookkeeping hops to the actor.
    private static func runJob(
        _ cache: ThumbnailCache?, key: String, jobID: UUID, source: any ImageSource,
        maxPixelSize: Int, diskFile: URL
    ) async throws -> CGImage {
        guard let cache else { throw CancellationError() }
        // Disk tier first, outside the slots: a warm read is ~3 ms.
        if let fromDisk = ThumbnailDiskStore.read(at: diskFile) {
            await cache.finish(key: key, jobID: jobID, image: fromDisk, fromDisk: true, diskFile: diskFile)
            return fromDisk
        }
        guard await cache.acquireSlot(for: key, jobID: jobID) else {
            await cache.finishCancelled(key: key, jobID: jobID)
            throw CancellationError()
        }
        let decoded: Result<CGImage, any Error>
        do {
            do {
                decoded = .success(try await source.loadCGImage(maxPixelSize: maxPixelSize))
            } catch ImageSourceError.unsupported {
                // QuickLook handles odd formats, videos, PDFs.
                decoded = .success(try await quickLookThumbnail(for: sourceURL(source),
                                                                maxPixelSize: maxPixelSize))
            }
        } catch {
            decoded = .failure(error)
        }
        await cache.releaseDecodeSlot()
        switch decoded {
        case .success(let image):
            await cache.finish(key: key, jobID: jobID, image: image, fromDisk: false, diskFile: diskFile)
            return image
        case .failure(let error):
            await cache.finishCancelled(key: key, jobID: jobID)
            throw error
        }
    }

    private func acquireSlot(for key: String, jobID: UUID) async -> Bool {
        guard let job = jobs[key], job.id == jobID else { return false }
        if activeDecodes < maxConcurrentDecodes, decodeWaiters.isEmpty {
            job.started = true
            activeDecodes += 1
            return true
        }
        return await acquireDecodeSlot(key: key, jobID: jobID, priority: job.priority)
    }

    /// Result is in: memory tier now, disk tier later (after the caller has
    /// it, on the writer queue, never inside a decode slot).
    private func finish(key: String, jobID: UUID, image: CGImage, fromDisk: Bool, diskFile: URL) {
        if let job = jobs[key], job.id == jobID, job.discardResult {
            jobs[key] = nil
            return
        }
        memory.set(image, for: key)
        if fromDisk {
            diskHits += 1
        } else {
            misses += 1
            disk.enqueueWrite(image, to: diskFile)
        }
        if let job = jobs[key], job.id == jobID { jobs[key] = nil }
    }

    private func finishCancelled(key: String, jobID: UUID) {
        if let job = jobs[key], job.id == jobID { jobs[key] = nil }
    }

    private func raise(_ job: Job, to priority: ThumbnailPriority) {
        guard priority > job.priority else { return }
        job.priority = priority
        if let i = decodeWaiters.firstIndex(where: { $0.jobID == job.id }) {
            decodeWaiters[i].priority = priority
        }
    }

    private func loseInterest(key: String, jobID: UUID) {
        guard let job = jobs[key], job.id == jobID else { return }
        job.interest -= 1
        if job.interest <= 0, !job.pinned { drop(key: key) }
    }

    /// Removes a job that hasn't started: its waiter resumes with `false`,
    /// so the job throws `CancellationError` without decoding.
    private func drop(key: String) {
        guard let job = jobs[key], !job.started else { return }
        jobs[key] = nil
        if let i = decodeWaiters.firstIndex(where: { $0.jobID == job.id }) {
            decodeWaiters.remove(at: i).cont.resume(returning: false)
        }
        job.task?.cancel()
    }

    public func evictMemory() {
        memory.removeAll()
    }

    public func statistics() -> ThumbStats {
        ThumbStats(
            memoryHits: memoryHits,
            diskHits: diskHits,
            misses: misses,
            diskBytesUsed: diskBytesUsed()
        )
    }

    /// Sum of on-disk cache bytes under `diskRoot`. Walks the directory once
    /// via `FileManager.enumerator`. Intentionally uncached — callers are
    /// user-driven (Preferences tab open + after "Clear cache"), not hot.
    public func currentDiskBytes() -> Int64 {
        diskBytesUsed()
    }

    /// Directory the cache writes to. Exposed so the Preferences window can
    /// offer "Reveal in Finder" without duplicating the path-construction
    /// logic.
    public var diskDirectory: URL { diskRoot }

    /// Recursively delete every file under `diskRoot`, then re-create the
    /// empty root. Also wipes the in-memory tier so the next request rebuilds
    /// the thumbnail from scratch. "Clear cache" in Preferences calls this.
    public func clearAll() {
        memory.removeAll()
        disk.cancelPendingWrites()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: diskRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            try? fm.removeItem(at: url)
        }
        // Ensure the root still exists for the next write.
        try? fm.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    // MARK: - Keying

    /// Public for testability — returns the on-disk file path a given
    /// `(source, maxPixelSize)` pair would land at.
    public func diskFileURL(for source: any ImageSource, maxPixelSize: Int) async throws -> URL {
        diskURL(for: Self.cacheKey(for: source, maxPixelSize: maxPixelSize))
    }

    /// "<12 hex of SHA256(path)><12 hex of SHA256(path || mtime || size)>_<maxPixelSize>".
    /// The path hash comes first, so every size and every version of one
    /// file shares a prefix (and a shard folder): `evict(url:)` finds them
    /// without knowing the old mtime or size.
    static func cacheKey(for source: any ImageSource, maxPixelSize: Int) -> String {
        "\(keyStem(for: source))_\(maxPixelSize)"
    }

    /// The size-independent part of the key (24 hex chars). Remembered per
    /// (file, mtime, size) for the session: a lookup then costs a hash-map
    /// read instead of two `stat()` calls and two SHA-256 runs. A changed
    /// file has a new mtime or size, so it gets a new stem.
    static func keyStem(for source: any ImageSource) -> String {
        let memoKey = KeyStemMemo.Key(source: source)
        if let hit = KeyStemMemo.shared.get(memoKey) { return hit }
        let stem = "\(pathPrefix(for: source))\(contentHash(for: source).prefix(12))"
        KeyStemMemo.shared.set(stem, for: memoKey)
        return stem
    }

    /// First 12 hex chars of SHA256 of the file's standardized path (or of
    /// `source.id` for sources without a file).
    static func pathPrefix(for source: any ImageSource) -> String {
        if let file = source as? FileImageSource { return pathPrefix(forPath: file.url.standardizedFileURL.path) }
        return pathPrefix(forPath: source.id)
    }

    static func pathPrefix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return hex(digest.prefix(6))
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Per-file eviction and disk ceiling

    /// Drops every size of `url`'s thumbnail, every version, from memory
    /// and disk. Queued decodes for it are dropped; running ones still
    /// answer their callers but are not cached; pending HEIC writes for it
    /// are skipped. Call after delete, rename and save.
    public func evict(url: URL) async {
        let prefix = Self.pathPrefix(forPath: url.standardizedFileURL.path)
        memory.removeAll(keyPrefix: prefix)
        for (key, job) in jobs where key.hasPrefix(prefix) {
            if job.started { job.discardResult = true } else { drop(key: key) }
        }
        disk.cancelPendingWrites(namePrefix: prefix)
        let shard = diskRoot.appendingPathComponent(String(prefix.prefix(2)), isDirectory: true)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: shard.path) else { return }
            for name in names where name.hasPrefix(prefix) {
                try? fm.removeItem(at: shard.appendingPathComponent(name))
            }
        }.value
    }

    /// Sets the disk-tier ceiling. Takes effect at once: if the cache is
    /// over the new ceiling it is trimmed (oldest first) before returning.
    /// The trim walks the folder off this actor, so thumbnail requests
    /// keep being served meanwhile.
    public func setDiskCeiling(bytes: Int64) async {
        diskCeilingBytes = max(0, bytes)
        lastEviction = Date()
        let root = diskRoot, ceiling = diskCeilingBytes
        await Task.detached(priority: .utility) {
            Self.trimDisk(root: root, ceiling: ceiling)
        }.value
    }

    /// Current disk ceiling in bytes.
    public var diskCeiling: Int64 { diskCeilingBytes }

    internal static func contentHash(for source: any ImageSource) -> String {
        // Best-effort — sources without a URL-like identifier still get a
        // stable key via `source.id` fallback.
        var hasher = SHA256()

        // Path
        if let file = source as? FileImageSource {
            let path = file.url.standardizedFileURL.path
            hasher.update(data: Data(path.utf8))
        } else {
            hasher.update(data: Data(source.id.utf8))
        }

        // mtime
        var mtimeBits: UInt64 = 0
        if let mtime = source.mtime {
            mtimeBits = mtime.timeIntervalSince1970.bitPattern.bigEndian
        }
        withUnsafeBytes(of: mtimeBits) { hasher.update(bufferPointer: $0) }

        // fileSize
        var sizeBits: Int64 = source.fileSize ?? 0
        sizeBits = sizeBits.bigEndian
        withUnsafeBytes(of: sizeBits) { hasher.update(bufferPointer: $0) }

        return hex(hasher.finalize())
    }

    /// `<root>/<first 2 hex>/<key>.heic`. The shard folder is created by
    /// the writer, not here: lookups stay free of file-system calls.
    private nonisolated func diskURL(for key: String) -> URL {
        diskRoot
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).heic")
    }

    // MARK: - QuickLook fallback

    private static func sourceURL(_ source: any ImageSource) -> URL? {
        (source as? FileImageSource)?.url
    }

    private static func quickLookThumbnail(
        for url: URL?, maxPixelSize: Int
    ) async throws -> CGImage {
        guard let url else { throw ThumbnailCacheError.sourceUnavailable }
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1.0,
            representationTypes: .thumbnail
        )
        // `QLThumbnailRepresentation` is not `Sendable`; extract the
        // `CGImage` (which is) inside the callback.
        let cg: CGImage = try await withCheckedThrowingContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { r, e in
                if let e { cont.resume(throwing: e); return }
                guard let r else {
                    cont.resume(throwing: ThumbnailCacheError.sourceUnavailable); return
                }
                cont.resume(returning: r.cgImage)
            }
        }
        return cg
    }

    // MARK: - Eviction

    private func startEvictionTicker() {
        evictionTicker?.cancel()
        evictionTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                await self.runEvictionIfNeeded()
            }
        }
    }

    /// The 60 s ticker. Skips the folder walk when no thumbnail was written
    /// since the last one (nothing can have grown), and runs it off this
    /// actor, so requests are served while it walks.
    private func runEvictionIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastEviction) >= 30 else { return }
        lastEviction = now
        let written = disk.acceptedWrites
        guard written != writesAtLastTrim, !trimRunning else { return }
        writesAtLastTrim = written
        trimRunning = true
        let root = diskRoot, ceiling = diskCeilingBytes
        Task.detached(priority: .utility) { [weak self] in
            Self.trimDisk(root: root, ceiling: ceiling)
            await self?.trimFinished()
        }
    }

    private func trimFinished() { trimRunning = false }

    /// Exposed for tests.
    public func runEvictionNow() {
        lastEviction = Date()
        evictDiskIfOverCeiling()
    }

    private func evictDiskIfOverCeiling() {
        Self.trimDisk(root: diskRoot, ceiling: diskCeilingBytes)
    }

    /// Deletes the oldest files under `root` until it holds ≤ `ceiling`.
    private nonisolated static func trimDisk(root diskRoot: URL, ceiling diskCeilingBytes: Int64) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: diskRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ])
            guard vals?.isRegularFile == true else { continue }
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? .distantPast
            entries.append((url, size, mtime))
            total += size
        }

        guard total > diskCeilingBytes else { return }

        // Oldest first.
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= diskCeilingBytes { break }
            do {
                try fm.removeItem(at: entry.url)
                total -= entry.size
            } catch {
                // Best effort — leave the file in place if removal fails.
            }
        }
    }

    private func diskBytesUsed() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: diskRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            total += Int64(vals?.fileSize ?? 0)
        }
        return total
    }
}
