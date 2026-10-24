//
//  DecodeQueue.swift
//  ShrikeCore
//
//  Actor that owns the sliding-window decode strategy for ONE viewer
//  window (two windows sharing a queue showed each other's photos).
//
//  * Cache and in-flight work are keyed by file identity
//    (`ImageSource.id`), never by list index.
//    A result that lands after its list was replaced, or after the file
//    was evicted, is dropped (token check in `install`).
//  * The window is ±`windowRadius` around the current image, ordered by
//    the direction of travel, and bounded by a BYTE budget: current and
//    both direct neighbours are always kept; farther neighbours only if
//    they fit. Large images therefore shrink the window, never to zero.
//  * Moving the window cancels decodes that fell out of it. Work that has
//    not started yet on the `DecodeLane` never runs.
//  * An optional `DisplayPreparer` (the viewer's GPU texture builder)
//    runs right after each decode, on the lane, so prefetched neighbours
//    are GPU-ready before the user presses the key.
//

import Foundation
import CoreGraphics
import ImageIO
import os

// MARK: - Errors

public enum DecodeQueueError: Error, Sendable {
    case emptyList
    case outOfRange
    case decodeFailed
    case cancelled
    case memoryBudgetExceeded
}

// MARK: - Decoded entries

/// Something the viewer builds from a decoded image ahead of time (a GPU
/// texture). Its size counts against the queue's byte budget.
public protocol PreparedDisplayImage: Sendable {
    var byteCount: Int { get }
}

/// Builds the prepared form of a decoded image. Runs on the decode lane
/// (a background thread); may block (e.g. wait for a GPU upload).
/// `maxLongEdge` is the size the queue asked for: the fast decode path
/// can return up to 2x that, and the texture need not be larger.
public struct DisplayPreparer: Sendable {
    /// Builds the prepared form of an image that is already upright.
    public let prepare: @Sendable (_ image: CGImage, _ maxLongEdge: Int?) -> (any PreparedDisplayImage)?

    /// Builds the prepared form straight from a
    /// file's STORED pixels (not rotated yet) and applies the EXIF
    /// `orientation` on the GPU. `sourceSize` is the oriented size the
    /// result reports (the lazy CPU twin's size). Nil when the preparer
    /// can't: rotated files then take ImageIO's slower decode-and-rotate
    /// path on the CPU.
    public let prepareOriented: OrientedPrepare?

    public typealias OrientedPrepare = @Sendable (
        _ stored: CGImage, _ orientation: CGImagePropertyOrientation,
        _ sourceSize: (width: Int, height: Int), _ maxLongEdge: Int?
    ) -> (any PreparedDisplayImage)?

    public init(
        oriented: OrientedPrepare? = nil,
        _ prepare: @escaping @Sendable (_ image: CGImage, _ maxLongEdge: Int?) -> (any PreparedDisplayImage)?
    ) {
        self.prepare = prepare
        self.prepareOriented = oriented
    }

    public func callAsFunction(_ image: CGImage, _ maxLongEdge: Int?) -> (any PreparedDisplayImage)? {
        prepare(image, maxLongEdge)
    }
}

/// One decoded display image, tagged with the file it came from.
public struct DecodedImage: Sendable {
    public let sourceID: String
    public let image: CGImage
    public let prepared: (any PreparedDisplayImage)?
    /// Long edge the decode was asked for (the image may be larger).
    public let requestedLongEdge: Int?
    /// True when `image` holds no decoded pixels yet (a lazy twin from
    /// `FileImageSource.lazyDisplayImage`; the texture carries the photo).
    public let imageIsLazy: Bool
    public let resourceLease: ImageResourceLease?

    public init(
        sourceID: String,
        image: CGImage,
        prepared: (any PreparedDisplayImage)? = nil,
        requestedLongEdge: Int? = nil,
        imageIsLazy: Bool = false,
        resourceLease: ImageResourceLease? = nil
    ) {
        self.sourceID = sourceID
        self.image = image
        self.prepared = prepared
        self.requestedLongEdge = requestedLongEdge
        self.imageIsLazy = imageIsLazy
        self.resourceLease = resourceLease
    }

    /// Resident bytes: CPU pixels (unless lazy) plus prepared (GPU) bytes.
    /// Both count against the window's budget.
    public var byteCount: Int {
        (imageIsLazy ? 0 : image.bytesPerRow * image.height) + (prepared?.byteCount ?? 0)
    }
}

// MARK: - Actor

public actor DecodeQueue {

    /// Default byte budget for one window's cache: 512 MB, or 1/8 of RAM
    /// on small machines (never under 128 MB).
    public static let defaultByteBudget: Int = {
        let eighth = Int(clamping: ProcessInfo.processInfo.physicalMemory / 8)
        return min(512 * 1_048_576, max(128 * 1_048_576, eighth))
    }()

    // Configuration
    private let windowRadius: Int
    private let byteBudget: Int
    private let lane: DecodeLane
    private var preparer: DisplayPreparer?

    // Navigation state
    private var list: [any ImageSource] = [] { didSet { listIDsByPath = nil } }
    /// Standardized file path → decode ids of the list's files; built on
    /// first use after the list changes, so a burst of changed files is not
    /// one full list scan each (audit MP-10).
    private var listIDsByPath: [String: [String]]?
    private var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                // Moving again: the full window comes back.
                compactWindow = false
                publishReadyCurrent()
            }
        }
    }

    /// The current photo's finished entry,
    /// readable from the main thread without an actor hop, so a new
    /// window can put its first photo on the canvas in the same run-loop
    /// turn it is built (`readyEntry(sourceID:)`). Holds at most the
    /// current photo (on screen anyway); follows every cache change and
    /// every change of the current photo, and is emptied by `purge()`.
    private nonisolated let readyCurrent = OSAllocatedUnfairLock<DecodedImage?>(initialState: nil)

    /// The finished, usable entry of the current photo when it is the
    /// file `sourceID`; nil otherwise. Never waits and never decodes.
    public nonisolated func readyEntry(sourceID: String) -> DecodedImage? {
        readyCurrent.withLockUnchecked { entry in
            entry?.sourceID == sourceID ? entry : nil
        }
    }

    private func publishReadyCurrent() {
        let entry = list.indices.contains(currentIndex) ? usableEntry(for: currentIndex) : nil
        readyCurrent.withLockUnchecked { $0 = entry }
    }
    /// +1 when the user last moved forward, -1 backward. Orders prefetch.
    private var direction: Int = 1

    /// List generation — bumps on every `setNavigation`.
    public private(set) var generation: UInt64 = 0

    // Cache: file id -> decoded display image.
    private var cache: [String: DecodedImage] = [:]
    /// Ids inside the current window (set by `schedule`).
    private var wanted: Set<String> = []

    private struct Pending {
        let token: UInt64
        let task: Task<DecodedImage, any Error>
    }
    /// In-flight decode per file id. Duplicate requests share the task.
    private var inFlight: [String: Pending] = [:]
    /// Size and content date of each file when its decode started, so a
    /// "modified" report for a rating / flag / tag write (extended
    /// attribute only) does not drop a picture that is still right.
    private var decodeStamps: [String: FileContentStamp] = [:]
    private var nextToken: UInt64 = 0

    /// Monotonic counter incremented by every user-visible navigation
    /// request (`jumpTo` / `advance` / `retreat`). A jump re-checks it
    /// after every `await`; if a newer jump landed meanwhile, the stale
    /// one throws `CancellationError` instead of waiting for an
    /// irrelevant decode (128 held-arrow presses used to drain for
    /// 10-15 s).
    private var latestNavGen: UInt64 = 0

    /// Long-edge override set by the viewer (`setMaxLongEdge`) — the real
    /// backing size of its screen. `nil` = the user pref.
    private var maxLongEdgeOverride: Int?

    /// Long edge, in pixels, that display decodes aim for.
    public var maxDisplayLongEdge: Int { effectiveMaxLongEdge }
    var effectiveMaxLongEdge: Int { maxLongEdgeOverride ?? Prefs.maxDisplayLongEdge }

    /// LRU cap on the header-dimensions cache (~64 B per entry).
    static let dimensionCacheCap: Int = 2000

    /// Header-only pixel dimensions keyed by `ImageSource.id`, used to
    /// clamp the requested size (`targetPixelSize(for:)`).
    private var dimensionCache: [String: (width: Int, height: Int)] = [:]
    private var dimensionLRU: [String] = []
    private var dimensionProbesInFlight: Set<String> = []

    /// A viewer that is not the key window keeps
    /// only its current photo (`setBackground`), so four open windows no
    /// longer hold four prefetch windows. Its neighbours come back when
    /// it is key again.
    private var isBackground = false

    /// How long the viewer may sit on one photo before the window shrinks
    /// to the current photo and its two direct neighbours (nil: never).
    /// The farther neighbours (about 15 MB of GPU texture each in a
    /// 1200 x 800 window) only help while the user is stepping, and they
    /// are decoded again as soon as the user steps.
    private let idleTrimDelay: Duration?
    private var compactWindow = false
    private var idleTrimTask: Task<Void, Never>?
    /// Radius in use now: the configured one, or 1 after the idle trim.
    private var effectiveRadius: Int { compactWindow ? 1 : windowRadius }
    /// Process-wide byte count shared by every queue; far neighbours
    /// (beyond the direct ones) only load while the total fits
    /// `sharedByteBudget`.
    private let ledger: DecodeMemoryLedger
    private let sharedByteBudget: Int
    public nonisolated let resources: ImageResourceBudget
    public nonisolated let resourceOwner: ImageResourceOwner
    private var pressureObservation: ImagePressureObservation?

    public init(
        windowRadius: Int = 2,
        byteBudget: Int = DecodeQueue.defaultByteBudget,
        lane: DecodeLane = .shared,
        preparer: DisplayPreparer? = nil,
        ledger: DecodeMemoryLedger = .shared,
        sharedByteBudget: Int = DecodeMemoryLedger.defaultSharedBudget,
        idleTrimDelay: Duration? = .seconds(3),
        resources: ImageResourceBudget = .shared,
        resourceOwner: ImageResourceOwner = .init()
    ) {
        self.idleTrimDelay = idleTrimDelay
        self.windowRadius = max(1, windowRadius)
        self.byteBudget = byteBudget
        self.lane = lane
        self.preparer = preparer
        self.ledger = ledger
        self.sharedByteBudget = sharedByteBudget
        self.resources = resources; self.resourceOwner = resourceOwner
    }

    deinit {
        ledger.set(ObjectIdentifier(self), bytes: 0)
    }

    /// Background (not the key window): keep only the current photo and
    /// drop the neighbours; foreground again: prefetch them again.
    public func setBackground(_ background: Bool) {
        observeResourcePressure()
        guard background != isBackground else { return }
        isBackground = background
        if !list.isEmpty { schedule(around: currentIndex) }
    }

    /// Resident bytes of this queue's cache (tests, diagnostics).
    public func cachedBytes() -> Int {
        cache.values.reduce(0) { $0 + $1.byteCount }
    }

    private func reportBytes() {
        ledger.set(ObjectIdentifier(self), bytes: cachedBytes())
        publishReadyCurrent()
    }

    private func observeResourcePressure() {
        guard pressureObservation == nil else { return }
        pressureObservation = resources.observePressure { [weak self] pressure in
            guard pressure != .normal else { return }
            Task { await self?.relieveResourcePressure() }
        }
    }
    private func relieveResourcePressure() {
        compactWindow = true
        if !list.isEmpty { schedule(around: currentIndex) }
    }

    // MARK: - Configuration

    /// Install (or replace) the GPU preparer. Cached neighbours made
    /// without it are dropped so they get re-prepared.
    public func setPreparer(_ preparer: DisplayPreparer?) {
        self.preparer = preparer
        let keep = currentID
        for id in cache.keys where id != keep { cache.removeValue(forKey: id) }
        if !list.isEmpty { schedule(around: currentIndex) }
    }

    /// Decode at the real backing size of the
    /// viewer's screen. Entries decoded for a smaller size stop counting
    /// as hits (`usableEntry`) and the window is re-decoded.
    public func setMaxLongEdge(_ px: Int) {
        let clamped = max(256, px)
        guard clamped != maxLongEdgeOverride else { return }
        maxLongEdgeOverride = clamped
        if !list.isEmpty { schedule(around: currentIndex) }
    }

    // MARK: - Public API

    public func setNavigation(list: [any ImageSource], currentIndex: Int) async {
        self.list = list
        self.currentIndex = list.isEmpty ? 0 : max(0, min(currentIndex, list.count - 1))
        self.direction = 1
        generation &+= 1
        // Supersede nav tasks queued against the old list.
        latestNavGen &+= 1
        // Keeps cached / in-flight files that are still in the new window
        // (re-opening the same folder is free); cancels the rest.
        schedule(around: self.currentIndex)
    }

    public func current() -> CGImage? {
        currentID.flatMap { cache[$0]?.image }
    }

    /// The ready entry for `index`, if it is cached at the current size.
    /// Never starts work. The viewer uses this to skip stand-ins.
    public func cachedEntry(at index: Int) -> DecodedImage? {
        guard list.indices.contains(index) else { return nil }
        return usableEntry(for: index)
    }

    /// A paging swipe toward `index` found no ready
    /// texture. Put that photo first — travel toward it, so it ranks
    /// right after the current photo, and start its decode now if it is
    /// not running — then wait for it. Never moves the current photo and
    /// never supersedes a navigation. Returns nil when the decode fails
    /// or is cancelled. Best effort: a decode already waiting for a lane
    /// slot is not reordered.
    public func prioritizeNeighbour(at index: Int) async -> DecodedImage? {
        guard list.indices.contains(index), index != currentIndex else { return nil }
        if let hit = usableEntry(for: index) { return hit }
        let id = list[index].id
        direction = index > currentIndex ? 1 : -1
        schedule(around: currentIndex)
        if inFlight[id] == nil, usableEntry(for: index) == nil {
            wanted.insert(id)
            spawnDecode(index: index)
        }
        prioritizedForTesting.append(index)
        guard let pending = inFlight[id] else { return usableEntry(for: index) }
        return try? await pending.task.value
    }

    /// Test seam: indices `prioritizeNeighbour` was asked for.
    private(set) var prioritizedForTesting: [Int] = []

    public func advance() async throws -> (image: CGImage, index: Int) {
        guard !list.isEmpty else { throw DecodeQueueError.emptyList }
        let next = (currentIndex + 1) % list.count
        let img = try await jumpTo(index: next)
        return (img, next)
    }

    public func retreat() async throws -> (image: CGImage, index: Int) {
        guard !list.isEmpty else { throw DecodeQueueError.emptyList }
        let prev = (currentIndex - 1 + list.count) % list.count
        let img = try await jumpTo(index: prev)
        return (img, prev)
    }

    public func jumpTo(index: Int) async throws -> CGImage {
        try await jumpToEntry(index: index).image
    }

    /// Move the window to `index` and return its decoded image. A cached
    /// image returns at once, without yielding.
    public func jumpToEntry(index: Int) async throws -> DecodedImage {
        guard list.indices.contains(index) else { throw DecodeQueueError.outOfRange }

        latestNavGen &+= 1
        let myGen = latestNavGen
        if index != currentIndex {
            direction = index > currentIndex ? 1 : -1
        }
        currentIndex = index
        let state = ShrikeSignposts.navigation.begin("jumpTo", "index=\(index)")

        if let hit = usableEntry(for: index) {
            schedule(around: index)
            ShrikeSignposts.navigation.end("jumpTo", state, "hit")
            return hit
        }

        // Yield once so peer jumps piling up behind us can bump
        // `latestNavGen` before we start real work.
        await Task.yield()
        guard myGen == latestNavGen else {
            ShrikeSignposts.navigation.end("jumpTo", state, "superseded")
            throw CancellationError()
        }

        schedule(around: index)
        let id = list[index].id
        if let hit = usableEntry(for: index) {
            ShrikeSignposts.navigation.end("jumpTo", state, "hit")
            return hit
        }
        guard var pending = inFlight[id] else {
            ShrikeSignposts.navigation.end("jumpTo", state, "error")
            throw DecodeQueueError.decodeFailed
        }

        let entry: DecodedImage
        var respawned = false
        while true {
            do {
                entry = try await pending.task.value
                break
            } catch is CancellationError {
                ShrikeSignposts.navigation.end("jumpTo", state, "superseded")
                throw CancellationError()
            } catch DecodeQueueError.memoryBudgetExceeded where !respawned {
                // COR-5: this task was started as a far neighbour (speculative, may be
                // refused under memory pressure). The user has jumped onto it, so it is
                // the current photo now: decode it again as REQUIRED instead of
                // reporting a good file as unreadable.
                respawned = true
                guard myGen == latestNavGen else {
                    ShrikeSignposts.navigation.end("jumpTo", state, "superseded")
                    throw CancellationError()
                }
                if inFlight[id]?.token == pending.token { inFlight.removeValue(forKey: id) }
                spawnDecode(index: index)
                guard let again = inFlight[id] else {
                    ShrikeSignposts.navigation.end("jumpTo", state, "error")
                    throw DecodeQueueError.decodeFailed
                }
                pending = again
            } catch {
                ShrikeSignposts.navigation.end("jumpTo", state, "error")
                throw error
            }
        }
        guard myGen == latestNavGen else {
            ShrikeSignposts.navigation.end("jumpTo", state, "superseded")
            throw CancellationError()
        }
        // Install now (the completion hop may not have run yet) so
        // `current()` is right the moment we return.
        install(entry, id: id, token: pending.token)
        ShrikeSignposts.navigation.end(
            "jumpTo", state, "pixelCount=\(entry.image.width * entry.image.height)"
        )
        return entry
    }

    /// Idempotent. Moves the window to `index` (the radius argument is
    /// kept for API compatibility; the byte budget decides).
    public func prefetch(around index: Int, radius: Int) async {
        guard list.indices.contains(index) else { return }
        schedule(around: index)
    }

    /// Every id this queue may hold for `url`: its URL string and the id of
    /// each list entry that is the same file.
    private func decodeIDs(for url: URL) -> Set<String> {
        if listIDsByPath == nil {
            var map: [String: [String]] = [:]
            for src in list {
                if let file = src as? FileImageSource { map[file.url.standardizedFileURL.path, default: []].append(file.id) }
            }
            listIDsByPath = map
        }
        var ids: Set<String> = [url.absoluteString]
        ids.formUnion(listIDsByPath?[url.standardizedFileURL.path] ?? [])
        return ids
    }

    /// `evictIfContentChanged(url:)` for a burst of changed files; returns
    /// the ones it evicted.
    public func evictIfContentChanged(urls: [URL]) -> [URL] {
        urls.filter { evictIfContentChanged(url: $0) }
    }

    /// `evict(url:)`, but only when the file's content is not what was
    /// decoded (size or content date differs). A file never decoded has no
    /// stamp and is evicted, to be safe. A stamp outlives the cached image
    /// (idle trim), so a trimmed file is not "changed" either.
    /// Returns whether it evicted.
    @discardableResult
    public func evictIfContentChanged(url: URL) -> Bool {
        let ids = decodeIDs(for: url)
        let stamps = ids.compactMap { decodeStamps[$0] }
        if !stamps.isEmpty, !stamps.contains(where: { $0.differs(from: url) }) {
            return false
        }
        evict(url: url)
        return true
    }

    /// Drop everything cached or decoding for `url` (file changed on disk:
    /// save, revert, rotate, rename, external edit).
    public func evict(url: URL) {
        let ids = decodeIDs(for: url)
        for id in ids {
            cache.removeValue(forKey: id)
            inFlight.removeValue(forKey: id)?.task.cancel()
            dimensionCache.removeValue(forKey: id)
            dimensionLRU.removeAll { $0 == id }
            decodeStamps.removeValue(forKey: id)
        }
        publishReadyCurrent()
        if !list.isEmpty { schedule(around: currentIndex) }
    }

    /// The window closed: cancel every decode, drop every cached image and
    /// texture, and forget the list. Late results are dropped by the token
    /// check in `install`. (Closed windows used to keep
    /// their caches while anything still referenced the queue.)
    public func purge() {
        pressureObservation?.cancel()
        pressureObservation = nil
        idleTrimTask?.cancel()
        idleTrimTask = nil
        fullResTask?.cancel()
        fullResTask = nil
        for pending in inFlight.values { pending.task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        decodeStamps.removeAll()
        wanted.removeAll()
        list = []
        currentIndex = 0
        generation &+= 1
        latestNavGen &+= 1
        dimensionCache.removeAll()
        dimensionLRU.removeAll()
        reportBytes()
        readyCurrent.withLockUnchecked { $0 = nil }
        // Restart the quiet period after releasing the queue's cached buffers.
        MemoryRelief.schedule()
    }

    /// Full-resolution image of the photo at `index`, for zoom past the
    /// display texture ("double-click = exact 100 %").
    ///
    /// - `image` holds every pixel of the file, EXIF orientation applied,
    ///   so `image.width × image.height` IS the file's pixel size after
    ///   orientation: 100 % = one `image` pixel per screen pixel.
    /// - `prepared` is the GPU texture from this queue's preparer, built
    ///   on the lane (nil without a preparer, or when the image is larger
    ///   than a Metal texture allows). With a texture, upright photos get
    ///   a lazy `image` twin (`imageIsLazy`) so the CPU copy is not kept.
    /// - Never enters the prefetch cache and never counts against its
    ///   budget. Runs on `DecodeLane.fullResolution` (one slot of its
    ///   own), so it never takes a slot the next/previous prefetch needs.
    /// - One at a time per queue: a newer call cancels the older one.
    /// - Cancelling the calling task throws `CancellationError` at once;
    ///   the decode still running is dropped when it ends.
    /// - Other errors: `DecodeQueueError.outOfRange` / `.decodeFailed`.
    public func loadFullResolution(at index: Int) async throws -> DecodedImage {
        guard list.indices.contains(index) else { throw DecodeQueueError.outOfRange }
        let source = list[index]
        let id = source.id
        let preparer = self.preparer
        let resources = self.resources, owner = resourceOwner
        fullResTask?.cancel()
        let state = ShrikeSignposts.decode.begin("loadFullResolution", "index=\(index)")
        let task = Task.detached(priority: .userInitiated) { () throws -> DecodedImage in
            let estimate = try await Self.workingSet(for: source, target: nil)
            let reservation = try await resources.reserve(bytes: estimate, owner: owner, category: .decodeWork,
                                                          priority: .visible, policy: .requiredImage)
            guard let file = source as? FileImageSource else {
                let img = try await source.loadCGImage(maxPixelSize: nil)
                return withExtendedLifetime(reservation) {
                    DecodedImage(sourceID: id, image: img, prepared: preparer?.prepare(img, nil))
                        .retaining(in: resources, owner: owner, category: .fullResolution)
                }
            }
            return try await DecodeLane.fullResolution.runInterruptible { isCancelled in
                defer { withExtendedLifetime(reservation) {} }
                // Upright + texture: the texture builder decodes the lazy
                // image itself, once (fastest, see
                // `uprightFullResolutionImage`); the caller gets a lazy
                // CPU twin, so no CPU copy of the pixels is kept.
                if let preparer, let source = file.uprightFullResolutionImage(cacheDecoded: false) {
                    if isCancelled() { throw CancellationError() }
                    if let prepared = preparer.prepare(source, nil) {
                        let twin = file.uprightFullResolutionImage(cacheDecoded: true) ?? source
                        return DecodedImage(sourceID: id, image: twin, prepared: prepared,
                                            requestedLongEdge: nil, imageIsLazy: true)
                            .retaining(in: resources, owner: owner, category: .fullResolution)
                    }
                }
                if isCancelled() { throw CancellationError() }
                let img = try file.decodeFullResolution(isCancelled: isCancelled)
                if isCancelled() { throw CancellationError() }
                return DecodedImage(sourceID: id, image: img, prepared: preparer?.prepare(img, nil),
                                    requestedLongEdge: nil).retaining(in: resources, owner: owner, category: .fullResolution)
            }
        }
        fullResTask = task
        defer {
            // A completed task retains its result. Keep only the active
            // cancellation handle, so returning to Fit can release the
            // full-size image. An older call must not clear a newer task.
            if fullResTask == task { fullResTask = nil }
        }
        do {
            let entry = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            ShrikeSignposts.decode.end("loadFullResolution", state,
                                      "pixelCount=\(entry.image.width * entry.image.height)")
            return entry
        } catch is CancellationError {
            ShrikeSignposts.decode.end("loadFullResolution", state, "cancelled")
            throw CancellationError()
        } catch {
            ShrikeSignposts.decode.end("loadFullResolution", state, "error")
            throw DecodeQueueError.decodeFailed
        }
    }

    /// The newest `loadFullResolution` decode (cancelled by the next one
    /// and by `purge`).
    private var fullResTask: Task<DecodedImage, any Error>?

    /// Older form of `loadFullResolution`: the decoded, oriented image
    /// only (no texture).
    public func loadFullRes(at index: Int) async throws -> CGImage {
        guard list.indices.contains(index) else { throw DecodeQueueError.outOfRange }
        let source = list[index]
        guard let file = source as? FileImageSource else {
            do { return try await source.loadCGImage(maxPixelSize: nil) } catch {
                throw DecodeQueueError.decodeFailed
            }
        }
        do {
            return try await DecodeLane.fullResolution.runInterruptible { isCancelled in
                try file.decodeFullResolution(isCancelled: isCancelled)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodeQueueError.decodeFailed
        }
    }

    // MARK: - Test seams

    func cachedIDs() -> Set<String> { Set(cache.keys) }
    /// Every index a decode was started for, in order.
    private(set) var spawnedForTesting: [Int] = []
    func spawnedIndicesForTesting() -> [Int] { spawnedForTesting }
    func inFlightIDs() -> Set<String> { Set(inFlight.keys) }
    func wantedIDs() -> Set<String> { wanted }

    #if DEBUG
    /// Failure-only ownership/lifetime diagnostics for integration tests.
    /// One actor snapshot avoids mixing state from different replans.
    func stateForTesting() -> String {
        let cached = cache.keys.sorted().map { id in
            guard let entry = cache[id] else { return id }
            let requested = entry.requestedLongEdge.map { String($0) } ?? "nil"
            return "\(id){pixels=\(entry.image.width)x\(entry.image.height),requested=\(requested),prepared=\(entry.prepared != nil)}"
        }
        return "queue currentIndex=\(currentIndex) currentID=\(currentID ?? "nil") sourceCount=\(list.count) sourceIDs=\(list.map(\.id)) wanted=\(wanted.sorted()) cached=\(cached) inFlight=\(inFlight.keys.sorted()) spawned=\(spawnedForTesting) background=\(isBackground) compact=\(compactWindow) generation=\(generation) maxLongEdge=\(effectiveMaxLongEdge) pressure=\(resources.snapshot().pressure)"
    }
    #endif

    // MARK: - Window

    private var currentID: String? {
        list.indices.contains(currentIndex) ? list[currentIndex].id : nil
    }

    /// A cached entry counts only if it was decoded for at least the
    /// current target size (or already covers it).
    private func usableEntry(for index: Int) -> DecodedImage? {
        let id = list[index].id
        guard let entry = cache[id] else { return nil }
        let want = targetPixelSize(for: index) ?? effectiveMaxLongEdge
        // An entry far LARGER than the target (made
        // for full screen, window now back to windowed) is not usable
        // either, or its 70 MB texture would stay for good. 25 % slack so
        // small resizes do not re-decode.
        if Self.isOversize(entry, for: want) { return nil }
        if max(entry.image.width, entry.image.height) >= want { return entry }
        if let asked = entry.requestedLongEdge, asked >= want { return entry }
        return nil
    }

    /// True when `entry` was made for a size well above `want`: both the
    /// pixels it holds and the size it was asked for exceed `want` by more
    /// than 25 %. (A small source clamped by its own size is never oversize.)
    static func isOversize(_ entry: DecodedImage, for want: Int) -> Bool {
        let limit = want + want / 4
        guard max(entry.image.width, entry.image.height) > limit else { return false }
        guard let asked = entry.requestedLongEdge else { return false }
        return asked > limit
    }

    /// Window indices in priority order: current, then alternating
    /// ahead/behind with the direction of travel first. Clamped, no wrap.
    private func windowOrder(around index: Int) -> [Int] {
        var order = [index]
        for d in 1...effectiveRadius {
            for i in [index + d * direction, index - d * direction] where list.indices.contains(i) {
                order.append(i)
            }
        }
        return order
    }

    /// Average bytes of cached entries — the estimate for images not yet
    /// decoded. 32 MB before anything is known.
    private func estimatedBytes() -> Int {
        guard !cache.isEmpty else { return 32 * 1_048_576 }
        return cache.values.reduce(0) { $0 + $1.byteCount } / cache.count
    }

    /// Move the window: pick wanted files under the byte budget, start
    /// their decodes (current first), cancel and drop everything else.
    private func schedule(around index: Int) {
        guard list.indices.contains(index) else {
            wanted = []
            return
        }
        let estimate = estimatedBytes()
        // Far neighbours must fit this window's budget AND what the other
        // windows leave of the shared one.
        observeResourcePressure()
        let sharedAvailable = ledger === DecodeMemoryLedger.shared
            ? resources.availableBytes(excluding: resourceOwner)
            : max(0, sharedByteBudget - ledger.others(than: ObjectIdentifier(self))) // legacy isolated cache-policy tests
        var budgetLeft = min(byteBudget, min(sharedByteBudget, sharedAvailable))
        var keep: [String] = []
        var toStart: [Int] = []
        for (rank, i) in windowOrder(around: index).enumerated() {
            // A background window keeps only its current photo.
            if isBackground && rank > 0 { break }
            let id = list[i].id
            let usable = usableEntry(for: i)
            let cost = usable?.byteCount ?? estimate
            // Current + the two direct neighbours are always kept.
            if rank > 2 && cost > budgetLeft { break }
            budgetLeft -= cost
            keep.append(id)
            if usable == nil && inFlight[id] == nil { toStart.append(i) }
        }
        wanted = Set(keep)
        for (id, pending) in inFlight where !wanted.contains(id) {
            pending.task.cancel()
            inFlight.removeValue(forKey: id)
        }
        for id in cache.keys where !wanted.contains(id) {
            cache.removeValue(forKey: id)
        }
        reportBytes()
        for i in toStart {
            spawnDecode(index: i)
        }
        armIdleTrim()
    }

    /// (Re)starts the idle timer: when the user has not moved for
    /// `idleTrimDelay`, the window shrinks to radius 1.
    private func armIdleTrim() {
        idleTrimTask?.cancel()
        idleTrimTask = nil
        guard let delay = idleTrimDelay, !compactWindow, !isBackground, windowRadius > 1 else { return }
        // Detached: a task that inherits the actor's isolation keeps the
        // queue (and, through it, the closed window) alive while it sleeps.
        idleTrimTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.compactWindowNow()
        }
    }

    private func compactWindowNow() {
        guard !compactWindow, !list.isEmpty else { return }
        compactWindow = true
        schedule(around: currentIndex)
    }

    /// Start a decode for `index` (off-actor, on the lane) and record it.
    private func spawnDecode(index: Int) {
        spawnedForTesting.append(index)
        let source = list[index]
        let id = source.id
        nextToken &+= 1
        let token = nextToken
        let target = targetPixelSize(for: index)
        let preparer = self.preparer
        let lane = self.lane
        let resources = self.resources, owner = resourceOwner
        let required = abs(index - currentIndex) <= 1
        let format: ImageFormat? = (source as? FileImageSource).flatMap { ImageFormat(url: $0.url) }

        // Cold open: the app may have started this file's decode before
        // the window existed (`DecodeHandoff`). Take it over.
        let handoff: Task<DecodedImage, any Error>? = {
            guard let file = source as? FileImageSource, let target else { return nil }
            return DecodeHandoff.shared.claim(url: file.url, target: target)
        }()

        let task = Task.detached(priority: .userInitiated) { () throws -> DecodedImage in
            if let handoff {
                let early = await withTaskCancellationHandler {
                    try? await handoff.value
                } onCancel: { handoff.cancel() }
                if let early {
                    ShrikeSignposts.decode.event("handoffTaken")
                    return DecodedImage(
                        sourceID: id, image: early.image, prepared: early.prepared,
                        requestedLongEdge: early.requestedLongEdge, imageIsLazy: early.imageIsLazy,
                        resourceLease: early.resourceLease
                    ).retaining(in: resources, owner: owner, category: .displayCache)
                }
            }
            try Task.checkCancellation()
            let estimate = try await Self.workingSet(for: source, target: target)
            let reservation: ImageWorkReservation
            if required {
                reservation = try await resources.reserve(bytes: estimate, owner: owner, category: .decodeWork,
                                                          priority: .visible, policy: .requiredImage)
            } else {
                guard let optional = resources.tryReserve(bytes: estimate, owner: owner, category: .decodeWork,
                                                         priority: .speculative, policy: .bounded) else {
                    throw DecodeQueueError.memoryBudgetExceeded
                }
                reservation = optional
            }
            defer { withExtendedLifetime(reservation) {} }
            let t0 = Date()
            let made: DecodedImage
            if let file = source as? FileImageSource, let target {
                made = try await lane.run { () throws -> DecodedImage in
                    defer { withExtendedLifetime(reservation) {} }
                    return try DecodeQueue.makeEntry(file: file, id: id, target: target, preparer: preparer)
                        .retaining(in: resources, owner: owner, category: .displayCache)
                }
            } else {
                let img = try await source.loadCGImage(maxPixelSize: target)
                if let preparer {
                    made = try await lane.run { () -> DecodedImage in
                        DecodedImage(
                            sourceID: id, image: img, prepared: preparer.prepare(img, target),
                            requestedLongEdge: target
                        )
                    }
                } else {
                    made = DecodedImage(sourceID: id, image: img, requestedLongEdge: target)
                }
            }
            if !Task.isCancelled, let format {
                await DecodeStatsStore.shared.record(format: format, duration: Date().timeIntervalSince(t0))
            }
            return made.resourceLease == nil ? made.retaining(in: resources, owner: owner, category: .displayCache) : made
        }
        inFlight[id] = Pending(token: token, task: task)
        if let file = source as? FileImageSource { decodeStamps[id] = FileContentStamp.read(file.url) }

        Task { [weak self] in
            let entry = try? await task.value
            await self?.complete(id: id, token: token, entry: entry)
        }
    }

    /// Decode `file` for a display of `target` pixels and build its
    /// texture. Blocks: run it on a `DecodeLane`.
    static func makeEntry(
        file: FileImageSource, id: String, target: Int, preparer: DisplayPreparer?
    ) throws -> DecodedImage {
        if let oriented = preparer?.prepareOriented,
           let entry = try makeOrientedEntry(file: file, id: id, target: target, prepare: oriented) {
            return entry
        }
        let img = try file.decodeDisplayImage(targetLongEdge: target)
        let prepared = preparer?.prepare(img, target)
        // Texture built: keep a lazy CPU twin instead of the decoded
        // pixels (saves memory).
        if prepared != nil,
           let lazy = file.lazyDisplayImage(targetLongEdge: target),
           lazy.width == img.width, lazy.height == img.height {
            return DecodedImage(
                sourceID: id, image: lazy, prepared: prepared,
                requestedLongEdge: target, imageIsLazy: true
            )
        }
        // PNG / TIFF / other thumbnail-path decodes
        // used to keep their full CPU pixels (15 MB at window size, 45 MB
        // at 4096 px) next to the texture. A lazy twin decodes again only
        // if something reads the pixels.
        if prepared != nil,
           let lazy = file.lazyReloadImage(like: img, targetLongEdge: target) {
            return DecodedImage(
                sourceID: id, image: lazy, prepared: prepared,
                requestedLongEdge: target, imageIsLazy: true
            )
        }
        return DecodedImage(sourceID: id, image: img, prepared: prepared, requestedLongEdge: target)
    }

    /// A rotated JPEG / HEIC (EXIF 2-8) used to
    /// decode through ImageIO's thumbnail + transform path (150-280 ms for
    /// an 18 MP JPEG at 4096 px) and kept that 42.7 MB CPU copy next to its
    /// texture. Now its stored pixels decode on the fast subsampled path
    /// (~45 ms), the preparer rotates them on the GPU while it builds the
    /// texture, and the entry keeps a lazy, already-rotated CPU twin.
    /// Nil: not a rotated JPEG/HEIC, or the preparer could not build it
    /// (the caller then takes the old path).
    static func makeOrientedEntry(
        file: FileImageSource, id: String, target: Int,
        prepare: DisplayPreparer.OrientedPrepare
    ) throws -> DecodedImage? {
        guard let frame = try file.decodeRotatedStoredFrame(targetLongEdge: target),
              let twin = file.lazyOrientedDisplayImage(frame: frame, targetLongEdge: target),
              let prepared = prepare(frame.image, frame.orientation, (twin.width, twin.height), target)
        else { return nil }
        return DecodedImage(sourceID: id, image: twin, prepared: prepared,
                            requestedLongEdge: target, imageIsLazy: true)
    }

    private func complete(id: String, token: UInt64, entry: DecodedImage?) {
        guard let entry else {
            if inFlight[id]?.token == token { inFlight.removeValue(forKey: id) }
            return
        }
        install(entry, id: id, token: token)
    }

    /// Install a finished decode — only if it is still the live request
    /// for that file (not cancelled, evicted, or from a replaced list)
    /// and the file is still in the window.
    private func install(_ entry: DecodedImage, id: String, token: UInt64) {
        guard inFlight[id]?.token == token else { return }
        inFlight.removeValue(forKey: id)
        guard wanted.contains(id) else { return }
        cache[id] = entry
        reportBytes()
        MemoryRelief.schedule()
        // A decode that started before the target shrank lands oversize
        // (nothing else would ask for a new one): run the window again.
        if let index = list.firstIndex(where: { $0.id == id }),
           Self.isOversize(entry, for: targetPixelSize(for: index) ?? effectiveMaxLongEdge) {
            schedule(around: currentIndex)
        }
    }

    // MARK: - Target size

    /// Returns the preferred pixel size for an index. Large images decode
    /// at 2x display long edge on the fast path to keep allocations
    /// predictable.
    ///
    /// Clamps to the source's own longer edge on cache hit — ImageIO
    /// emits `createThumbnailAtIndex: ... is larger than image-dimension`
    /// and wastes CPU on its "requested larger than source" path
    /// whenever `kCGImageSourceThumbnailMaxPixelSize` exceeds the
    /// source's longer edge.
    ///
    /// On cache miss: returns the unclamped request as a fallback (one
    /// ImageIO warning will fire, the same as the old behaviour) AND
    /// launches a fire-and-forget header probe so the next call for
    /// this source returns the clamped value.
    ///
    /// Marked `internal` rather than `private` so tests can drive it
    /// directly without routing through a full navigation burst.
    func targetPixelSize(for index: Int) -> Int? {
        guard list.indices.contains(index) else { return nil }
        // The user's "max display size" preference (Performance tab,
        // default 4096) — it was never wired, and the old `4096 * 2`
        // decoded 8K for every image. Upright JPEG/HEIC then decode at a
        // power-of-two subsample >= this (FileImageSource fast path).
        let unclamped = effectiveMaxLongEdge
        let key = list[index].id

        if let dims = dimensionCache[key] {
            touchLRU(key: key)
            let longEdge = max(dims.width, dims.height)
            // Guard against degenerate header reads that returned 0×0:
            // return the unclamped request rather than asking ImageIO
            // for a 0-pixel thumbnail.
            guard longEdge > 0 else { return unclamped }
            return min(unclamped, longEdge)
        }

        // Cache miss — spawn probe for next time, return unclamped now.
        spawnDimensionProbe(for: list[index])
        return unclamped
    }

    /// Seeds the dimension cache synchronously. Test seam — production
    /// code only populates via the header-probe path in
    /// `spawnDimensionProbe`.
    func seedDimensionCache(id: String, width: Int, height: Int) {
        installDimensions(id: id, width: width, height: height)
    }

    /// Exposed for tests that need to observe whether an entry landed.
    func dimensionCacheCount() -> Int { dimensionCache.count }
    func dimensionCacheContains(id: String) -> Bool { dimensionCache[id] != nil }

    /// Fire-and-forget header probe. Idempotent per source id — if a
    /// probe is already in flight for this id, we skip. The probe
    /// calls `loadProperties()` (header-only, 2-4 ms)
    /// and installs the result.
    private func spawnDimensionProbe(for source: any ImageSource) {
        let key = source.id
        if dimensionCache[key] != nil { return }
        if dimensionProbesInFlight.contains(key) { return }
        dimensionProbesInFlight.insert(key)

        Task { [weak self] in
            // Probe off-actor — `loadProperties` does file I/O.
            let dims: (width: Int, height: Int)? = await {
                do {
                    let props = try await source.loadProperties()
                    // Match the orientation swap used in
                    // `FilmstripView.ioAspect`: orientations 5-8 swap
                    // width/height relative to the container's pixel
                    // counts. We want the post-orientation longer edge
                    // because that's what the decoded CGImage will
                    // present (ImageIO's thumbnail path honours the
                    // `WithTransform` flag we pass).
                    let o = props.orientation.rawValue
                    let swap = (5...8).contains(o)
                    let w = swap ? props.pixelHeight : props.pixelWidth
                    let h = swap ? props.pixelWidth  : props.pixelHeight
                    return (w, h)
                } catch {
                    return nil
                }
            }()

            await self?.completeDimensionProbe(key: key, dims: dims)
        }
    }

    private func completeDimensionProbe(
        key: String,
        dims: (width: Int, height: Int)?
    ) {
        dimensionProbesInFlight.remove(key)
        if let dims, dims.width > 0, dims.height > 0 {
            installDimensions(id: key, width: dims.width, height: dims.height)
        }
    }

    private func installDimensions(id: String, width: Int, height: Int) {
        if dimensionCache[id] == nil {
            dimensionLRU.append(id)
        } else {
            touchLRU(key: id)
        }
        dimensionCache[id] = (width, height)
        evictDimensionLRUIfNeeded()
    }

    private func touchLRU(key: String) {
        // Move `key` to the end of `dimensionLRU` (most-recent). Linear
        // scan is fine at cap 2000 for the access frequency (a few per
        // navigation) — if this ever becomes hot, swap for a doubly-
        // linked list + map.
        if let idx = dimensionLRU.firstIndex(of: key) {
            dimensionLRU.remove(at: idx)
        }
        dimensionLRU.append(key)
    }

    private func evictDimensionLRUIfNeeded() {
        while dimensionCache.count > Self.dimensionCacheCap,
              let oldest = dimensionLRU.first {
            dimensionLRU.removeFirst()
            dimensionCache.removeValue(forKey: oldest)
        }
    }

}
