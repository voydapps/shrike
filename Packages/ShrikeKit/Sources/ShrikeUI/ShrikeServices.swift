//
//  ShrikeServices.swift
//  ShrikeUI
//
//  Service locator passed into every viewer/browser window. Holds references
//  to the actors owned by the application.
//
//  The viewer calls the full `DecodeQueue` API (setNavigation /
//  advance / retreat / jumpTo / current / prefetch / loadFullRes)
//  directly. `NavigationController` is a thin convenience that produces
//  `(image, index)` tuples so `ViewerWindow` doesn't have to re-fetch the
//  index state after every navigation call.
//

import Foundation
import ShrikeCore
import ShrikeRendering
import ShrikeIO
import CoreGraphics
import ImageIO

/// Call first thing in `main`. Builds the
/// viewer's Metal device, shader library and pipelines on a background
/// thread while AppKit starts, so the first viewer window does not
/// compile shaders on the main thread (measured 250 ms).
public enum ViewerWarmUp {
    public static func start() {
        MetalPipelines.warmUp()
        DisplayTextureFactory.warmUp()
    }
}

/// The bundle of actors the UI depends on. Sendable — callers are free to
/// pass it across actor boundaries.
///
/// `Prefs` intentionally isn't a member: the current scaffold's `Prefs`
/// isn't `Sendable`, and it's a lightweight wrapper over `UserDefaults.standard`
/// that any caller can construct locally. Add a `prefs` field here once
/// Prefs gains a `Sendable` conformance.
public struct ShrikeServices: Sendable {
    public let thumbnailCache: ThumbnailCache
    public let metadataStore: MetadataStore
    /// Edit backups. Nil in tests: no pencil marks, no
    /// backup reads under the user's Application Support.
    public var backupStore: BackupStore?

    public init(
        thumbnailCache: ThumbnailCache,
        metadataStore: MetadataStore
    ) {
        self.thumbnailCache = thumbnailCache
        self.metadataStore = metadataStore
    }

    /// Every viewer (and compare) window gets its
    /// OWN decode queue — a shared one let window B's list replace window
    /// A's, so A showed B's photos. The queue reads the max-long-edge pref
    /// until the window sets its real screen size (`setMaxLongEdge`).
    /// `preparer` builds GPU textures for prefetched neighbours.
    public func makeDecodeQueue(preparer: DisplayPreparer? = nil) -> DecodeQueue {
        DecodeQueue(preparer: preparer)
    }

    public func makeDisplayDecodeQueue() -> DecodeQueue {
        let owner = ImageResourceOwner()
        return DecodeQueue(preparer: DisplayTextureFactory.preparer(resources: .shared, owner: owner), resourceOwner: owner)
    }

    /// Convenience factory for top-level app code — wires default actors.
    /// Lays out caches and metadata under the standard
    /// `~/Library/Application Support/app.shrike/` and
    /// `~/Library/Caches/app.shrike/` paths. Under XCTest both
    /// live in a per-process temp folder instead (`ShrikeDataPaths`), so
    /// tests never touch the user's real database or cache.
    public static func makeDefault() -> ShrikeServices {
        makeDefault(storagePaths: .defaults)
    }

    /// Resolved factory inputs; tests can obstruct disposable paths without
    /// disturbing another service's open database in this process.
    struct StoragePaths: Sendable {
        let thumbnails: URL
        let metadata: URL
        let thumbnailFallback: URL
        let metadataFallback: URL

        static var defaults: Self {
            Self(applicationSupport: ShrikeDataPaths.applicationSupport, caches: ShrikeDataPaths.caches,
                 fallbackDirectory: ShrikeDataPaths.fallbackDirectory)
        }

        init(applicationSupport: URL, caches: URL, fallbackDirectory: URL) {
            thumbnails = caches.appendingPathComponent("thumbs", isDirectory: true)
            metadata = applicationSupport.appendingPathComponent("metadata.sqlite")
            thumbnailFallback = fallbackDirectory.appendingPathComponent("shrike-thumbs-fallback", isDirectory: true)
            metadataFallback = fallbackDirectory.appendingPathComponent("shrike-metadata-fallback.sqlite")
        }
    }

    static func makeDefault(storagePaths: StoragePaths) -> ShrikeServices {

        // Init paths that can throw. If they fail (sandbox quirks, disk full),
        // use temporary storage so the app still launches — the user just
        // won't get persistence. Under XCTest, temporary fallbacks remain
        // inside the guarded test root. Log failures for Instruments.
        let thumbCache: ThumbnailCache
        do {
            // The user's ceiling from the start; the
            // Thumbnails tab applies changes with `setDiskCeiling`.
            thumbCache = try ThumbnailCache(diskURL: storagePaths.thumbnails,
                                            diskCeilingBytes: Prefs.cacheDiskCeilingBytes)
        } catch {
            ShrikeSignposts.thumbnail.event("initFailed", "\(error.localizedDescription)")
            // Force a second attempt at the tmp path — if that fails too,
            // we genuinely can't run.
            thumbCache = (try? ThumbnailCache(diskURL: storagePaths.thumbnailFallback))
                ?? {
                    fatalError("ThumbnailCache init failed everywhere: \(error)")
                }()
        }

        // A non-persistent fallback is flagged on the store
        // (`isPersistent == false`, `openError`) so the UI can warn.
        let metaStore = MetadataStore.openWithFallback(primary: storagePaths.metadata,
                                                     fallback: storagePaths.metadataFallback)

        // `backupStore` stays nil here: the app sets `.shared` (tests use
        // makeDefault too and must not read the user's backup index).
        return ShrikeServices(
            thumbnailCache: thumbCache,
            metadataStore: metaStore
        )
    }
}

// MARK: - NavigationController

/// Convenience wrapper around `DecodeQueue` that returns `(image, index)`
/// tuples so `ViewerWindow` navigation is a one-liner.
///
/// `DecodeQueue` already owns list + index state (via `setNavigation`),
/// but it returns either `CGImage` or `(image, index)` inconsistently
/// (`advance`/`retreat` return tuples, `jumpTo` returns just the image
/// and relies on the caller to know `index`). This shim flattens that
/// into a uniform `(CGImage, Int)` return type + adds a "sourceAt" lookup
/// the filmstrip needs without having to keep its own copy of the list.
public actor NavigationController {

    public enum Error: Swift.Error, Sendable {
        case emptyList
        case outOfRange
        case decodeFailed
    }

    private let queue: DecodeQueue
    private let thumbnailCache: ThumbnailCache?
    private var sources: [any ImageSource] = []
    private var currentIndex: Int = 0

    public init(queue: DecodeQueue, thumbnailCache: ThumbnailCache? = nil) {
        self.queue = queue
        self.thumbnailCache = thumbnailCache
    }

    /// Fetch a thumbnail for `index` from the shared `ThumbnailCache`.
    /// Returns nil when no cache is wired (tests, legacy callers), when
    /// the index is out of range, or when the thumbnail lookup throws
    /// (unsupported format, disk error). Never blocks longer than the
    /// cache's internal decode takes — memory tier is near-instant, disk
    /// tier is ~20 ms for a 1024 px HEIC.
    public func thumbnail(at index: Int, maxPixelSize: Int) async -> CGImage? {
        guard let cache = thumbnailCache else { return nil }
        guard sources.indices.contains(index) else { return nil }
        let source = sources[index]
        return try? await cache.thumbnail(for: source, maxPixelSize: maxPixelSize)
    }

    /// Fetch the source's **embedded preview** for `index` — the
    /// camera-instant path. Bypasses the ThumbnailCache entirely; the
    /// embedded preview lives in the source container and ImageIO can
    /// return it in 10-30 ms without decoding the full image.
    ///
    /// Returns `nil` when:
    ///   - the index is out of range,
    ///   - the underlying source has no embedded preview (small JPGs,
    ///     non-camera-out files, formats that don't support previews),
    ///   - or the read throws (file gone, disk fault) — silently, since
    ///     this is a best-effort fast path. The viewer falls through to
    ///     the ThumbnailCache bridge in any of these cases.
    public func embeddedPreview(at index: Int) async -> CGImage? {
        guard sources.indices.contains(index) else { return nil }
        let source = sources[index]
        return try? await source.loadEmbeddedPreview()
    }

    public func setNavigation(list: [any ImageSource], currentIndex: Int) async {
        trimmed = false
        self.sources = list
        self.currentIndex = list.isEmpty ? 0 : max(0, min(currentIndex, list.count - 1))
        await queue.setNavigation(list: list, currentIndex: self.currentIndex)
    }

    public func count() -> Int { sources.count }

    /// True after `trimToCurrent()` until the next navigation.
    private var trimmed = false

    /// A hidden viewer drops every cached decode. The
    /// on-screen texture lives in the view, so the photo stays visible;
    /// the list is kept and handed back to the queue on the next jump.
    public func trimToCurrent() async {
        await queue.purge()
        trimmed = true
    }

    private func restoreIfTrimmed() async {
        guard trimmed else { return }
        trimmed = false
        await queue.setNavigation(list: sources, currentIndex: currentIndex)
    }

    /// The window closed: forget the list and empty the decode queue.
    public func teardown() async {
        sources = []
        currentIndex = 0
        await queue.purge()
    }

    /// The window's own decode queue.
    public nonisolated var decodeQueue: DecodeQueue { queue }

    /// Like `jump(to:)`, but returns the full decoded entry (file id and
    /// the GPU-ready texture, when the queue has a preparer).
    public func jumpEntry(to index: Int) async throws -> DecodedImage {
        guard sources.indices.contains(index) else { throw Error.outOfRange }
        await restoreIfTrimmed()
        do {
            let entry = try await queue.jumpToEntry(index: index)
            currentIndex = index
            return entry
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.decodeFailed
        }
    }

    /// The current photo's finished entry for the file
    /// `sourceID`, read without an actor hop (`DecodeQueue.readyEntry`).
    public nonisolated func readyEntryNow(sourceID: String) -> DecodedImage? {
        queue.readyEntry(sourceID: sourceID)
    }

    /// Ready (cached) entry for `index`, or nil. Never starts a decode.
    public func cachedEntry(at index: Int) async -> DecodedImage? {
        await queue.cachedEntry(at: index)
    }
    /// Swipe fallback: decode `index` first and wait for it
    /// (the current photo stays). Nil on failure.
    public func prioritizeNeighbour(at index: Int) async -> DecodedImage? {
        guard sources.indices.contains(index) else { return nil }
        await restoreIfTrimmed()
        return await queue.prioritizeNeighbour(at: index)
    }
    public func index() -> Int { currentIndex }

    public func currentSource() -> (any ImageSource)? {
        guard sources.indices.contains(currentIndex) else { return nil }
        return sources[currentIndex]
    }

    public func sourceAt(_ index: Int) -> (any ImageSource)? {
        guard sources.indices.contains(index) else { return nil }
        return sources[index]
    }

    public func current() async -> CGImage? {
        await queue.current()
    }

    public func advance() async throws -> (image: CGImage, index: Int) {
        guard !sources.isEmpty else { throw Error.emptyList }
        do {
            let result = try await queue.advance()
            currentIndex = result.index
            return result
        } catch is CancellationError {
            // Supersession — a newer nav request has taken over. Let
            // the viewer's catch path recognise it as routine (no
            // error overlay) rather than mapping it to `.decodeFailed`.
            throw CancellationError()
        } catch {
            throw Error.decodeFailed
        }
    }

    public func retreat() async throws -> (image: CGImage, index: Int) {
        guard !sources.isEmpty else { throw Error.emptyList }
        do {
            let result = try await queue.retreat()
            currentIndex = result.index
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.decodeFailed
        }
    }

    public func jump(to index: Int) async throws -> (image: CGImage, index: Int) {
        guard sources.indices.contains(index) else { throw Error.outOfRange }
        do {
            let image = try await queue.jumpTo(index: index)
            currentIndex = index
            return (image, index)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Error.decodeFailed
        }
    }
}
