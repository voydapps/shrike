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
import os

// MARK: - Stats

public struct ThumbStats: Sendable {
    public let memoryHits: Int
    public let diskHits: Int
    public let misses: Int
    public let diskBytesUsed: Int64
    public let diskBytesAreApproximate: Bool

    public init(memoryHits: Int, diskHits: Int, misses: Int, diskBytesUsed: Int64, diskBytesAreApproximate: Bool = false) {
        self.memoryHits = memoryHits
        self.diskHits = diskHits
        self.misses = misses
        self.diskBytesUsed = diskBytesUsed
        self.diskBytesAreApproximate = diskBytesAreApproximate
    }
}

public struct ThumbnailClearResult: Sendable {
    public let success: Bool
    public let errorDescription: String?
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
    struct TestHooks: Sendable {
        var beforeResourceReservation: (@Sendable () async throws -> Void)? = nil
        var beforeDiskRead: (@Sendable (URL) async throws -> Void)? = nil
        var beforeExactScan: (@Sendable () -> Void)? = nil
        var beforeTombstoneDelete: (@Sendable () -> Void)? = nil
    }
    private var testHooks = TestHooks()
    func setHooksForTesting(_ hooks: TestHooks) { testHooks = hooks }

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
        let resourceDemand: ImageWorkDemand
        /// Callers currently awaiting the result.
        var interest = 0
        /// Created by `prefetch`: kept even with no caller waiting.
        var pinned = false
        /// Past the slot queue (decoding or reading disk): can't be dropped.
        var started = false
        /// The file was evicted (or every caller left) while this job ran: its
        /// task is cancelled and it ends in `CancellationError`, nothing is
        /// cached, and new requests do not join it (see `liveJob(for:)`).
        var discardResult = false
        var task: Task<CGImage, any Error>?
        let epoch: UInt64
        let version: UInt64
        let prefix: String
        init(key: String, priority: ThumbnailPriority, epoch: UInt64, version: UInt64, prefix: String) {
            self.key = key
            self.priority = priority
            self.resourceDemand = ImageWorkDemand(priority: priority == .visible ? .visible : priority == .nearby ? .nearby : .speculative,
                policy: priority == .visible ? .oneOversizedOperation : .bounded)
            self.epoch = epoch; self.version = version; self.prefix = prefix
        }
    }
    private var jobs: [String: Job] = [:]
    private var cacheEpoch: UInt64 = 0
    private var invalidationVersions: [String: UInt64] = [:]
    private var diskEstimate: Int64 = 0
    private var diskEstimateWrites = -1
    private var diskEstimateDelta: Int64 = 0
    private var statisticsScanRunning = false
    private let resources: ImageResourceBudget
    private let resourceOwner = ImageResourceOwner()
    private var pressureObservation: ImagePressureObservation?

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
        memoryByteLimit: Int = ThumbnailCache.defaultMemoryByteLimit,
        resources: ImageResourceBudget = .shared
    ) throws {
        self.diskRoot = diskURL
        self.diskCeilingBytes = diskCeilingBytes
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes ?? Self.defaultMaxConcurrentDecodes)
        self.resources = resources
        self.memory = ThumbnailMemoryLRU(byteLimit: memoryByteLimit, countLimit: 1024, resources: resources)
        self.disk = ThumbnailDiskStore(root: diskURL, resources: resources)
        try FileManager.default.createDirectory(
            at: diskURL, withIntermediateDirectories: true
        )
        self.evictionTicker = nil
        // Start the eviction ticker asynchronously since `init` can't
        // call actor-isolated methods synchronously under Swift 6.
        Task { [weak self] in
            await self?.startEvictionTicker()
            await self?.observeResourcePressure()
        }
    }

    /// The ticker sleeps 60 s per round: without this a dropped cache's task
    /// would linger until its next wake-up.
    deinit { evictionTicker?.cancel() }

    var evictionTickerForTesting: Task<Void, Never>? { evictionTicker }

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
    internal func interestForTesting(for source: any ImageSource, maxPixelSize: Int) -> Int {
        jobs[Self.cacheKey(for: source, maxPixelSize: maxPixelSize)]?.interest ?? 0
    }
    internal func doomedJobCountForTesting() -> Int { jobs.values.filter(\.discardResult).count }

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

        let job = liveJob(for: key) ?? startJob(key: key, source: source, maxPixelSize: maxPixelSize,
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
            try Task.checkCancellation()
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
            let job = liveJob(for: key) ?? startJob(key: key, source: source, maxPixelSize: maxPixelSize,
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
        updateResourceDemand(job)
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

    /// The job a new request may join. A running job that was marked
    /// "discard" (its callers left, or its file was evicted) has a cancelled
    /// task and will end in `CancellationError`: a caller that joined it
    /// would get that error although it never cancelled, and its grid cell
    /// would stay blank. Such a job is not joined; `startJob` replaces it
    /// (the old one ends harmlessly, its id no longer matches `jobs[key]`).
    private func liveJob(for key: String) -> Job? {
        guard let job = jobs[key], !job.discardResult else { return nil }
        return job
    }

    private func startJob(key: String, source: any ImageSource, maxPixelSize: Int,
                          priority: ThumbnailPriority) -> Job {
        let prefix = Self.pathPrefix(for: source)
        let job = Job(key: key, priority: priority, epoch: cacheEpoch,
                      version: invalidationVersions[prefix, default: 0], prefix: prefix)
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
        let work = try await cache.reserveWork(for: key, jobID: jobID, size: maxPixelSize)
        defer { withExtendedLifetime(work) {} }
        guard await cache.acquireSlot(for: key, jobID: jobID) else {
            await cache.finishCancelled(key: key, jobID: jobID)
            throw CancellationError()
        }
        let decoded: Result<CGImage, any Error>
        var fromDisk = false
        do {
            try await cache.beforeDiskRead(diskFile)
            try Task.checkCancellation()
            if await cache.diskReadsAvailable(), let warm = try await ThumbnailBlockingIO.run({
                withExtendedLifetime(work) { ThumbnailDiskStore.read(at: diskFile) }
            }) {
                fromDisk = true; decoded = .success(warm)
            } else {
                do {
                    if let file = source as? FileImageSource {
                        decoded = .success(try await ThumbnailBlockingIO.run {
                            try withExtendedLifetime(work) { try file.decodeImage(maxPixelSize: maxPixelSize) }
                        })
                    } else { decoded = .success(try await source.loadCGImage(maxPixelSize: maxPixelSize)) }
                } catch ImageSourceError.unsupported {
                    decoded = .success(try await quickLookThumbnail(for: sourceURL(source), maxPixelSize: maxPixelSize,
                                                                    reservation: work))
                }
            }
        } catch {
            decoded = .failure(error)
        }
        await cache.releaseDecodeSlot()
        switch decoded {
        case .success(let image):
            guard await cache.finish(key: key, jobID: jobID, image: image, fromDisk: fromDisk, diskFile: diskFile) else {
                throw CancellationError()
            }
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
    private func finish(key: String, jobID: UUID, image: CGImage, fromDisk: Bool, diskFile: URL) -> Bool {
        guard let job = jobs[key], job.id == jobID else { return false }
        if job.discardResult || job.epoch != cacheEpoch || job.version != invalidationVersions[job.prefix, default: 0]
            || (job.interest <= 0 && !job.pinned) {
            jobs[key] = nil
            return false
        }
        memory.set(image, for: key)
        if fromDisk {
            diskHits += 1
        } else {
            misses += 1
            disk.enqueueWrite(image, to: diskFile)
        }
        if let job = jobs[key], job.id == jobID { jobs[key] = nil }
        return true
    }

    private func finishCancelled(key: String, jobID: UUID) {
        if let job = jobs[key], job.id == jobID { jobs[key] = nil }
    }

    private func updateResourceDemand(_ job: Job) {
        let priority: ImageWorkPriority = job.priority == .visible ? .visible : job.priority == .nearby ? .nearby : .speculative
        let policy: ImageAdmissionPolicy = job.priority == .visible ? .oneOversizedOperation : .bounded
        // Release the demand lock before acquiring the budget lock. The
        // insertion path reads demand under the budget lock, so an update
        // either precedes insertion or updates the newly queued waiter.
        job.resourceDemand.update(priority: priority, policy: policy)
        resources.updatePriority(for: job.id, to: priority, policy: policy)
    }

    private func raise(_ job: Job, to priority: ThumbnailPriority) {
        guard priority > job.priority else { return }
        job.priority = priority
        updateResourceDemand(job)
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
        guard let job = jobs[key] else { return }
        if job.started {
            if job.interest <= 0 && !job.pinned { job.discardResult = true; job.task?.cancel() }
            return
        }
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
        let delta = disk.changedBytes
        diskEstimate = max(0, diskEstimate + delta - diskEstimateDelta)
        diskEstimateDelta = delta
        reconcileStatisticsIfNeeded()
        return ThumbStats(
            memoryHits: memoryHits,
            diskHits: diskHits,
            misses: misses,
            diskBytesUsed: diskEstimate,
            diskBytesAreApproximate: diskEstimateWrites != disk.acceptedWrites
        )
    }

    /// Sum of on-disk cache bytes under `diskRoot`. Walks the directory once
    /// via `FileManager.enumerator`. Intentionally uncached — callers are
    /// user-driven (Preferences tab open + after "Clear cache"), not hot.
    public func currentDiskBytes() async -> Int64 {
        let root = diskRoot, epoch = cacheEpoch, writes = disk.acceptedWrites, hook = testHooks.beforeExactScan
        let bytes = await Task.detached(priority: .utility) { hook?(); return Self.diskBytesUsed(root: root) }.value
        if epoch == cacheEpoch {
            diskEstimate = bytes; diskEstimateDelta = disk.changedBytes
            diskEstimateWrites = disk.pendingWrites == 0 ? writes : -1
        }
        return bytes
    }

    /// Directory the cache writes to. Exposed so the Preferences window can
    /// offer "Reveal in Finder" without duplicating the path-construction
    /// logic.
    public var diskDirectory: URL { diskRoot }

    /// Recursively delete every file under `diskRoot`, then re-create the
    /// empty root. Also wipes the in-memory tier so the next request rebuilds
    /// the thumbnail from scratch. "Clear cache" in Preferences calls this.
    @discardableResult
    public func clearAll() async -> ThumbnailClearResult {
        cacheEpoch &+= 1
        memory.removeAll()
        disk.beginClear()
        for job in jobs.values { job.discardResult = true; job.task?.cancel() }
        jobs.removeAll()
        let waiters = decodeWaiters; decodeWaiters.removeAll()
        for waiter in waiters { waiter.cont.resume(returning: false) }
        let disk = self.disk, deleteHook = testHooks.beforeTombstoneDelete
        do {
            let tombstones = try await Task.detached(priority: .utility) { try disk.rotateRoot() }.value
            // Old encodes may still have temporary paths under the old
            // root; wait for the real work before reporting completion.
            await disk.waitUntilIdle()
            try await Task.detached(priority: .utility) { deleteHook?(); try disk.removeTombstones(tombstones) }.value
            _ = await currentDiskBytes()
            return ThumbnailClearResult(success: true, errorDescription: nil)
        } catch {
            return ThumbnailClearResult(success: false, errorDescription: error.localizedDescription)
        }
    }

    private func diskReadsAvailable() -> Bool { disk.isAvailable }
    private func beforeDiskRead(_ url: URL) async throws { try await testHooks.beforeDiskRead?(url) }
    private func reserveWork(for key: String, jobID: UUID, size: Int) async throws -> ImageWorkReservation {
        guard let job = jobs[key], job.id == jobID else { throw CancellationError() }
        let estimate = try ImageWorkingSetEstimate(width: size, height: size).totalBytes
        let demand = job.resourceDemand
        try await testHooks.beforeResourceReservation?()
        return try await resources.reserve(bytes: estimate, owner: resourceOwner, category: .thumbnail,
                                           requestID: jobID, demand: demand)
    }
    private func observeResourcePressure() {
        guard pressureObservation == nil else { return }
        pressureObservation = resources.observePressure { [weak self] pressure in
            guard pressure != .normal else { return }
            Task { await self?.relievePressure() }
        }
    }
    private func relievePressure() {
        memory.removeAll()
        for job in jobs.values where job.priority == .prefetch && job.interest <= 0 {
            job.pinned = false; drop(key: job.key)
        }
        cancelQueued(atOrBelow: .prefetch)
    }
    private func reconcileStatisticsIfNeeded() {
        guard !statisticsScanRunning, diskEstimateWrites != disk.acceptedWrites else { return }
        statisticsScanRunning = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.currentDiskBytes()
            await self.statisticsScanFinished()
        }
    }
    private func statisticsScanFinished() { statisticsScanRunning = false }

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
        invalidationVersions[prefix, default: 0] &+= 1
        memory.removeAll(keyPrefix: prefix)
        for (key, job) in jobs where key.hasPrefix(prefix) {
            if job.started { job.discardResult = true } else { drop(key: key) }
        }
        disk.cancelPendingWrites(namePrefix: prefix)
        let token = disk.maintenanceToken, disk = self.disk
        let shard = diskRoot.appendingPathComponent(String(prefix.prefix(2)), isDirectory: true)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: shard.path) else { return }
            for name in names where name.hasPrefix(prefix) {
                _ = disk.removeFile(shard.appendingPathComponent(name), token: token)
            }
        }.value
    }

    /// `evict(url:)` unless the thumbnail on hand is for the file as it is now.
    /// The key holds path, mtime and size; a rating, flag or tag (an extended
    /// attribute) changes none of them. Returns whether it evicted.
    @discardableResult
    public func evictIfContentChanged(url: URL) async -> Bool {
        // A fresh URL: Foundation caches resource values on the instance.
        let stem = Self.keyStem(for: FileImageSource(url: URL(fileURLWithPath: url.path)))
        let shard = diskRoot.appendingPathComponent(String(stem.prefix(2)), isDirectory: true)
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: shard.path)) ?? [])
            .contains { $0.hasPrefix(stem) }
        if onDisk || memory.contains(keyPrefix: stem) { return false }
        await evict(url: url)
        return true
    }

    /// Sets the disk-tier ceiling. Takes effect at once: if the cache is
    /// over the new ceiling it is trimmed (oldest first) before returning.
    /// The trim walks the folder off this actor, so thumbnail requests
    /// keep being served meanwhile.
    public func setDiskCeiling(bytes: Int64) async {
        diskCeilingBytes = max(0, bytes)
        lastEviction = Date()
        let root = diskRoot, ceiling = diskCeilingBytes, disk = self.disk, token = disk.maintenanceToken
        await Task.detached(priority: .utility) {
            Self.trimDisk(root: root, ceiling: ceiling, disk: disk, token: token)
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

    private struct QuickLookWaiter: Sendable {
        var continuation: CheckedContinuation<CGImage, any Error>?
        var cancelled = false
    }
    private static func quickLookThumbnail(
        for url: URL?, maxPixelSize: Int, reservation: ImageWorkReservation
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
        let waiter = OSAllocatedUnfairLock(initialState: QuickLookWaiter())
        // Immutable request reference, synchronized rather than adding an
        // unchecked Sendable wrapper around the SDK's NSObject type.
        let requestBox = OSAllocatedUnfairLock(uncheckedState: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let cancelled = waiter.withLock { state in state.continuation = cont; return state.cancelled }
                if cancelled {
                    let take = waiter.withLock { state in defer { state.continuation = nil }; return state.continuation }
                    take?.resume(throwing: CancellationError()); return
                }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { r, e in
                    defer { withExtendedLifetime(reservation) {} }
                    let take = waiter.withLock { state in defer { state.continuation = nil }; return state.continuation }
                    if let e { take?.resume(throwing: e) }
                    else if let r { take?.resume(returning: r.cgImage) }
                    else { take?.resume(throwing: ThumbnailCacheError.sourceUnavailable) }
                }
            }
        } onCancel: {
            let take = waiter.withLock { state in
                state.cancelled = true; defer { state.continuation = nil }; return state.continuation
            }
            requestBox.withLockUnchecked { QLThumbnailGenerator.shared.cancel($0) }
            take?.resume(throwing: CancellationError())
        }
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
        let root = diskRoot, ceiling = diskCeilingBytes, disk = self.disk, token = disk.maintenanceToken
        Task.detached(priority: .utility) { [weak self] in
            Self.trimDisk(root: root, ceiling: ceiling, disk: disk, token: token)
            await self?.trimFinished()
        }
    }

    private func trimFinished() { trimRunning = false }

    /// Exposed for tests.
    public func runEvictionNow() async {
        lastEviction = Date()
        await setDiskCeiling(bytes: diskCeilingBytes)
    }

    /// Deletes the oldest files under `root` until it holds ≤ `ceiling`.
    private nonisolated static func trimDisk(root diskRoot: URL, ceiling diskCeilingBytes: Int64,
        disk: ThumbnailDiskStore, token: (epoch: Int, sequence: UInt64)) {
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
            if disk.removeFile(entry.url, token: token) {
                total -= entry.size
            }
        }
    }

    private nonisolated static func diskBytesUsed(root diskRoot: URL) -> Int64 {
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
