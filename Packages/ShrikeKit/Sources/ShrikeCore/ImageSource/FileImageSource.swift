//
//  FileImageSource.swift
//  ShrikeCore
//
//  ImageSource backed by a file URL on disk — the common case.
//  Honors the exact `CGImageSource` flag combination used for thumbnails.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct FileImageSource: ImageSource {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: Identity

    public var id: String { url.absoluteString }
    public var displayName: String { url.lastPathComponent }

    public var fileSize: Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    public var mtime: Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    // MARK: Decode

    /// `CGImageSourceCreateImageAtIndex` + `SubsampleFactor` for upright
    /// images: 3–6x faster than `CreateThumbnailAtIndex` at display sizes.
    /// Returns nil (caller uses the thumbnail path) when the image needs
    /// an EXIF rotation, or when the codec may ignore SubsampleFactor and
    /// the source is more than 2x the target (so output never balloons).
    static func fastUprightDecode(_ src: CGImageSource, target: Int) -> CGImage? {
        guard let factor = fastUprightSubsample(src, target: target) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        if factor > 1 { opts[kCGImageSourceSubsampleFactor] = factor }
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    /// Subsample factor the fast path uses for `src`, or nil when the
    /// fast path does not apply.
    static func fastUprightSubsample(_ src: CGImageSource, target: Int) -> Int? {
        guard target > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard orientation == 1 else { return nil }
        let type = (CGImageSourceGetType(src) as String?) ?? ""
        let subsamples = ["public.jpeg", "public.heic", "public.heif"].contains(type)
        let longEdge = max(w, h)
        guard subsamples || (["public.png", "public.tiff"].contains(type) && longEdge <= target * 2) else {
            return nil
        }
        var factor = 1
        if subsamples {
            while factor < 8 && longEdge / (factor * 2) >= target { factor *= 2 }
        }
        return factor
    }

    /// The same image as `decodeDisplayImage`,
    /// but LAZY — no pixels are decoded until something draws it on the
    /// CPU (loupe, edit mode, copy), and then they stay cached in this
    /// CGImage only. Once the GPU texture of a neighbour exists, the
    /// decode queue swaps the eager CGImage for this twin, so a cached
    /// photo costs its texture only, not texture + CPU pixels.
    /// Returns nil when the fast path does not apply (rotated images,
    /// other formats): those keep their eager CGImage.
    public func lazyDisplayImage(targetLongEdge: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let factor = Self.fastUprightSubsample(src, target: targetLongEdge)
        else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceShouldCache: true]
        if factor > 1 { opts[kCGImageSourceSubsampleFactor] = factor }
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    /// A rotated file's stored pixels (EXIF orientation NOT applied yet),
    /// decoded on the fast subsampled path. See `decodeRotatedStoredFrame`.
    public struct RotatedStoredFrame: @unchecked Sendable {
        /// Stored (unrotated) pixels, decoded now. Immutable.
        public let image: CGImage
        /// EXIF orientation (2-8) to apply for display.
        public let orientation: CGImagePropertyOrientation
        /// The file's full pixel size AFTER orientation.
        public let orientedWidth: Int
        public let orientedHeight: Int
    }

    /// For a JPEG / HEIC with EXIF orientation
    /// 2-8, the stored pixels decoded with `CreateImageAtIndex` +
    /// `SubsampleFactor` (the fast display path, ~45 ms for 18 MP) instead
    /// of `CreateThumbnailAtIndex` + `WithTransform` (150-280 ms at
    /// 4096 px). The caller applies `orientation` itself (on the GPU).
    /// Nil for upright files and other formats. Blocks: decode lane only.
    public func decodeRotatedStoredFrame(targetLongEdge: Int) throws -> RotatedStoredFrame? {
        try checkMaterialized()
        guard targetLongEdge > 0,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              ["public.jpeg", "public.heic", "public.heif"]
                .contains((CGImageSourceGetType(src) as String?) ?? ""),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0,
              let raw = props[kCGImagePropertyOrientation] as? UInt32, (2...8).contains(raw),
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return nil }
        let longEdge = max(w, h)
        var factor = 1
        while factor < 8 && longEdge / (factor * 2) >= targetLongEdge { factor *= 2 }
        var opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        if factor > 1 { opts[kCGImageSourceSubsampleFactor] = factor }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let turns = raw >= 5   // EXIF 5-8 turn the image by 90 degrees
        return RotatedStoredFrame(image: image, orientation: orientation,
                                  orientedWidth: turns ? h : w, orientedHeight: turns ? w : h)
    }

    /// Lazy CPU twin for a rotated file's display texture: the image
    /// `decodeDisplayImage` returns for it (thumbnail + transform at
    /// `targetLongEdge`), but nothing is decoded until something reads the
    /// pixels (loupe, edit mode, copy); then they are kept in this CGImage
    /// only, like `lazyDisplayImage`. Nil unless `frame` is 8-bit RGB or
    /// grey (the caller then keeps the eager path).
    public func lazyOrientedDisplayImage(frame: RotatedStoredFrame, targetLongEdge: Int) -> CGImage? {
        let stored = frame.image
        guard targetLongEdge > 0, stored.bitsPerComponent == 8,
              !stored.bitmapInfo.contains(.floatComponents),
              let space = stored.colorSpace else { return nil }
        let long = max(frame.orientedWidth, frame.orientedHeight)
        let scale = Double(min(targetLongEdge, long)) / Double(long)
        let width = max(1, Int((Double(frame.orientedWidth) * scale).rounded()))
        let height = max(1, Int((Double(frame.orientedHeight) * scale).rounded()))
        let file = self
        return LazyOrientedPixels.makeImage(
            width: width, height: height, space: space,
            decode: { try? file.decodeImage(maxPixelSize: targetLongEdge) }
        )
    }

    /// Lazy CPU twin for an eager thumbnail-path decode (`decodeImage`):
    /// the same size and colour space as `eager`, decoded again on the
    /// first pixel read. Nil (keep the eager image) unless `eager` is
    /// opaque 8-bit RGB / grey: the twin's pixel format has no alpha.
    public func lazyReloadImage(like eager: CGImage, targetLongEdge: Int) -> CGImage? {
        guard targetLongEdge > 0, eager.bitsPerComponent == 8,
              !eager.bitmapInfo.contains(.floatComponents),
              let space = eager.colorSpace else { return nil }
        switch eager.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default: return nil
        }
        let file = self
        return LazyOrientedPixels.makeImage(
            width: eager.width, height: eager.height, space: space,
            decode: { try? file.decodeImage(maxPixelSize: targetLongEdge) }
        )
    }

    /// Formats whose thumbnails take `fastThumbnail`. Empty on purpose:
    /// measured (release, 96 × 12 MP, M-series), the fast path
    /// LOST for every format. Cold thumbs/s, old → fast:
    ///   JPEG 74 → 19 (4 slots), 144 → 19 (8 slots)
    ///   HEIC 40 → 17 (4 slots),  40 → 17 (8 slots)
    ///   PNG / TIFF / GIF: slower or not subsampled at all (single call,
    ///   4000×3000 @ 256: PNG 92 → 183 ms, TIFF 16 → 29 ms; GIF ignores it).
    /// Throughput did not change with slot count, so the subsampled
    /// `CreateImageAtIndex` decode runs one at a time (likely the shared
    /// hardware decoder), while `CreateThumbnailAtIndex` decodes in
    /// software and scales with cores. Re-measure with
    /// `ThumbnailFastPathTests.testTiming_oldVsFast_perFormat` and
    /// `ThumbnailThroughputTests` before adding a type here.
    static let fastThumbnailTypes: Set<String> = []

    /// Formats `fastThumbnail` is correct for (tested for all 8 EXIF
    /// orientations), should one become faster.
    static let fastThumbnailCandidateTypes: Set<String> = ["public.jpeg", "public.heic", "public.heif"]

    /// Thumbnails up to this long edge take `fastThumbnail`; larger
    /// requests (rotated display decodes) keep the ImageIO path.
    static let fastThumbnailMaxEdge = 1024

    /// Thumbnail fast path: decode with `SubsampleFactor` at the largest
    /// power of two (≤ 8) that still keeps ≥ `maxPixelSize` on the long
    /// edge, then scale to exactly `maxPixelSize` and apply the EXIF
    /// orientation in one high-quality `CGContext` draw of the small image.
    /// Output size and orientation match the `CreateThumbnailAtIndex`
    /// path (short edge within 1 px). Not used today: see
    /// `fastThumbnailTypes`. Nil (caller uses that path) for other formats, larger
    /// requests, or a codec that ignored the factor.
    static func fastThumbnail(_ src: CGImageSource, props: [CFString: Any], maxPixelSize: Int,
                              types: Set<String> = fastThumbnailTypes) -> CGImage? {
        guard maxPixelSize > 0, maxPixelSize <= fastThumbnailMaxEdge,
              let type = CGImageSourceGetType(src) as String?, types.contains(type),
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let longEdge = max(w, h)
        let target = min(maxPixelSize, longEdge)
        var factor = 1
        while factor < 8 && longEdge / (factor * 2) >= target { factor *= 2 }
        var opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        if factor > 1 { opts[kCGImageSourceSubsampleFactor] = factor }
        guard let decoded = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // A codec that ignores the factor hands back the full image; the
        // scale would then cost more than ImageIO's own thumbnail.
        guard max(decoded.width, decoded.height) <= max(target, longEdge / factor + 1) * 2 else { return nil }

        // Stored-frame size of the result (short edge rounded to nearest).
        let scale = Double(target) / Double(longEdge)
        let sw = w >= h ? target : max(1, Int((Double(w) * scale).rounded()))
        let sh = w >= h ? max(1, Int((Double(h) * scale).rounded())) : target
        let out = OrientedDraw.displaySize(width: sw, height: sh, orientation: orientation)
        return OrientedDraw.render(decoded, orientation: orientation, outWidth: out.width,
                                   outHeight: out.height, keepDepth: false, quality: .high)
    }

    /// Viewer display decode. Upright images take the fast path
    /// (measured on an 18 MP JPEG, target 4096, median 50 ms vs
    /// 280 ms for the thumbnail path). The result can be up to 2x
    /// `targetLongEdge` (power-of-two subsample), so thumbnail callers
    /// that need a strict cap must use `loadCGImage(maxPixelSize:)`.
    /// Rotated / other images fall back to that path (WithTransform).
    public func loadDisplayCGImage(targetLongEdge: Int) async throws -> CGImage {
        try decodeDisplayImage(targetLongEdge: targetLongEdge)
    }

    /// Synchronous form of `loadDisplayCGImage`. Blocks the calling thread
    /// on ImageIO, so callers run it on a dedicated decode queue
    /// (`DecodeLane`), never on the Swift cooperative pool or main.
    public func decodeDisplayImage(targetLongEdge: Int) throws -> CGImage {
        try checkMaterialized()
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(src) > 0,
           let fast = Self.fastUprightDecode(src, target: targetLongEdge) {
            return fast
        }
        return try decodeImage(maxPixelSize: targetLongEdge)
    }

    public func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        try decodeImage(maxPixelSize: maxPixelSize)
    }

    // MARK: Full resolution (zoom past the display texture)

    /// Upright files only (EXIF orientation 1, RAW included): the full-size
    /// image, NOT decoded yet. Whoever reads its pixels first decodes it.
    /// Nil for rotated files (use `decodeFullResolution`).
    ///
    /// Measured (M-series, warm file cache, median of 5): a GPU
    /// texture built straight from this lazy image is the fastest way to a
    /// full-size texture — 18 MP JPEG 21–32 ms, 16 MP ORF 354 ms — while
    /// decoding first with `ShouldCacheImmediately` and then uploading
    /// costs 61 ms (JPEG) and 1.9 s (ORF: ImageIO's eager RAW render).
    ///
    /// - Parameter cacheDecoded: true keeps the pixels inside the CGImage
    ///   once decoded (a CPU twin for the loupe or edit mode); false lets
    ///   them go after each read (the texture source).
    public func uprightFullResolutionImage(cacheDecoded: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              ((props[kCGImagePropertyOrientation] as? UInt32) ?? 1) == 1
        else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: cacheDecoded] as CFDictionary)
    }

    /// How a rotated (EXIF 2–8) or RAW file is decoded at full size.
    enum FullResolutionPath: Sendable {
        /// `CreateThumbnailAtIndex` with `WithTransform` at the file's
        /// own long edge: ImageIO decodes and orients in one step.
        case thumbnailTransform
        /// `CreateImageAtIndex`, then a CPU draw that applies the
        /// orientation (`OrientedDraw`).
        case decodeThenDraw
    }

    /// Chosen by measurement (`SpeedBenchTests`, 18 MP JPEG
    /// with EXIF 6): thumbnail + transform 163 ms, decode + CPU draw 173 ms.
    static let rotatedFullResolutionPath: FullResolutionPath = .thumbnailTransform

    /// Every pixel of the file, EXIF orientation applied, decoded NOW on
    /// the calling thread (ImageIO's cache off, so nothing is kept after
    /// the caller drops the image). Blocks: call it on a decode lane.
    /// For a GPU texture of an upright file, `uprightFullResolutionImage`
    /// is faster (see there).
    ///
    /// - Upright files: `CreateImageAtIndex` + `ShouldCacheImmediately`.
    /// - Rotated files: `rotatedFullResolutionPath`; rotated RAW always
    ///   takes the thumbnail + transform path (slow: ~1.8 s for 16 MP).
    /// - `isCancelled` is polled between steps; a cancelled call throws
    ///   `CancellationError` (ImageIO itself can't be interrupted).
    public func decodeFullResolution(isCancelled: () -> Bool = { false }) throws -> CGImage {
        try decodeFullResolution(rotatedPath: Self.rotatedFullResolutionPath, isCancelled: isCancelled)
    }

    func decodeFullResolution(rotatedPath: FullResolutionPath,
                              isCancelled: () -> Bool = { false }) throws -> CGImage {
        try checkMaterialized()
        guard let src = CGImageSourceCreateWithURL(url as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageSourceError.cannotOpen }
        let status = CGImageSourceGetStatus(src)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw Self.statusToError(status)
        }
        guard CGImageSourceGetCount(src) > 0 else { throw ImageSourceError.unsupported }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let isRAW = ImageFormat(url: url) == .raw
        if isCancelled() { throw CancellationError() }

        let rotated = orientation != 1 && (2...8).contains(orientation)
        if !rotated {
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
                throw ImageSourceError.corrupt
            }
            return image
        }

        if rotatedPath == .thumbnailTransform || isRAW, width > 0, height > 0 {
            // Rotated RAW always takes this path: it matches the display
            // decode's orientation handling (not verified that ImageIO's
            // RAW `CreateImageAtIndex` output is stored-frame).
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw ImageSourceError.corrupt
            }
            return image
        }

        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let stored = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageSourceError.corrupt
        }
        guard rotated else { return stored }
        if isCancelled() { throw CancellationError() }
        let out = OrientedDraw.displaySize(width: stored.width, height: stored.height,
                                           orientation: orientation)
        guard let oriented = OrientedDraw.render(stored, orientation: orientation,
                                                 outWidth: out.width, outHeight: out.height,
                                                 keepDepth: true, quality: .none)
        else { throw ImageSourceError.corrupt }
        return oriented
    }

    /// Synchronous form of `loadCGImage` (same threading rule as
    /// `decodeDisplayImage`).
    public func decodeImage(maxPixelSize: Int?) throws -> CGImage {
        try checkMaterialized()

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // File is unreadable — permissions, missing, or ImageIO refused
            // the container outright.
            throw ImageSourceError.cannotOpen
        }
        // Must be able to read at least one image.
        let status = CGImageSourceGetStatus(src)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw Self.statusToError(status)
        }
        guard CGImageSourceGetCount(src) > 0 else {
            throw ImageSourceError.unsupported
        }

        if let size = maxPixelSize {
            // Clamp the thumbnail request to the source's longer edge so
            // ImageIO never emits `createThumbnailAtIndex: N is larger than
            // image-dimension: WxH`. The caller-side clamp in
            // `DecodeQueue.targetPixelSize(for:)` has a
            // cache-miss hole where it returns the unclamped request on
            // first-touch; doing the clamp here — where the CGImageSource
            // is already open — is both cheaper (one header read, ~2-4 ms
            // correct on the first call.
            //
            // If the header is unreadable (rare, corrupt container) fall
            // back to the raw request. The ImageIO warning is cosmetic;
            // decoding still succeeds.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let clamped: Int = {
                guard let props,
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0
                else { return size }
                return max(1, min(size, max(w, h)))
            }()

            // Subsampled decode + scale-and-orient draw, only for formats
            // in `fastThumbnailTypes` (none today: see that constant).
            if let props, let fast = Self.fastThumbnail(src, props: props, maxPixelSize: clamped) {
                return fast
            }

            // Thumbnail path — exact flag cocktail
            // (The viewer's display decode uses `loadDisplayCGImage`.)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: clamped,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw ImageSourceError.corrupt
            }
            return image
        } else {
            // Full-res path — ShouldCache=false so we own LRU.
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
                throw ImageSourceError.corrupt
            }
            return image
        }
    }

    // MARK: Embedded preview (camera-instant path)

    /// Read the container's embedded preview JPEG without decoding the
    /// full image. This is the same data path the camera body's LCD
    /// uses for "instant" image review:
    ///
    ///     5184 × 3888 source JPEG  ─▶ embedded 1920 × 1440 thumb (~10-30 ms)
    ///                                 vs. full decode (~80-200 ms)
    ///
    /// Why: navigating same-folder camera JPGs in Shrike felt
    /// noticeably slower than navigating the same files on the camera's
    /// own LCD. Reason: the camera shows the embedded preview through
    /// its DSP in <20 ms; we were decoding the full container through
    /// ImageIO + uploading to Metal + sRGB → linear-P3 every nav. The
    /// fix is the same trick the camera uses: paint the embedded preview
    /// first, then upgrade to full-res in the background.
    ///
    /// Returns `nil` (not `throws`) when the container exposes no
    /// embedded preview — the viewer treats that as "fast path
    /// unavailable, fall through to the ThumbnailCache bridge". Errors
    /// are reserved for genuine I/O / corruption faults.
    ///
    /// Flag cocktail (intentionally the inverse of `loadCGImage`'s
    /// thumbnail path):
    ///   * `kCGImageSourceCreateThumbnailFromImageAlways: false`
    ///       — read the EMBEDDED thumbnail, do NOT decode-and-shrink the
    ///         full image. This is the whole point of the call.
    ///   * `kCGImageSourceCreateThumbnailFromImageIfAbsent: false`
    ///       — do NOT fall back to a fresh full decode if no embedded
    ///         preview exists. Callers want a fast path or `nil`,
    ///         never a slow surprise.
    ///   * `kCGImageSourceCreateThumbnailWithTransform: true`
    ///       — apply EXIF orientation so the returned CGImage matches
    ///         what `loadCGImage` will eventually paint. Without this,
    ///         portrait shots flip when full-res lands.
    ///   * `kCGImageSourceThumbnailMaxPixelSize: embeddedPreviewMaxEdge`
    ///       — IMPORTANT non-obvious behavior: without a MaxPixelSize,
    ///         `CGImageSourceCreateThumbnailAtIndex` returns the FULL
    ///         image regardless of how the FromImage* flags are set —
    ///         even with `FromImageAlways: false` + `IfAbsent: false`.
    ///         The `MaxPixelSize` is what makes ImageIO actually consult
    ///         the embedded EXIF IFD1 / preview data block. Verified
    ///         empirically against both a fixture-with-preview and the
    ///         no-preview test fixtures; without it the function
    ///         returned 2048×2048 for every input. The chosen ceiling
    ///         (4096) is well above every camera's embedded-preview size
    ///         (Olympus 1920×1440, Sony 1616×1080, Canon 1620×1080,
    ///         Nikon 1616×1080, Fuji 1920×1280) so the embedded data is
    ///         returned at its native size — we never ask ImageIO to
    ///         shrink it further, which would defeat the speed win.
    ///   * `kCGImageSourceShouldCacheImmediately: true` /
    ///     `kCGImageSourceShouldCache: false`
    ///       — match the rest of the file: we own LRU through the decode
    ///         queue, ImageIO's internal cache fights us for budget.
    ///
    /// Concurrency: this is intentionally NOT throttled by the
    /// `ThumbnailCache.activeDecodes` semaphore.
    /// Embedded-preview reads finish in 10-30 ms, return small images
    /// (~3 MB IOSurface), and are released immediately when the full-res
    /// paint commits — the IOSurface storm failure mode that motivated
    /// that semaphore exists for does not apply. If profiling later shows otherwise
    /// (e.g. on burst nav across a ZIP-archive source), gate this call
    /// behind a small dedicated semaphore here rather than reusing the
    /// thumbnail cache's slot.
    public func loadEmbeddedPreview() async throws -> CGImage? {
        try checkMaterialized()

        // Format pre-gate: skip ImageIO entirely for containers that
        // cannot carry an embedded preview. PNG/GIF/BMP/WebP/AVIF/PSD/PDF
        // have no embedded-preview convention, so calling
        // `CGImageSourceCreateThumbnailAtIndex` with the embedded-only
        // flag pair (`FromImageAlways: false` + `FromImageIfAbsent: false`)
        // produces a `failed to create thumbnail [-50]` console log on
        // every nav even though the function correctly returns nil. The
        // gate makes the fast-path opt-in for formats that actually have
        // a preview to read (JPEG / HEIC / RAW / TIFF — the latter
        // intentionally permissive to cover RAW-in-TIFF containers like
        // DNG; see `ImageFormat.hasEmbeddedPreview`).
        if let format = ImageFormat(url: url), !format.hasEmbeddedPreview {
            return nil
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageSourceError.cannotOpen
        }
        // Same status guard as loadCGImage — incomplete is fine because
        // ImageIO can still emit the embedded preview from a partial read.
        let status = CGImageSourceGetStatus(src)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw Self.statusToError(status)
        }
        guard CGImageSourceGetCount(src) > 0 else {
            throw ImageSourceError.unsupported
        }

        // Read the source's full pixel dimensions to detect a degenerate
        // case: even with FromImage* both set to false, on some
        // images/versions ImageIO can return a thumbnail that is the
        // same size as the source (e.g. when the source IS small enough
        // to be its own preview). In that case the caller paid for a
        // full decode rather than a fast preview, so reject and let the
        // viewer fall through to the ThumbnailCache bridge instead. The
        // 95 % band absorbs ±N-pixel rounding inside EXIF IFD1 records
        // without ever passing for "I got a real fast preview".
        let (sourceWidth, sourceHeight): (Int, Int) = {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return (0, 0) }
            return (w, h)
        }()
        let sourceLongEdge = max(sourceWidth, sourceHeight)

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.embeddedPreviewMaxEdge,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            src, 0, opts as CFDictionary
        ) else {
            // ImageIO returned nil — no embedded preview exists. This is
            // the expected path for non-camera-out files, small JPGs,
            // PNGs, etc. Clean fall-through, NOT an error.
            return nil
        }

        // Defensive size check (see comment above).
        let thumbLongEdge = max(thumb.width, thumb.height)
        if sourceLongEdge > 0 {
            let ratio = Double(thumbLongEdge) / Double(sourceLongEdge)
            if ratio >= 0.95 {
                return nil
            }
        }
        return thumb
    }

    /// Cap on the embedded preview's longer edge. Above every camera's
    /// embedded-preview size (Olympus 1920×1440 is the largest in
    /// common use), so the preview is returned at its native dimensions
    /// rather than being shrunk by ImageIO. See `loadEmbeddedPreview`
    /// for why this constant is needed at all.
    static let embeddedPreviewMaxEdge: Int = 4096

    // MARK: Properties (header-only)

    public func loadProperties() async throws -> ImageProperties {
        try checkMaterialized()

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageSourceError.cannotOpen
        }
        guard CGImageSourceGetCount(src) > 0 else {
            throw ImageSourceError.unsupported
        }
        guard let raw = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ImageSourceError.corrupt
        }

        let pixelWidth = (raw[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (raw[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientationRaw = (raw[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let colorModel = raw[kCGImagePropertyColorModel] as? String
        let profileName = raw[kCGImagePropertyProfileName] as? String
        let colorSpaceName: String? = profileName ?? colorModel
        let bitDepth = raw[kCGImagePropertyDepth] as? Int
        let hasAlpha = (raw[kCGImagePropertyHasAlpha] as? Bool) ?? false

        let exif = Self.parseExif(raw)
        let utType = Self.resolveUTType(source: src, url: url)

        let fileSize: Int64 = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0

        return ImageProperties(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: orientation,
            colorSpaceName: colorSpaceName,
            bitDepth: bitDepth,
            hasAlpha: hasAlpha,
            exif: exif,
            utType: utType,
            fileSize: fileSize
        )
    }

    // MARK: - iCloud materialisation

    /// Throw `.needsDownload` if the backing URL is a not-yet-downloaded
    /// iCloud placeholder. Local files pass through silently.
    private func checkMaterialized() throws {
        // Resource may not expose this key at all for plain local files.
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey,
        ])
        guard let values else { return }
        // Not an iCloud item? Nothing to check.
        if values.isUbiquitousItem != true { return }
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current):          return           // fully materialized
        case .none:                    return           // local / unknown
        case .some(let status) where status == URLUbiquitousItemDownloadingStatus.current:
            return
        default:
            throw ImageSourceError.needsDownload
        }
    }

    private static func statusToError(_ status: CGImageSourceStatus) -> ImageSourceError {
        switch status {
        case .statusComplete, .statusIncomplete: return .cannotOpen
        case .statusReadingHeader:               return .corrupt
        case .statusUnknownType:                 return .unsupported
        case .statusInvalidData, .statusUnexpectedEOF: return .corrupt
        @unknown default:                        return .cannotOpen
        }
    }

    // MARK: - EXIF parsing

    private static func parseExif(_ raw: [CFString: Any]) -> ExifSummary? {
        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps  = raw[kCGImagePropertyGPSDictionary]  as? [CFString: Any] ?? [:]

        // DateTimeOriginal — EXIF format "yyyy:MM:dd HH:mm:ss"
        var dateTimeOriginal: Date?
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            dateTimeOriginal = Self.exifDateFormatter.date(from: s)
        }

        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        let lensModel = exif[kCGImagePropertyExifLensModel] as? String

        let fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        let shutter = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let iso: Int? = {
            if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
               let n = arr.first {
                return n.intValue
            }
            return nil
        }()
        let focal = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue

        // GPS — ImageIO stores positive magnitudes + N/S/E/W direction.
        let latMag = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue
        let lonMag = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        let latRef = gps[kCGImagePropertyGPSLatitudeRef]  as? String
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        let latitude  = latMag.map { latRef == "S" ? -$0 : $0 }
        let longitude = lonMag.map { lonRef == "W" ? -$0 : $0 }

        // If every field is nil, skip the payload entirely.
        let anyFieldSet = dateTimeOriginal != nil || make != nil || model != nil
            || lensModel != nil || fNumber != nil || shutter != nil || iso != nil
            || focal != nil || latitude != nil || longitude != nil
        guard anyFieldSet else { return nil }

        return ExifSummary(
            dateTimeOriginal: dateTimeOriginal,
            cameraMake: make,
            cameraModel: model,
            lensModel: lensModel,
            fNumber: fNumber,
            shutterSpeedSeconds: shutter,
            iso: iso,
            focalLengthMM: focal,
            latitude: latitude,
            longitude: longitude
        )
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func resolveUTType(source: CGImageSource, url: URL) -> UTType {
        if let typeId = CGImageSourceGetType(source) as String?,
           let ut = UTType(typeId) {
            return ut
        }
        if let ut = UTType(filenameExtension: url.pathExtension) {
            return ut
        }
        return .data
    }
}
