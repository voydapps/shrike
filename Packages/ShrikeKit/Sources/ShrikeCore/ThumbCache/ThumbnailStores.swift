//
//  ThumbnailStores.swift
//  ShrikeCore
//
//  The pieces `ThumbnailCache` is built from:
//  - `ThumbnailMemoryLRU`: a true least-recently-used memory tier bounded by
//    bytes (and a count guard), behind a lock so the grid can read it
//    synchronously from the main thread.
//  - `ThumbnailDiskStore`: the HEIC disk tier. Reads decode immediately
//    (`ShouldCacheImmediately`) so the first draw on main is free; writes
//    run after the thumbnail was returned, on a narrow `.utility` queue,
//    and land atomically (temp file + rename).
//  - `ThumbnailDecodeExecutor`: on macOS 15+, blocking ImageIO work runs on
//    its own dispatch queue instead of the Swift cooperative pool, so a
//    full set of decode slots never starves the rest of the app.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - Memory tier (LRU by bytes)

final class ThumbnailMemoryLRU: @unchecked Sendable {

    private final class Node {
        let key: String
        var image: CGImage
        var cost: Int
        weak var prev: Node?
        var next: Node?
        var resourceLease: ImageResourceLease
        init(key: String, image: CGImage, cost: Int, resourceLease: ImageResourceLease) {
            self.key = key
            self.image = image
            self.cost = cost
            self.resourceLease = resourceLease
        }
    }

    let byteLimit: Int
    let countLimit: Int
    private let resources: ImageResourceBudget
    private let owner: ImageResourceOwner

    // Guarded by `lock`.
    private var nodes: [String: Node] = [:]
    private var head: Node?   // most recent
    private var tail: Node?   // least recent
    private var bytes = 0
    private let lock = NSLock()

    init(byteLimit: Int, countLimit: Int, resources: ImageResourceBudget = .shared, owner: ImageResourceOwner = .init()) {
        self.byteLimit = max(1, byteLimit)
        self.countLimit = max(1, countLimit)
        self.resources = resources; self.owner = owner
    }

    /// Bytes an image pins in memory (its backing store estimate).
    static func cost(of image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
    }

    func get(_ key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[key] else { return nil }
        moveToFront(node)
        return node.image
    }

    func set(_ image: CGImage, for key: String) {
        let cost = Self.cost(of: image)
        lock.lock(); defer { lock.unlock() }
        if let node = nodes[key] {
            bytes += cost - node.cost
            node.image = image
            node.resourceLease = resources.retain(image: image, owner: owner, category: .thumbnail)
            node.cost = cost
            moveToFront(node)
        } else {
            let node = Node(key: key, image: image, cost: cost,
                            resourceLease: resources.retain(image: image, owner: owner, category: .thumbnail))
            nodes[key] = node
            bytes += cost
            insertAtFront(node)
        }
        while (bytes > byteLimit || nodes.count > countLimit), let last = tail, last !== head {
            remove(last)
        }
    }

    /// Removes every entry whose key starts with `keyPrefix`.
    func removeAll(keyPrefix: String) {
        lock.lock(); defer { lock.unlock() }
        for node in nodes.values where node.key.hasPrefix(keyPrefix) { remove(node) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        nodes.removeAll()
        head = nil
        tail = nil
        bytes = 0
    }

    var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var count: Int { lock.lock(); defer { lock.unlock() }; return nodes.count }

    // MARK: List (lock held)

    private func insertAtFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func remove(_ node: Node) {
        unlink(node)
        nodes[node.key] = nil
        bytes -= node.cost
    }
}

// MARK: - Disk tier (HEIC)

final class ThumbnailDiskStore: @unchecked Sendable {

    /// Pending writes beyond this are dropped (it's a cache): a fast scroll
    /// through 10 000 files must not hold 10 000 decoded thumbnails.
    static let maxPendingWrites = 96

    let root: URL
    private let queue: OperationQueue
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let resources: ImageResourceBudget
    private let resourceOwner = ImageResourceOwner()
    private let byteDelta = OSAllocatedUnfairLock<Int64>(initialState: 0)
    var changedBytes: Int64 { byteDelta.withLock { $0 } }

    init(root: URL, writeConcurrency: Int = 2, resources: ImageResourceBudget = .shared) {
        self.root = root
        self.resources = resources
        let queue = OperationQueue()
        queue.name = "app.shrike.thumbs.write"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, writeConcurrency)
        self.queue = queue
    }

    /// Decoded (not lazy) image, or nil when the file is missing or bad.
    /// `ShouldCacheImmediately` makes ImageIO decode here, off the main
    /// thread, instead of on the first draw.
    static func read(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
        ]
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    /// Queues an HEIC write of `image` to `url`. Returns false when the
    /// write was dropped because too many are pending.
    @discardableResult
    func enqueueWrite(_ image: CGImage, to url: URL) -> Bool {
        guard isAvailable else { return false }
        let accepted = pending.withLock { count -> Bool in
            guard count < Self.maxPendingWrites else { return false }
            count += 1
            return true
        }
        guard accepted else { return false }
        acceptedTotal.withLock { $0 += 1 }
        let payload = OSAllocatedUnfairLock<(image: UncheckedImage, lease: ImageResourceLease)?>(initialState:
            (UncheckedImage(image), resources.retain(image: image, owner: resourceOwner, category: .thumbnail)))
        let gen = generation.withLock { $0 }
        let token = targets.withLock { state -> UInt64 in
            state.next &+= 1
            state.live[url] = state.next
            return state.next
        }
        queue.addOperation { [pending, generation, targets, byteDelta] in
            // BlockOperation may retain its completed closure after a later
            // barrier resumes. Transfer the payload out of that capture so
            // real image ownership and its lease end with the work itself.
            let write = payload.withLock { value in let write = value; value = nil; return write }
            if let write, generation.withLock({ $0 }) == gen {
                defer { withExtendedLifetime(write.lease) {} }
                // The final rename happens under the `targets` lock, and only
                // while this write is still wanted, so `cancelPendingWrites(
                // namePrefix:)` + a delete can never be overtaken by a write.
                Self.writeAtomically(write.image.image, to: url) { commit in
                    // `withLockUnchecked`: the body captures the non-Sendable
                    // `commit` closure, and runs synchronously on this thread
                    // while the lock is held, so nothing crosses threads.
                    targets.withLockUnchecked { state -> Bool in
                        guard state.live[url] == token, state.available, generation.withLock({ $0 }) == gen else { return false }
                        state.live[url] = nil
                        let oldBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        let result = commit()
                        if result {
                            state.committed[url] = token
                            let newBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            byteDelta.withLock { $0 += newBytes - oldBytes }
                        }
                        return result
                    }
                }
            }
            // Encode failures and skipped writes leave no entry behind.
            targets.withLock { state in if state.live[url] == token { state.live[url] = nil } }
            pending.withLock { $0 -= 1 }
        }
        return true
    }

    /// Pending writes whose file name starts with `namePrefix` are skipped
    /// (a file was deleted, renamed or saved: `ThumbnailCache.evict`).
    func cancelPendingWrites(namePrefix: String) {
        targets.withLock { state in
            for url in state.live.keys where url.lastPathComponent.hasPrefix(namePrefix) {
                state.live[url] = nil
            }
        }
    }

    private struct Targets {
        var next: UInt64 = 0
        /// Final URL → token of the newest write queued for it.
        var live: [URL: UInt64] = [:]
        var committed: [URL: UInt64] = [:]
        var available = true
        var tombstones: [URL] = []
    }
    private let targets = OSAllocatedUnfairLock(initialState: Targets())

    var pendingWrites: Int { pending.withLock { $0 } }

    /// How many writes were accepted since this store was created. The
    /// cache compares it between disk trims: unchanged means nothing grew.
    private let acceptedTotal = OSAllocatedUnfairLock(initialState: 0)
    var acceptedWrites: Int { acceptedTotal.withLock { $0 } }

    /// Resumes once every write queued so far has finished.
    func waitUntilIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.addBarrierBlock { cont.resume() }
        }
    }

    // Deterministically retain a completed operation in lifetime tests.
    func setWritesSuspendedForTesting(_ suspended: Bool) { queue.isSuspended = suspended }
    var operationsForTesting: [Operation] { queue.operations }

    /// Writes queued before this call are skipped ("Clear cache").
    func cancelPendingWrites() {
        generation.withLock { $0 &+= 1 }
        targets.withLock { $0.live.removeAll() }
    }

    var isAvailable: Bool { targets.withLock { $0.available } }
    var maintenanceToken: (epoch: Int, sequence: UInt64) {
        targets.withLock { state in (generation.withLock { $0 }, state.next) }
    }
    func beginClear() {
        targets.withLock { state in
            state.available = false; state.live.removeAll()
            generation.withLock { $0 &+= 1 }
        }
    }
    /// Only root rename/create holds the commit gate; recursive cleanup
    /// occurs afterwards on the utility worker.
    func rotateRoot() throws -> [URL] {
        try targets.withLock { state in
            let fm = FileManager.default
            if fm.fileExists(atPath: root.path) {
                let tombstone = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).clearing.\(UUID().uuidString)")
                try fm.moveItem(at: root, to: tombstone)
                state.tombstones.append(tombstone)
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            state.committed.removeAll(); state.available = true
            return state.tombstones
        }
    }
    func removeTombstones(_ urls: [URL]) throws {
        for url in urls {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            targets.withLock { $0.tombstones.removeAll { $0 == url } }
        }
    }
    func removeFile(_ url: URL, token: (epoch: Int, sequence: UInt64)) -> Bool {
        targets.withLock { state in
            guard state.available, generation.withLock({ $0 }) == token.epoch,
                  (state.committed[url] ?? 0) <= token.sequence else { return false }
            do {
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try FileManager.default.removeItem(at: url); state.committed[url] = nil
                byteDelta.withLock { $0 -= bytes }; return true
            }
            catch { return false }
        }
    }

    /// Encode to a hidden temp file in the same folder, then `rename(2)`
    /// over the final name, so a reader never sees a half-written file.
    /// `commitGate` wraps the final rename: it runs the closure it is given
    /// (which renames and returns success) or returns false to discard.
    static func writeAtomically(_ image: CGImage, to url: URL,
                                commitGate: ((() -> Bool) -> Bool)? = nil) {
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let tmp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            return
        }
        let commit = { rename(tmp.path, url.path) == 0 }
        let committed = commitGate.map { $0(commit) } ?? commit()
        if !committed {
            try? fm.removeItem(at: tmp)
        }
    }
}

/// `CGImage` is immutable and thread-safe; this only carries one into an
/// `OperationQueue` block under strict concurrency.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

// MARK: - Decode executor (macOS 15+)

/// Runs thumbnail jobs on a private concurrent dispatch queue. ImageIO
/// calls block their thread for 40–60 ms; on the cooperative pool (one
/// thread per core) a full set of decode slots would stall every other
/// task in the app. The slot semaphore in `ThumbnailCache` still bounds
/// how many run at once.
@available(macOS 15.0, *)
final class ThumbnailDecodeExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.shrike.thumbs.decode",
                                      qos: .userInitiated, attributes: .concurrent)

    static let shared = ThumbnailDecodeExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority)
        let unowned = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async(qos: qos) { unowned.runSynchronously(on: executor) }
    }

    private static func qos(for priority: JobPriority) -> DispatchQoS {
        switch priority.rawValue {
        case TaskPriority.userInitiated.rawValue...: return .userInitiated
        case TaskPriority.medium.rawValue...: return .default
        case TaskPriority.utility.rawValue...: return .utility
        default: return .background
        }
    }
}

// MARK: - Key stem memo

/// Session memo for `ThumbnailCache.keyStem`: (file, mtime, size) -> the 24
/// hex chars of the cache key. Thread-safe; bounded (cleared when full).
final class KeyStemMemo: @unchecked Sendable {
    static let shared = KeyStemMemo()

    struct Key: Hashable {
        let url: URL?
        let id: String?
        let mtimeBits: UInt64
        let size: Int64

        init(source: any ImageSource) {
            if let file = source as? FileImageSource {
                url = file.url
                id = nil
            } else {
                url = nil
                id = source.id
            }
            mtimeBits = source.mtime.map { $0.timeIntervalSince1970.bitPattern } ?? 0
            size = source.fileSize ?? 0
        }
    }

    private let limit = 200_000
    private var map: [Key: String] = [:]
    private let lock = NSLock()

    func get(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    func set(_ stem: String, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if map.count >= limit { map.removeAll(keepingCapacity: true) }
        map[key] = stem
    }
}

// MARK: - Request sizes

/// Which pixel size a cell asks the cache for.
public enum ThumbnailSizing {
    /// Cell size in points x the screen scale, rounded up to a multiple of
    /// 64 and capped at 1024. The rounding keeps a continuous size slider
    /// from creating a new cache file for every point value, and the cap
    /// keeps the cache entry small for the largest grid size.
    public static func requestPixels(points: Int, scale: CGFloat) -> Int {
        let raw = Double(max(1, points)) * Double(max(1, scale))
        let bucket = 64
        let rounded = Int((raw / Double(bucket)).rounded(.up)) * bucket
        return min(1024, max(bucket, rounded))
    }
}
