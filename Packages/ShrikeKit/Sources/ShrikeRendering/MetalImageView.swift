//
//  MetalImageView.swift
//  ShrikeRendering
//
//  CAMetalLayer-backed NSView hosting the single-image viewer surface.
//
//  Design notes:
//    * Drawable: bgra8Unorm_srgb + Display P3 for SDR photos, rgba16Float +
//      extendedLinearDisplayP3 for 16F/HDR.
//      Honors `viewerBackgroundAlwaysBlack`: the layer is pure black behind the
//      quad, so transparent regions of PNGs composite onto black in fullscreen.
//    * One vertex + one fragment shader. MPSImageLanczosScale runs for
//      meaningful downsamples (texture edge >= 2x drawable edge) to keep
//      minification quality high without CPU cost.
//    * Texture upload runs off the main actor; the MainActor flip is atomic.
//    * First drawable commit fires a delegate callback so the app-level cold
//      launch signpost can close on a real GPU frame (Performance.md).
//

import AppKit
import ShrikeCore
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore
import os

/// How the image lays out inside the view when zoom is implicit.
public enum ContentMode: Sendable, Hashable {
    case bestFit          // scale down to fit, never upscale
    case actualSize       // 1:1 pixel mapping (`zoom == 1.0`)
    case fitWidth
    case fitHeight
    case zoom(Double)     // explicit multiplier; 1.0 == 100 %
}

@MainActor
public protocol MetalImageViewDelegate: AnyObject {
    func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double)
    func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint)
    func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView)
    /// Wheel or swipe asks for the next (`forward`) or previous image
    func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool)
    /// Whether there is an image in that direction (swipe thresholds).
    func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool
    /// A wheel, pinch, smart-zoom or double-click zoom finished (for the
    /// VoiceOver announcement).
    func metalImageViewDidFinishUserZoom(_ view: MetalImageView)
    /// A swipe needs the neighbour's texture. Answer with
    /// `setSwipeNeighbour` when it is at hand; never wait for a decode.
    func metalImageView(_ view: MetalImageView, wantsSwipeNeighbour forward: Bool)
    /// A swipe completed toward `forward`; `handOver` is what is on screen
    /// now. The host navigates (default: `requestsNavigation`).
    func metalImageView(_ view: MetalImageView, didCompleteSwipe forward: Bool, handOver: SwipeHandOver)
    /// A swipe stretched at least 12 pt toward an end of the list with no
    /// photo, then sprang back (shows a toast; never a folder change).
    func metalImageView(_ view: MetalImageView, didStretchPastEndOfList forward: Bool)
}

/// What a completed swipe left as the current picture.
public enum SwipeHandOver: Sendable, Equatable {
    /// The neighbour's prefetched texture: nothing left to load.
    case photo
    /// Its thumbnail: the full photo replaces it in the same rect.
    case standIn
    /// Nothing had arrived: an empty canvas until the photo loads.
    case nothing
}

public extension MetalImageViewDelegate {
    func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double) {}
    func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint) {}
    func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) {}
    func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool) {}
    func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool { false }
    func metalImageViewDidFinishUserZoom(_ view: MetalImageView) {}
    func metalImageView(_ view: MetalImageView, wantsSwipeNeighbour forward: Bool) {}
    func metalImageView(_ view: MetalImageView, didCompleteSwipe forward: Bool, handOver: SwipeHandOver) {
        metalImageView(view, requestsNavigation: forward)
    }
    func metalImageView(_ view: MetalImageView, didStretchPastEndOfList forward: Bool) {}
}

@MainActor
public final class MetalImageView: NSView {

    // MARK: - Public API

    /// Setting this schedules an async GPU upload; the old texture remains on
    /// screen until the new one is ready, then the main actor flips. Clears
    /// the placeholder flag unless the setter is being driven by
    /// `setPlaceholderImage`.
    public var resources: ImageResourceBudget = .shared
    public var resourceOwner = ImageResourceOwner()
    public private(set) var imageResourceLease: ImageResourceLease?
    public private(set) var imageIsLazy = false
    private var pendingImageLease: ImageResourceLease?
    private var pendingImageIsLazy = false
    public var image: CGImage? {
        didSet {
            guard !isPermanentlyDisposed else {
                image = nil
                imageResourceLease = nil
                imageIsLazy = false
                return
            }
            imageIsLazy = pendingImageIsLazy
            imageResourceLease = image.map { pendingImageLease ?? resources.retain(image: $0, owner: resourceOwner, category: .displayCache, isLazy: imageIsLazy) }
            if recordsImageAssignmentsForTesting, let image {
                imageAssignmentLogForTesting.append((image, sourceID, placeholderAssignmentInProgress, swappingResolution,
                                                     Array(Thread.callStackSymbols.prefix(14))))
            }
            if !placeholderAssignmentInProgress {
                isCurrentImagePlaceholder = false
            }
            // Any other photo drops the full-resolution texture (and the
            // display texture kept for the way back): one per window.
            if !swappingResolution {
                preFullResolution = nil
                // Never animated: a new photo shows at its own zoom.
                dropZoomPresentation()
            }
            handleImageChange(isPlaceholder: placeholderAssignmentInProgress)
        }
    }

    /// True when the currently-displayed texture is a thumbnail placeholder
    /// that the viewer expects to replace with a full-res decode shortly.
    /// Overlays consult this so they don't redundantly pulse twice per nav
    /// (once on thumb paint, once on full paint) when bridging is active.
    public private(set) var isCurrentImagePlaceholder: Bool = false

    /// Internal flag read by the `image` didSet to route a placeholder
    /// assignment through the same upload path as a full-res one, but
    /// without clearing the placeholder state. Main-actor isolated, so
    /// the set/clear bracketing is safe.
    private var placeholderAssignmentInProgress: Bool = false

    /// Paint a placeholder image (typically a ~1024 px thumbnail from
    /// `ThumbnailCache`) while the full-resolution decode is still
    /// running. Geometry rules (`contentMode` / `zoom` / `pan`) are re-applied
    /// on the subsequent full-res paint, so a thumb that "best-fits" the
    /// window is replaced in place by the full-res image, also "best-fit",
    /// with no snap-back to zero pan/zoom between the two.
    ///
    /// The two-phase "thumb first, then full" paint exists to close the
    /// "viewer shows the previous image with no indication anything is
    /// happening" gap on a cache miss. A 1024 px HEIC loads in a few
    /// milliseconds from `ThumbnailCache`'s memory tier and ~20 ms from
    /// its disk tier, versus hundreds of ms for a cold full-res decode
    /// on a 50 MP RAW.
    ///
    /// The `isPlaceholder` flag exists because the full-res paint that
    /// follows would otherwise look like the *second* image change in a
    /// ~50 ms window — overlays that pulse on zoom-change would flash
    /// twice. By flagging the placeholder upload, overlays can consult
    /// `isCurrentImagePlaceholder` and suppress their pulse on the
    /// placeholder leg.
    public func setPlaceholderImage(_ placeholder: CGImage, sourceID: String? = nil) {
        guard !isPermanentlyDisposed else { return }
        if sourceID != self.sourceID || sourceID == nil { sourcePixelSize = nil }
        self.sourceID = sourceID
        placeholderAssignmentInProgress = true
        isCurrentImagePlaceholder = true
        // Writing through the property runs handleImageChange via didSet;
        // the flag ensures the didSet sees this as a placeholder path.
        self.image = placeholder
        placeholderAssignmentInProgress = false
    }

    /// Identity (`ImageSource.id`) of the file whose pixels are on screen,
    /// set together with the image. `nil` when the caller didn't say.
    public private(set) var sourceID: String?

    /// Hand the view a full image for a known file. Same as setting
    /// `image`, but records which file the pixels belong to.
    public func setImage(_ newImage: CGImage?, sourceID: String?) {
        setImage(newImage, sourceID: sourceID, prepared: nil)
    }

    /// Same, with a texture the decode lane already built for `newImage`
    /// (`DisplayTextureFactory.preparer`). The view then skips the upload
    /// entirely: the main thread only swaps a pointer and draws.
    public func setImage(_ newImage: CGImage?, sourceID: String?, prepared: DisplayTexture?, resourceLease: ImageResourceLease? = nil, imageIsLazy: Bool = false) {
        guard !isPermanentlyDisposed else { return }
        pendingImageLease = resourceLease; pendingImageIsLazy = imageIsLazy
        defer { pendingImageLease = nil; pendingImageIsLazy = false }
        // A size recorded for another file must never define "100 %" for
        // this one: the viewer sets the new file's size when it
        // knows it.
        if sourceID != self.sourceID || sourceID == nil { sourcePixelSize = nil }
        self.sourceID = sourceID
        pendingPrepared = prepared
        self.image = newImage
        pendingPrepared = nil
    }

    /// Drop the photo and request one tiny black presentation for a live canvas.
    /// AppKit owns this backing layer's contents; clearing that property directly
    /// can prevent later Metal presentations from recovering when Undo reuses it.
    public func releaseResources() {
        guard !isPermanentlyDisposed else { return }
        let wasReleased = drawableWasReleased
        // Cleanup invalidates layout/display. Enter quiescence before any of
        // those callbacks can request an ordinary drawable, including queued work.
        drawableWasReleased = true
        cancelActiveSwipe()
        onFirstImagePresented = nil
        pendingPrepared = nil
        sourceID = nil
        image = nil
        currentDisplay = nil
        lastPresentedTexture = nil
        metalLayer?.drawableSize = CGSize(width: 1, height: 1)
        guard !wasReleased else { return }
        presentReleasedCanvas()
    }

    /// Irreversible disposal for a permanently closed viewer or removed pane.
    /// Reusable Empty/Undo canvases must continue to use `releaseResources()`.
    public func disposeAfterClose() {
        guard !isPermanentlyDisposed else { return }
        // Layer changes can reenter AppKit lifecycle methods. Close every gate
        // first, before dropping pixels or disconnecting the backing layer.
        isPermanentlyDisposed = true
        presentationIsLive.withLock { $0 = false }
        drawableWasReleased = true
        delegate = nil
        onFirstImagePresented = nil
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
        zoomAnimationFinish = nil
        zoomPresentation = nil
        pinch = nil
        swipeGeneration &+= 1
        swipe = nil
        swipeOffsetX = 0
        swipeFade = 0
        pendingPrepared = nil
        pendingImageLease = nil
        pendingImageIsLazy = false
        preFullResolution = nil
        image = nil
        imageResourceLease = nil
        currentDisplay = nil
        lastPresentedTexture = nil
        sourceID = nil
        isCurrentImagePlaceholder = false
        sourcePixelSize = nil
        standInLogicalSize = nil
        dragSourceURL = nil
        lastDragPoint = nil
        dragStartPoint = nil
        windowStripActionHandler = nil
        imageAssignmentLogForTesting.removeAll(keepingCapacity: false)
        NotificationCenter.default.removeObserver(self)
        // Release both owners: NSView's public backing and our configured layer.
        // No final drawable is acquired or presented here.
        wantsLayer = false
        layer = nil
        metalLayer = nil
    }

    /// True after `releaseResources()` until a photo is set again.
    private var drawableWasReleased = false

    internal enum ReleasedCanvasOutcome: Equatable {
        case notRequested, skippedDetached, drawableUnavailable, commandBufferUnavailable, encoderUnavailable
        case unexpectedDrawableSize(width: Int, height: Int)
        /// Encoded and committed, not a claim that the compositor displayed it.
        case submitted
    }
    internal private(set) var releasedCanvasOutcomeForTesting: ReleasedCanvasOutcome = .notRequested
    internal private(set) var releasedCanvasAcquisitionAttemptsForTesting = 0
    internal private(set) var releasedCanvasAcquisitionsForTesting = 0
    internal private(set) var releasedCanvasSubmissionsForTesting = 0
    internal private(set) var releasedCanvasTextureSizeForTesting: CGSize?
    internal private(set) var releasedCanvasClearColorForTesting: SIMD4<Double>?
    /// Narrow failure seam: take the same nil-drawable branch without attempting
    /// an unavailable surface. Never substitutes a texture or a rendering path.
    internal var failsReleasedCanvasAcquisitionForTesting = false

    private func presentReleasedCanvas() {
        guard !isPermanentlyDisposed, let metalLayer else { return }
        releasedCanvasTextureSizeForTesting = nil
        releasedCanvasClearColorForTesting = nil
        // Closed/detached canvases need no presentation. Their owner releases
        // the backing layer; a live empty canvas must replace its old surface.
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor else {
            releasedCanvasOutcomeForTesting = .skippedDetached
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            releasedCanvasOutcomeForTesting = .commandBufferUnavailable
            return
        }
        // One acquisition, with CAMetalLayer's normal drawable timeout. Never
        // retry or clear a full-size fallback if its pool cannot supply 1 × 1.
        releasedCanvasAcquisitionAttemptsForTesting &+= 1
        guard !failsReleasedCanvasAcquisitionForTesting, let drawable = metalLayer.nextDrawable() else {
            releasedCanvasOutcomeForTesting = .drawableUnavailable
            ShrikeSignposts.navigation.event("releaseEmptyFrameUnavailable")
            return
        }
        releasedCanvasAcquisitionsForTesting &+= 1
        let texture = drawable.texture
        releasedCanvasTextureSizeForTesting = CGSize(width: texture.width, height: texture.height)
        guard texture.width == 1, texture.height == 1 else {
            releasedCanvasOutcomeForTesting = .unexpectedDrawableSize(width: texture.width, height: texture.height)
            ShrikeSignposts.navigation.event("releaseEmptyFrameWrongSize")
            return
        }
        commandBuffer.label = "Shrike released canvas"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            releasedCanvasOutcomeForTesting = .encoderUnavailable
            return
        }
        encoder.label = "Shrike opaque empty canvas"
        encoder.endEncoding() // Clear only: no shader, image, quad or launch/teaching callback.
        releasedCanvasClearColorForTesting = SIMD4<Double>(0, 0, 0, 1)
        // Commit on the photo queue before returning: prior photo → tiny blank
        // → any fresh Undo photo. No delayed callback can erase the new photo.
        commandBuffer.present(drawable)
        commandBuffer.commit()
        releasedCanvasSubmissionsForTesting &+= 1
        releasedCanvasOutcomeForTesting = .submitted
        ShrikeSignposts.navigation.event("releaseEmptyFrameSubmitted", "1x1 opaque black")
    }

    /// Test seam: true while a texture is on screen.
    internal var hasTextureForTesting: Bool { currentDisplay != nil }

    /// Texture handed in by `setImage(_:sourceID:prepared:)`, consumed by
    /// the `image` didSet.
    private var pendingPrepared: DisplayTexture?

    /// Test seam: how many textures this view built itself on the main
    /// thread (fallback path), as opposed to using a prepared one.
    internal private(set) var mainThreadUploadCountForTesting = 0

    /// Test seam: the encoding of the texture on screen.
    internal var currentEncodingForTesting: DisplayTextureEncoding? { currentDisplay?.encoding }

    /// Test seam: the drawable pixel format in use.
    internal var layerPixelFormatForTesting: MTLPixelFormat { metalLayer?.pixelFormat ?? .invalid }
    internal var maximumDrawableCountForTesting: Int { metalLayer?.maximumDrawableCount ?? 0 }

    /// Test seam: forces Reduce Motion on or off (nil = the system
    /// setting). The one shared source (`ReduceMotion`).
    internal static var reduceMotionOverrideForTesting: Bool? {
        get { ReduceMotion.overrideForTesting }
        set { ReduceMotion.overrideForTesting = newValue }
    }

    /// Test seam: forces the system's "Swipe between pages" setting on or
    /// off (nil = read the machine).
    internal static var swipeEnabledOverrideForTesting: Bool?

    /// Reduce Motion, read each time.
    static var reduceMotion: Bool { ReduceMotion.isOn }

    /// A keyboard / menu zoom step (`motion.instant`).
    public static let zoomStepDuration: TimeInterval = 0.08
    /// A pinch released below Fit goes back to Fit (`motion.quick`).
    public static let pinchReleaseDuration: TimeInterval = 0.12

    /// Test seam: the zoom and pan the next frame draws while a zoom step
    /// or a pinch release animates (nil when none runs).
    internal var zoomPresentationForTesting: (pixelScale: Double, pan: CGPoint)? {
        zoomPresentation.map { ($0.pixelScale, $0.pan) }
    }
    /// Test seam: the duration of the last zoom animation started.
    internal private(set) var lastZoomAnimationDurationForTesting: TimeInterval?
    /// Test seam: lands a running zoom animation on its end state.
    internal func finishZoomAnimationForTesting() { finishZoomAnimation() }
    /// Test seam: a swipe stand-in texture caps Fit at this logical size.
    internal var standInLogicalSizeForTesting: CGSize? {
        get { standInLogicalSize }
        set { standInLogicalSize = newValue }
    }
    /// Test seam: pretends a resolution swap is in progress.
    internal var swappingResolutionForTesting: Bool {
        get { swappingResolution }
        set { swappingResolution = newValue }
    }

    /// Test seam: the on-screen image size in view points.
    internal var displayedImageSizeForTesting: CGSize { displayedImageSize }

    /// Test seam: the on-screen image rect in view points.
    internal var displayedImageRectForTesting: CGRect { displayedImageRect() }

    /// Test seam: the file whose full-resolution texture is on screen.
    internal var fullResolutionSourceIDForTesting: String? {
        isShowingFullResolution ? sourceID : nil
    }

    /// Test seam: the texture's size in texels.
    internal var textureSizeForTesting: CGSize? {
        currentTexture.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Test seam: double-click / smart zoom at a view point.
    internal func toggleZoomForTesting(at point: CGPoint) { toggleZoom(at: point) }

    /// Test seam: replaces `trackSwipeEvent` (tests script the handler).
    internal var swipeTrackerForTesting: ((NSEvent) -> Void)?

    /// Test seam: replaces `beginDraggingSession` with a counter.
    internal var beginFileDragForTesting: (() -> Void)?

    public var contentMode: ContentMode = .bestFit {
        didSet {
            // Another zoom (Fit, 100 %, ...) replaces a running step at once.
            if !swappingResolution { dropZoomPresentation() }
            applyContentMode()
        }
    }

    public var allowsHDR: Bool = false {
        didSet {
            guard !isPermanentlyDisposed, let metalLayer else { return }
            metalLayer.wantsExtendedDynamicRangeContent = allowsHDR
            applyLayerFormat()
        }
    }

    public weak var delegate: (any MetalImageViewDelegate)?

    /// Optional file URL the viewer is currently showing. When set, dragging
    /// off the view (holding Option while dragging) starts a drag session
    /// carrying this file URL, so the user can drag into Finder, Mail, etc.
    public var dragSourceURL: URL?

    /// Canvas colour behind the image. A dynamic colour
    /// is resolved against the view's appearance at draw time.
    public var canvasColor: NSColor = .black {
        didSet {
            guard canvasColor != oldValue else { return }
            resolvedClear = nil
            needsDisplay = true
        }
    }
    private var resolvedClear: (appearance: NSAppearance.Name, color: MTLClearColor)?

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !isPermanentlyDisposed else { return }
        resolvedClear = nil
        needsDisplay = true
    }

    /// The clear colour for this frame: `canvasColor` in Display P3,
    /// linear (the sRGB-view and 16F drawables both take linear values).
    /// Cached per appearance so a frame does no colour work.
    internal func clearColorForDraw() -> MTLClearColor {
        let name = effectiveAppearance.name
        if let cached = resolvedClear, cached.appearance == name { return cached.color }
        var c: [Double] = [0, 0, 0, 1]
        let color = canvasColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let p3 = color.usingColorSpace(.displayP3) {
                c = [Double(p3.redComponent), Double(p3.greenComponent),
                     Double(p3.blueComponent), Double(p3.alphaComponent)]
            }
        }
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let clear = MTLClearColor(red: linear(c[0]), green: linear(c[1]), blue: linear(c[2]), alpha: c[3])
        resolvedClear = (name, clear)
        return clear
    }

    /// False in edit mode: drags belong to the tool.
    public var fileDragEnabled: Bool = true

    /// The file's pixel size (any orientation). "100 %" is one image pixel
    /// per screen pixel, so it is computed from this, not from the texture,
    /// which may be subsampled. Nil = assume the
    /// texture is full size.
    public var sourcePixelSize: CGSize?

    // MARK: Pixel scale

    /// Screen pixels per image pixel for one unit of `zoom`
    /// (texels per point).
    private var pixelsPerZoomUnit: Double {
        let backing = Double(window?.backingScaleFactor ?? metalLayer?.contentsScale ?? 1)
        guard let texture = currentTexture,
              let src = sourcePixelSize, src.width > 0, src.height > 0 else {
            return backing
        }
        let texLong = Double(max(texture.width, texture.height))
        let srcLong = Double(max(src.width, src.height))
        return texLong * backing / srcLong
    }

    /// Current scale where 1.0 = 100 % (one image pixel per screen pixel).
    public var pixelScale: Double { zoomLevel * pixelsPerZoomUnit }

    // MARK: Full resolution

    /// The display texture (and its image) shown before a full-resolution
    /// swap, kept for the way back to Fit. The decode cache holds the same
    /// objects, so keeping them costs no memory.
    private var preFullResolution: (display: DisplayTexture, image: CGImage, lease: ImageResourceLease?, lazy: Bool)?
    /// True while `image` is set by a resolution swap (keeps
    /// `preFullResolution` and the zoom badge quiet).
    private var swappingResolution = false

    /// The image as drawn, in view points (view coordinates).
    public var drawnImageRect: CGRect {
        guard currentTexture != nil else { return .zero }
        return displayedImageRect()
    }

    /// True while the full-resolution texture is on screen.
    public var isShowingFullResolution: Bool { preFullResolution != nil }

    /// True while the double-click / smart-zoom animation runs (its zoom
    /// is not at the target yet). A zoom step or pinch release does not
    /// count: its zoom is at the target, only the drawing follows.
    public var isZoomAnimating: Bool { zoomAnimationTimer != nil && zoomPresentation == nil }

    /// The zoom has gone past the display texture: more than one screen
    /// pixel per texel, and the file has more pixels than the texture.
    public var wantsFullResolution: Bool {
        guard !isShowingFullResolution, !isCurrentImagePlaceholder, swipe == nil,
              let t = currentTexture, let src = sourcePixelSize,
              src.width > 0, src.height > 0 else { return false }
        let texLong = Double(max(t.width, t.height))
        let srcLong = Double(max(src.width, src.height))
        guard texLong + 1 < srcLong, !isAtFit else { return false }
        let backing = Double(window?.backingScaleFactor ?? metalLayer?.contentsScale ?? 1)
        return zoomLevel * backing > 1.0 + 1e-3
    }

    /// Swaps in the full-resolution decode of the photo on screen. Same
    /// image rect, same pan: no jump, no flash, no re-fit. Returns false
    /// when the photo changed meanwhile (the texture is then dropped).
    @discardableResult
    public func swapInFullResolution(_ full: CGImage, prepared: DisplayTexture?,
                                     resourceLease: ImageResourceLease? = nil, imageIsLazy: Bool = false, sourceID: String?) -> Bool {
        guard !isPermanentlyDisposed, sourceID == self.sourceID, !isShowingFullResolution,
              let display = currentDisplay, let shown = image else { return false }
        let priorLease = imageResourceLease; let priorLazy = self.imageIsLazy
        guard swapTextureKeepingRect(full, prepared: prepared, resourceLease: resourceLease, imageIsLazy: imageIsLazy) else { return false }
        preFullResolution = (display, shown, priorLease, priorLazy)
        return true
    }

    /// Long edge, in texels, of the display texture (not the
    /// full-resolution one while that is shown); nil without a texture.
    public var displayTextureLongEdge: Int? {
        if let pre = preFullResolution {
            return max(pre.display.texture.width, pre.display.texture.height)
        }
        guard let size = rotatedTextureSize else { return nil }
        return Int(max(size.width, size.height))
    }

    /// The window grew, so a larger display texture of the
    /// same photo replaces the current one, keeping what is on screen
    /// (Fit stays Fit; a zoom keeps its on-screen size and pan). While
    /// the full-resolution texture is shown, the new texture becomes the
    /// one Fit comes back to. False when another photo is shown.
    @discardableResult
    public func swapInLargerDisplayTexture(_ newImage: CGImage, prepared: DisplayTexture?,
                                           resourceLease: ImageResourceLease? = nil, imageIsLazy: Bool = false, sourceID: String?) -> Bool {
        guard !isPermanentlyDisposed, sourceID != nil, sourceID == self.sourceID, !isCurrentImagePlaceholder else { return false }
        if preFullResolution != nil {
            guard let prepared else { return false }
            preFullResolution = (prepared, newImage, resourceLease ?? resources.retain(image: newImage, owner: resourceOwner, category: .displayCache, isLazy: imageIsLazy), imageIsLazy)
            return true
        }
        return swapTextureKeepingRect(newImage, prepared: prepared, resourceLease: resourceLease, imageIsLazy: imageIsLazy)
    }

    /// Back to the display texture (return to Fit): the full-resolution
    /// texture is released at once.
    public func dropFullResolution() {
        guard let pre = preFullResolution else { return }
        preFullResolution = nil
        _ = swapTextureKeepingRect(pre.image, prepared: pre.display, resourceLease: pre.lease, imageIsLazy: pre.lazy)
    }

    /// Replaces the texture, keeping the on-screen rect: zoom is rescaled
    /// by the texel ratio, pan (view points) is kept, Fit stays Fit.
    private func swapTextureKeepingRect(_ newImage: CGImage, prepared: DisplayTexture?, resourceLease: ImageResourceLease? = nil, imageIsLazy: Bool = false) -> Bool {
        guard !isPermanentlyDisposed else { return false }
        pendingImageLease = resourceLease; pendingImageIsLazy = imageIsLazy
        defer { pendingImageLease = nil; pendingImageIsLazy = false }
        guard let oldSize = rotatedTextureSize else { return false }
        let oldLong = Double(max(oldSize.width, oldSize.height))
        let oldZoom = zoomLevel
        let keepPan = panOffset
        let mode = contentMode
        swappingResolution = true
        defer { swappingResolution = false }
        pendingPrepared = prepared
        image = newImage
        pendingPrepared = nil
        guard let newSize = rotatedTextureSize, newSize.width > 0 else { return false }
        let newLong = Double(max(newSize.width, newSize.height))
        if case .bestFit = mode {
            contentMode = .bestFit
        } else {
            panOffset = keepPan
            contentMode = .zoom(oldZoom * oldLong / newLong)
        }
        needsDisplay = true
        return true
    }

    /// The fit-mode scale in the same units (fit never upscales past one
    /// texel per point).
    public var fitPixelScale: Double { fitZoomLevel * pixelsPerZoomUnit }

    /// Fit mode, or within 0.5 % of the fit scale.
    public var isAtFit: Bool {
        if case .bestFit = contentMode { return true }
        let fit = fitPixelScale
        return fit > 0 && abs(pixelScale - fit) <= fit * 0.005
    }

    /// Sets the pixel scale, keeping the image point under `anchor` (view
    /// coordinates) in place; nil anchors at the view centre. A scale at
    /// the fit value switches to fit mode.
    public func setPixelScale(_ scale: Double, anchor: CGPoint?) {
        finishZoomAnimation()
        let fit = fitPixelScale
        if fit > 0, abs(scale - fit) <= fit * 0.005 {
            contentMode = .bestFit
            return
        }
        let ppu = pixelsPerZoomUnit
        guard ppu > 0 else { return }
        let newZoom = max(0.001, min(scale, ZoomLadder.maxScale) / ppu)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        panOffset = PanGeometry.anchoredPan(
            pan: panOffset, anchor: anchor.map(panAnchor) ?? center, viewSize: bounds.size,
            from: zoomLevel, to: newZoom
        )
        contentMode = .zoom(newZoom)
        needsDisplay = true
    }

    /// Anchor for menu and keyboard zooms: the pointer when it is over
    /// the image, else nil (the view centre).
    public func pointerAnchorOverImage() -> CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return displayedImageRect().contains(p) ? p : nil
    }

    /// Zoom In / Zoom Out along the zoom ladder:
    /// 80 ms ease-out around the anchor, instant under Reduce Motion. The
    /// zoom itself (badge, VoiceOver, menus, the next step) is at the
    /// target at once; only the drawing catches up.
    public func stepZoom(in zoomIn: Bool) {
        let anchor = pointerAnchorOverImage()
        animateZoomChange(duration: Self.zoomStepDuration, anchor: anchor) {
            let fit = fitPixelScale
            let current = pixelScale
            guard let target = zoomIn ? ZoomLadder.stepIn(from: current, fit: fit)
                                      : ZoomLadder.stepOut(from: current, fit: fit) else { return }
            setPixelScale(target, anchor: anchor)
        }
    }

    public var canZoomIn: Bool { ZoomLadder.canZoomIn(from: pixelScale, fit: fitPixelScale) }
    public var canZoomOut: Bool { ZoomLadder.canZoomOut(from: pixelScale, fit: fitPixelScale) }

    /// Pan offset in view points (pre-zoom image-space, applied after scaling).
    public var pan: CGPoint {
        get { CGPoint(x: panOffset.x + bandOffset.x, y: panOffset.y + bandOffset.y) }
        set {
            panOffset = newValue
            resetRubberBand()
            needsDisplay = true
            delegate?.metalImageViewDidChangePan(self, pan: newValue)
        }
    }

    /// 1.0 == 100 %.
    public var zoom: Double {
        get { zoomLevel }
        set {
            let clamped = max(0.01, min(newValue, 64.0))
            if clamped != zoomLevel {
                zoomLevel = clamped
                needsDisplay = true
                delegate?.metalImageViewDidChangeZoom(self, zoom: pixelScale)
            }
        }
    }

    /// Degrees snapped to 90° increments, **clockwise-positive on
    /// screen** (+90 = Rotate Right), like `OrientationOp.rotate(quarters:)`
    /// and `ExifOrientation.rotated(quarters:)`.
    ///
    /// The view keeps the same shape as an EXIF orientation: a mirror of
    /// the texture first, then this clockwise turn. So `rotationDegrees`
    /// = quarters × 90 and `isFlippedHorizontally` = mirrored of the
    /// `ExifOrientation` made by the same presses.
    public private(set) var rotationDegrees: Double = 0
    public private(set) var isFlippedHorizontally: Bool = false
    /// Always false: a vertical flip is kept as a horizontal flip plus a
    /// half turn (see `flipVertical()`). Kept for the transform's API.
    public private(set) var isFlippedVertically: Bool = false

    public func reset() {
        panOffset = .zero
        zoomLevel = 1.0
        rotationDegrees = 0
        isFlippedHorizontally = false
        isFlippedVertically = false
        contentMode = .bestFit
        needsDisplay = true
    }

    /// Fit from ANY prior state (spec 27 B1): a running zoom animation lands
    /// first (its finish block writes `contentMode`, and would put the old
    /// zoom back after this call), then the presentation and pan are cleared
    /// and the fit zoom is applied whether or not the mode value changed.
    public func zoomToFit() {
        finishZoomAnimation()
        dropZoomPresentation()
        resetRubberBand()
        panOffset = .zero
        contentMode = .bestFit
        applyContentMode()
        needsDisplay = true
    }

    /// 100 %: one image pixel per screen pixel (not one texel per point).
    public func zoomToActual() {
        setPixelScale(1.0, anchor: pointerAnchorOverImage())
    }

    public func rotateBy(degrees: Double) {
        // Snap to 90° increments.
        let snapped = (rotationDegrees + degrees).truncatingRemainder(dividingBy: 360.0)
        rotationDegrees = (snapped / 90.0).rounded() * 90.0
        if rotationDegrees < 0 { rotationDegrees += 360.0 }
        applyContentMode()
        needsDisplay = true
    }

    /// Drops the view-only rotation and flips (navigation, or a fresh
    /// decode that already carries the file's orientation). Zoom and pan
    /// are kept.
    public func resetOrientation() {
        guard rotationDegrees != 0 || isFlippedHorizontally || isFlippedVertically else { return }
        rotationDegrees = 0
        isFlippedHorizontally = false
        isFlippedVertically = false
        applyContentMode()
        needsDisplay = true
    }

    /// Mirrors the photo **as it is on screen** (left ↔ right). After a
    /// turn R the result is F·R = R⁻¹·F, so the turn changes sign and the
    /// texture mirror toggles, the same as
    /// `ExifOrientation.flippedHorizontally()`.
    public func flipHorizontal() {
        isFlippedHorizontally.toggle()
        rotationDegrees = Self.normalizedDegrees(-rotationDegrees)
        needsDisplay = true
    }

    /// Mirrors the photo as it is on screen (top ↔ bottom): a horizontal
    /// flip plus a half turn, so the turn becomes 180° − θ and the texture
    /// mirror toggles (`ExifOrientation.flippedVertically()`). The turn
    /// keeps its parity, so the fit size does not change.
    public func flipVertical() {
        isFlippedHorizontally.toggle()
        rotationDegrees = Self.normalizedDegrees(180 - rotationDegrees)
        needsDisplay = true
    }

    /// Degrees in [0, 360), snapped to quarters.
    private nonisolated static func normalizedDegrees(_ degrees: Double) -> Double {
        let q = Int((degrees / 90).rounded())
        return Double(((q % 4) + 4) % 4) * 90
    }

    // MARK: - Metal state

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    /// Pipeline for the `rgba16Float` drawable (linear extended P3).
    /// Pipeline for the `bgra8Unorm_srgb` drawable (Display P3, SDR).
    private var metalLayer: CAMetalLayer?
    private var isPermanentlyDisposed = false
    private let presentationIsLive = OSAllocatedUnfairLock(initialState: true)

    /// Pre-uploaded vertex buffer for a unit quad [-1, 1] with UVs.
    private let quadBuffer: any MTLBuffer

    /// The photo on screen, as a GPU texture plus how to read it.
    private var currentDisplay: DisplayTexture?
    private var currentTexture: (any MTLTexture)? { currentDisplay?.texture }
    /// Last texture handed to a presented drawable — `imageFrame`
    /// signposts fire only when this changes.
    private weak var lastPresentedTexture: (any MTLTexture)?
    private nonisolated static let firstPlaceholderFrameFired = OSAllocatedUnfairLock(initialState: false)
    private nonisolated static let firstRealImageFrameFired = OSAllocatedUnfairLock(initialState: false)

    /// Fires the process-wide `launch/firstImageFrame` signpost once: the
    /// first time a full (non-placeholder) image frame reaches the glass.
    /// Called from Metal's presented-handler thread.
    nonisolated static func noteFirstRealImageFrame(presentedUptime: Double = ProcessInfo.processInfo.systemUptime) {
        let first = firstRealImageFrameFired.withLock { fired -> Bool in
            defer { fired = true }
            return !fired
        }
        if first {
            ShrikeSignposts.launch.event("firstImageFrame")
            NotificationCenter.default.post(name: Notification.Name("shrike.firstImagePresented"), object: nil, userInfo: ["presentedUptime": presentedUptime])
        }
    }
    private var displayLink: CVDisplayLink?
    private var firstDrawableFired = false
    public var onFirstImagePresented: (@MainActor () -> Void)?
    private var firstPhotoPresented = false

    /// Monotonic counter incremented on every `redraw()` call. Used by
    /// the fullscreen-exit regression tests to prove that a bounds
    /// change schedules a repaint. Stored here rather than computed so
    /// the test seam is O(1) and doesn't need to introspect CAMetalLayer.
    private var redrawAttemptCount: Int = 0

    /// Set inside `handleImageChange` when the incoming image is a thumbnail
    /// placeholder; read by `applyContentMode` to decide whether to emit the
    /// delegate's `didChangeZoom` callback. Suppressed on placeholders so
    /// overlays that pulse on zoom changes don't flicker twice per nav.
    private var suppressZoomCallbackForThisAssignment: Bool = false

    // Geometry.
    private var zoomLevel: Double = 1.0
    private var panOffset: CGPoint = .zero

    // Pointer tracking for drag-pan.
    private var lastDragPoint: NSPoint?
    private var dragStartPoint: NSPoint?

    // Input state.
    private var scrollRouter = ScrollInputRouter()
    private var pinch: PinchZoomState?
    /// View-only horizontal offset while a swipe is tracked.
    private var swipeOffsetX: CGFloat = 0
    /// Reduce Motion cross-fade: the neighbour's alpha.
    private var swipeFade: CGFloat = 0
    /// A swipe stand-in (thumbnail) is the current picture: Fit uses the
    /// photo's own pixel size (`.zero` = the thumbnail's aspect, no cap),
    /// so the full photo later lands in the same rect.
    private var standInLogicalSize: CGSize?
    private var zoomAnimationTimer: ActiveAnimationClock?
    /// What a zoom step or pinch release draws while it animates.
    /// In pixel scale, so a full-resolution swap mid-way needs no
    /// fix-up.
    private struct ZoomPresentation {
        var pixelScale: Double
        var pan: CGPoint
    }
    private var zoomPresentation: ZoomPresentation?
    /// End state of the running zoom / spring-back animation. Anything
    /// that stops the animation lands on it first (see
    /// `finishZoomAnimation`).
    private var zoomAnimationFinish: (@MainActor () -> Void)?

    // "Pan while zoomed in": the trackpad rubber band.
    /// Pan past the clamp as the fingers asked for it (the `x` of the
    /// band formula), signed, per axis. Zero when not stretched.
    private var stretch: CGPoint = .zero
    /// What the band shows on screen for `stretch`, added to `panOffset`.
    private var bandOffset: CGPoint = .zero
    /// A momentum pan hit the clamp: drop the rest of that momentum.
    private var momentumBlocked = false

    // Paging swipe.
    /// Gap between pages, in points (`space.xl`).
    public static let swipePageGap: CGFloat = 24
    private struct SwipeState {
        let isDirectionInverted: Bool
        let hasNext: Bool
        let hasPrevious: Bool
        /// Reduce Motion at the start: cross-fade in place, no slide.
        var crossFades = false
        /// Direction whose neighbour is wanted / held (true = next).
        var neighbourForward: Bool?
        /// The best picture of the neighbour at hand; held for the whole
        /// swipe so the prefetch window cannot free it while on screen.
        var neighbour: DisplayTexture?
        var neighbourIsStandIn = false
        var neighbourLogicalSize: CGSize?
        /// Peak stretch toward a side with no photo, in points.
        var peakEndStretch: CGFloat = 0
        var peakEndForward = true
        /// Outcome known when the fingers lifted.
        var knownOutcome: Bool?
        var stopRequested = false
        var lastAmount: Double = 0
    }
    private var swipe: SwipeState?
    /// Bumped per swipe: an older tracker's late calls stop at once.
    private var swipeGeneration = 0

    /// The part of the view the image
    /// fits and centres in. Edit mode keeps the photo and its crop handles
    /// out from under the side panel, the capsule and the screen edges;
    /// the canvas colour still fills the whole view. Zero = the bounds.
    public var fitInsets = NSEdgeInsets() {
        didSet {
            guard !NSEdgeInsetsEqual(oldValue, fitInsets) else { return }
            applyContentMode()
            needsDisplay = true
        }
    }

    /// `bounds` less `fitInsets` (the bounds when the insets leave no room).
    public var fitArea: CGRect {
        let r = CGRect(x: bounds.minX + fitInsets.left, y: bounds.minY + fitInsets.bottom,
                       width: bounds.width - fitInsets.left - fitInsets.right,
                       height: bounds.height - fitInsets.top - fitInsets.bottom)
        return r.width >= 1 && r.height >= 1 ? r : bounds
    }

    /// Where the fit area's centre sits from the view centre.
    private var fitCentreOffset: CGPoint {
        let a = fitArea
        return CGPoint(x: a.midX - bounds.midX, y: a.midY - bounds.midY)
    }

    /// The fit zoom in `zoom` units (texels per point), never above 1.
    private var fitZoomLevel: Double {
        guard let size = rotatedTextureSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return zoomLevel }
        return bestFitZoom(width: size.width, height: size.height)
    }

    /// Fit zoom for an image of `width` x `height` texels: never past one
    /// texel per point, except a swipe stand-in (see `standInLogicalSize`).
    private func bestFitZoom(width: Double, height: Double) -> Double {
        let area = fitArea
        let fit = min(Double(area.width) / width, Double(area.height) / height)
        guard let logical = standInLogicalSize else { return min(fit, 1.0) }
        return logical.width > 0 ? min(fit, Double(logical.width) / width) : fit
    }

    /// Texture size after the view-only rotation, in texels.
    private var rotatedTextureSize: CGSize? {
        guard let t = currentTexture else { return nil }
        return Int(rotationDegrees) % 180 == 0
            ? CGSize(width: t.width, height: t.height)
            : CGSize(width: t.height, height: t.width)
    }

    /// On-screen image size in view points.
    private var displayedImageSize: CGSize {
        guard let s = rotatedTextureSize else { return .zero }
        return CGSize(width: s.width * zoomLevel, height: s.height * zoomLevel)
    }

    private func displayedImageRect() -> CGRect {
        let size = displayedImageSize
        let off = fitCentreOffset
        return CGRect(x: bounds.midX + off.x + panOffset.x - size.width / 2,
                      y: bounds.midY + off.y + panOffset.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func clampedPan(_ p: CGPoint) -> CGPoint {
        PanGeometry.clamp(pan: p, imageSize: displayedImageSize, viewSize: fitArea.size)
    }

    /// A view point as the pan maths sees it (relative to the fit area's
    /// centre, which is the view centre when there are no insets).
    private func panAnchor(_ p: CGPoint) -> CGPoint {
        let off = fitCentreOffset
        return CGPoint(x: p.x - off.x, y: p.y - off.y)
    }

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MetalImageView: no Metal device available")
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            fatalError("MetalImageView: could not create command queue")
        }
        self.commandQueue = queue

        let layer = CAMetalLayer()
        layer.device = device
        // Starts 8-bit (SDR); `applyLayerFormat()` switches to rgba16Float
        // + extendedLinearDisplayP3 when a 16F photo arrives.
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        // Two drawables, not the default three: the viewer draws one frame
        // per change, never several frames ahead, and a drawable is the
        // window's pixels x 4 bytes (70 MB each on a 5K full screen).
        layer.maximumDrawableCount = 2
        layer.colorspace = ColorPipeline.displayP3Space
        layer.wantsExtendedDynamicRangeContent = false
        layer.backgroundColor = NSColor.black.cgColor
        // Disable Core Animation's implicit animations on the layer's
        // geometry + contents. The layer-backed contract (see
        // `makeBackingLayer()`) means AppKit drives `layer.frame` to
        // follow the view's `bounds` exactly, including across the
        // multi-tick AppKit fullscreen animation. Without this, CA
        // *also* lays its own implicit tween over the geometry change,
        // continuing to display the previously-presented (fullscreen-
        // sized) drawable's contents scaled into the shrinking layer
        // rect — visible to the user as a "shrink → un-shrink" pulse on
        // fullscreen exit (the trailing snap is the post-animation
        // refit landing once the AppKit animation settles). Disabling
        // implicit actions on `bounds` / `position` / `frame` /
        // `contents` makes each layout tick atomic: `setFrameSize` →
        // `updateDrawableSize` → `applyContentMode` → fresh draw at the
        // correct intermediate size. AppKit's frame-sync still happens;
        // CA just doesn't tween it.
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
        ]
        self.metalLayer = layer

        // Unit quad (x, y, u, v). Two triangles.
        let vertices: [Float] = [
            -1, -1, 0, 1,
             1, -1, 1, 1,
            -1,  1, 0, 0,
             1,  1, 1, 0,
        ]
        let length = vertices.count * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: length, options: [.storageModeShared]) else {
            fatalError("MetalImageView: could not create quad buffer")
        }
        self.quadBuffer = buffer

        // Build pipeline + sampler synchronously — first draw needs them.
        // Pipelines come from `MetalPipelines.shared`, built once per
        // process off the main thread.
        MetalPipelines.warmUp()

        super.init(frame: frameRect)

        // Layer-backed mode via `makeBackingLayer()` (below). AppKit
        // auto-manages the backing layer's frame in sync with our
        // `bounds`, which matters across NSWindow fullscreen-exit
        // transitions: in layer-HOSTING mode (the earlier setup —
        // `self.layer = layer` after `wantsLayer = true`), AppKit
        // stops syncing the layer frame on bounds changes, and the
        // CAMetalLayer's frame drifted out of sync during the
        // fullscreen → windowed animation, leaving the previously
        // presented drawable pinned into a corner of the smaller view
        // with a black strip on the other two edges. Layer-backed
        // mode, with the Metal layer supplied via `makeBackingLayer`,
        // keeps AppKit responsible for the layer.frame contract while
        // still giving us the CAMetalLayer we need for drawable
        // presentation. We only still manage `drawableSize` (pixels)
        // and `contentsScale`, which AppKit doesn't touch.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        wantsLayer = true
        layer.contentsScale =
            window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0

        registerForTrackingAndKeys()
    }

    /// AppKit calls this when the view needs a backing layer. Returning
    /// our pre-configured `CAMetalLayer` keeps the view layer-backed
    /// (AppKit owns the frame contract) while letting us render via
    /// Metal. See the matching commentary in `init`.
    public override func makeBackingLayer() -> CALayer {
        guard !isPermanentlyDisposed, let metalLayer else { return super.makeBackingLayer() }
        return metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalImageView is programmatic only.")
    }

    // CVDisplayLink teardown would live in deinit, but the display link is
    // unused (we redraw on-demand). If it is ever used, tear it
    // down via an explicit `invalidate()` call from ViewerWindow before the
    // view is released, since deinit is nonisolated and can't touch
    // main-actor state under Swift 6 strict concurrency.

    // MARK: - NSView lifecycle

    public override var isFlipped: Bool { false }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isPermanentlyDisposed else { return }
        updateDrawableSize()
        startDisplayLink()
        window?.makeFirstResponder(self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey(_:)),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    /// A stale start point can never arm a drag.
    @objc private func windowResignedKey(_ note: Notification) {
        lastDragPoint = nil
        dragStartPoint = nil
    }

    // MARK: - Window-move strip

    /// What a mouse-down in the window-move strip does.
    public enum WindowStripAction: Equatable, Sendable {
        case move, minimize, zoom, none
    }

    /// Test seam and injection point: runs the strip action instead of
    /// moving / minimising / zooming the real window. Nil = the real
    /// action (`performDrag(with:)`, `miniaturize`, `zoom`).
    public var windowStripActionHandler: (@MainActor (WindowStripAction, NSEvent) -> Void)?

    /// Test seam: the value of `AppleActionOnDoubleClick` to use
    /// (nil = read the user's defaults).
    internal var doubleClickActionOverrideForTesting: String??

    /// True for a down above `contentLayoutRect.maxY` of a windowed
    /// (not full-screen) window: the title + toolbar strip.
    func isInWindowMoveStrip(_ event: NSEvent) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen),
              window.styleMask.contains(.titled) else { return false }
        return event.locationInWindow.y > window.contentLayoutRect.maxY
    }

    /// Single click: move the window (the Window Server runs the drag and
    /// may send no mouseUp). Double click: the system titlebar setting.
    private func performWindowStripAction(for event: NSEvent) {
        let action: WindowStripAction
        if event.clickCount >= 2 {
            let pref = doubleClickActionOverrideForTesting
                ?? UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch pref {
            case "Minimize": action = .minimize
            case "None": action = .none
            default: action = .zoom
            }
        } else {
            action = .move
        }
        if let handler = windowStripActionHandler {
            handler(action, event)
        } else if let window {
            switch action {
            case .move: window.performDrag(with: event)
            case .minimize: window.miniaturize(nil)
            case .zoom: window.zoom(nil)
            case .none: break
            }
        }
        lastDragPoint = nil
        dragStartPoint = nil
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !isPermanentlyDisposed, let metalLayer else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        updateDrawableSize()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        guard !isPermanentlyDisposed else { return }
        updateDrawableSize()
        applyContentMode()
        // Force a repaint on every layout pass — `applyContentMode`
        // only mutates `zoomLevel` / `panOffset` and wouldn't otherwise
        // invalidate the last presented drawable. After a fullscreen
        // exit, the bounds shrink and we need a fresh drawable rendered
        // for the new drawableSize, otherwise the previous fullscreen-
        // sized drawable lingers until the next unrelated `needsDisplay`.
        needsDisplay = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        if !isPermanentlyDisposed, newSize != frame.size {
            cancelActiveSwipe()
            dropZoomPresentation()
        }
        super.setFrameSize(newSize)
        guard !isPermanentlyDisposed else { return }
        updateDrawableSize()
        applyContentMode()
        needsDisplay = true
    }

    private func updateDrawableSize() {
        // Closing can leave geometry callbacks queued. Only a new photo may
        // reactivate the drawable; layout must not rebuild its surface pool.
        guard !isPermanentlyDisposed, !drawableWasReleased, let metalLayer else { return }
        let scale = metalLayer.contentsScale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: w, height: h)
        // `metalLayer.frame` is NOT set here: now that the view is
        // layer-backed (see `makeBackingLayer()`), AppKit keeps the
        // layer's frame synchronised with `bounds`. Writing it from
        // here races AppKit's own frame update under fullscreen-exit
        // animations and was the root cause of the "image pinned to
        // bottom-right, black strip on top+left" regression.
    }

    // MARK: - Test seams

    /// Test seam: when true, every image handed to the view (full or
    /// placeholder) is appended to `imageAssignmentLogForTesting`. The
    /// full-screen regression test asserts that a mode flip + resize
    /// never hands the view a different photo.
    internal var recordsImageAssignmentsForTesting = false
    internal var imageAssignmentLogForTesting: [
        (image: CGImage, sourceID: String?, isPlaceholder: Bool, isResolutionSwap: Bool, callStack: [String])
    ] = []

    /// Exposed for tests only — the Metal layer's current frame in the
    /// view's coordinate space. Regression tests for fullscreen-exit
    /// assert this tracks `bounds` after the transition so a stale
    /// fullscreen-sized drawable isn't pinned into a corner of the
    /// smaller windowed view.
    internal var metalLayerFrameForTesting: CGRect { metalLayer?.frame ?? .zero }

    /// Exposed for tests only — the Metal layer's `actions` dictionary.
    /// Regression tests for the fullscreen-pulse fix assert that
    /// implicit Core Animation actions on `bounds` / `position` /
    /// `frame` / `contents` are explicitly disabled (mapped to
    /// `NSNull`), so AppKit-driven layer geometry changes don't get a
    /// CA tween layered on top of them during the multi-tick fullscreen
    /// animation.
    internal var metalLayerActionsForTesting: [String: any CAAction]? {
        metalLayer?.actions
    }

    /// Exposed for tests only — the Metal drawable's pixel size.
    internal var drawableSizeForTesting: CGSize { metalLayer?.drawableSize ?? .zero }

    /// Exposed for tests only — the backing layer's `contentsScale`.
    internal var metalLayerContentsScaleForTesting: CGFloat { metalLayer?.contentsScale ?? 0 }

    /// Exposed for tests only — monotonic counter incremented on every
    /// `redraw()` entry. Regression tests for fullscreen-exit assert
    /// that a bounds change flips the counter, guarding against the
    /// prior bug where `layout()` / `setFrameSize()` silently updated
    /// geometry without scheduling a repaint, leaving the previous
    /// fullscreen-sized drawable on screen.
    internal var redrawCountForTesting: Int { redrawAttemptCount }

    /// Exposed for tests only — a single sample (RGBA) read back from the
    /// last successfully uploaded texture's origin. Returns `nil` when no
    /// upload has succeeded yet, when readback isn't possible, or when
    /// running in release (the blit is gated behind `#if DEBUG` to keep
    /// the < 50 ms cached-nav budget — production builds don't pay for
    /// the test instrumentation). Regression tests for the "PNG renders
    /// black" bug call this after `image = somePNG` and assert the sample
    /// isn't near-zero, proving the upload path didn't silently fail and
    /// leave `currentTexture` stale or nil.
    internal var lastUploadedSampleForTesting: SIMD4<Float>? {
        #if DEBUG
        return lastUploadedSample
        #else
        return nil
        #endif
    }
    #if DEBUG
    private var lastUploadedSample: SIMD4<Float>?
    #endif

    // MARK: - Image → texture

    private func handleImageChange(isPlaceholder: Bool = false) {
        guard !isPermanentlyDisposed else { return }
        standInLogicalSize = nil
        guard let image else {
            currentDisplay = nil
            #if DEBUG
            lastUploadedSample = nil
            #endif
            needsDisplay = true
            return
        }
        // `releaseResources()` shrinks the drawable to 1 × 1 (the
        // empty state). Nothing re-lays the view when a photo comes back
        // (undo from the empty state), so the photo drew into 1 pixel:
        // a black canvas. Size the drawable for the view again.
        if drawableWasReleased {
            drawableWasReleased = false
            updateDrawableSize()
        }
        // The flag is used inside applyContentMode to decide whether to fire
        // the delegate's `didChangeZoom` callback — placeholders don't pulse
        // the zoom badge / overlay HUDs, only real full-res paints do.
        suppressZoomCallbackForThisAssignment = isPlaceholder
        defer { suppressZoomCallbackForThisAssignment = false }

        // Use the texture the decode lane built off the main thread when
        // it belongs to this exact image; otherwise build one here (Core
        // Image on the view's queue, no wait — the draw is ordered after
        // it on the same queue). See `DisplayTexture` for the encodings:
        // 8-bit for SDR photos, linear `rgba16Float` only when needed.
        //
        // History: `MTKTextureLoader.newTexture(cgImage:)` could not load
        // half-float CGImages with alpha (PNG/TIFF rendered black), so
        // uploads go through `CIContext.render(_:to:commandBuffer:...)`.
        let display: DisplayTexture
        if let prepared = pendingPrepared, prepared.matches(image) {
            display = prepared
        } else {
            guard let made = DisplayTextureFactory.make(
                from: image, commandQueue: commandQueue, waitUntilCompleted: false
            ) else {
                ShrikeSignposts.navigation.event(
                    "textureUploadFailed", "DisplayTextureFactory.make returned nil"
                )
                return
            }
            mainThreadUploadCountForTesting += 1
            display = made
        }

        // Capture a single readback sample for the test seam (debug only —
        // the blit + waitUntilCompleted adds ~1 ms to every image change,
        // which we don't want on the < 50 ms cached-nav budget in release).
        // The regression suite asserts on this sample to prove the upload
        // path didn't silently produce a black texture.
        #if DEBUG
        lastUploadedSample = captureSampleForTesting(from: display)
        #endif

        // Guard against a stale upload: if `image` changed again before this
        // synchronous call returned, the setter will have overwritten
        // `self.image` already and we still want the new texture to show.
        currentDisplay = display
        applyLayerFormat()
        applyContentMode()
        needsDisplay = true
    }

    /// Drawable format follows the photo: 8-bit sRGB-encoded Display P3
    /// for SDR textures (half the memory and bandwidth of the float
    /// drawable), linear extended P3 float for 16F content or when HDR
    /// output is allowed. Changing it only when needed keeps the
    /// drawable pool.
    private func applyLayerFormat() {
        guard !isPermanentlyDisposed, let metalLayer else { return }
        let eightBit = (currentDisplay?.encoding.isEightBit ?? true)
            && (swipe?.neighbour?.encoding.isEightBit ?? true) && !allowsHDR
        let format: MTLPixelFormat = eightBit ? .bgra8Unorm_srgb : .rgba16Float
        guard metalLayer.pixelFormat != format else { return }
        metalLayer.pixelFormat = format
        metalLayer.colorspace = eightBit ? ColorPipeline.displayP3Space : ColorPipeline.workingColorSpace
    }

    #if DEBUG
    /// Read back a single RGBA half-float pixel from the upper-left corner
    /// of `source`. Used by the test seam to prove that an image upload
    /// produced non-zero pixel data — the regression we're guarding against
    /// is "upload silently fails and the viewer paints solid black".
    /// Returns `nil` on any error path (we never let test instrumentation
    /// crash the viewer). Compiled out of release builds (see the gate
    /// in `handleImageChange` — the blit + waitUntilCompleted would
    /// otherwise add ~1 ms to every image change).
    private func captureSampleForTesting(from display: DisplayTexture) -> SIMD4<Float>? {
        let source = display.storage
        let eightBit = display.encoding.isEightBit
        let readbackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: 1, height: 1,
            mipmapped: false
        )
        readbackDesc.usage = [.shaderRead]
        readbackDesc.storageMode = .shared
        guard let readback = device.makeTexture(descriptor: readbackDesc),
              let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder()
        else { return nil }
        cb.label = "Shrike upload-sample readback"
        blit.copy(
            from: source,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: readback,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        if eightBit {
            // Report what the shader outputs: linear Display P3.
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBufferPointer { buf in
                readback.getBytes(buf.baseAddress!, bytesPerRow: 4,
                                  from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            }
            lastUploadedBytesForTesting = SIMD4<UInt8>(bytes[0], bytes[1], bytes[2], bytes[3])
            let linear = SIMD3<Float>(
                Float(ColorPipeline.srgbToLinear(Double(bytes[0]) / 255)),
                Float(ColorPipeline.srgbToLinear(Double(bytes[1]) / 255)),
                Float(ColorPipeline.srgbToLinear(Double(bytes[2]) / 255))
            )
            let p3 = display.toLinearP3 * linear
            return SIMD4<Float>(p3.x, p3.y, p3.z, Float(bytes[3]) / 255)
        }
        lastUploadedBytesForTesting = nil
        var halfBytes = [UInt16](repeating: 0, count: 4)
        halfBytes.withUnsafeMutableBufferPointer { buf in
            readback.getBytes(
                buf.baseAddress!,
                bytesPerRow: 8,
                from: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0
            )
        }
        return SIMD4<Float>(
            Float(Self.halfToFloat(halfBytes[0])),
            Float(Self.halfToFloat(halfBytes[1])),
            Float(Self.halfToFloat(halfBytes[2])),
            Float(Self.halfToFloat(halfBytes[3]))
        )
    }

    /// Test seam: the raw 8-bit texel at the origin of the last upload
    /// (nil for 16F textures). Proves sRGB/P3 bytes are copied exactly.
    internal private(set) var lastUploadedBytesForTesting: SIMD4<UInt8>?

    /// Decode an IEEE 754 binary16 value to Double. Local copy of the helper
    /// in `ColorPipeline` so the upload-path readback doesn't reach across
    /// module boundaries for a few lines of arithmetic.
    private static func halfToFloat(_ h: UInt16) -> Double {
        let sign: Double = ((h >> 15) & 0x1) == 0 ? 1.0 : -1.0
        let exp = Int((h >> 10) & 0x1F)
        let frac = Int(h & 0x3FF)
        switch exp {
        case 0:
            if frac == 0 { return sign * 0.0 }
            return sign * Double(frac) * pow(2.0, -24)
        case 0x1F:
            return frac == 0 ? sign * .infinity : .nan
        default:
            return sign * (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp - 15))
        }
    }
    #endif

    // MARK: - Transform / layout

    private func applyContentMode() {
        guard let texture = currentTexture else { return }
        let texW = Double(texture.width)
        let texH = Double(texture.height)
        let viewW = Double(bounds.width)
        let viewH = Double(bounds.height)
        guard texW > 0, texH > 0, viewW > 0, viewH > 0 else { return }

        // Account for 90° rotation swapping the effective image dims.
        let (imgW, imgH): (Double, Double)
        if Int(rotationDegrees) % 180 == 0 {
            imgW = texW; imgH = texH
        } else {
            imgW = texH; imgH = texW
        }

        let emit = !suppressZoomCallbackForThisAssignment && !swappingResolution
        switch contentMode {
        case .bestFit:
            zoomLevel = bestFitZoom(width: imgW, height: imgH)
            panOffset = .zero
        case .actualSize:
            zoomLevel = 1.0 / max(pixelsPerZoomUnit, 0.0001)
            panOffset = .zero
        case .fitWidth:
            zoomLevel = Double(fitArea.width) / imgW
            panOffset = clampedPan(panOffset)
        case .fitHeight:
            zoomLevel = Double(fitArea.height) / imgH
            panOffset = clampedPan(panOffset)
        case .zoom(let z):
            zoomLevel = max(0.001, min(z, 64.0))
            panOffset = clampedPan(panOffset)
        }
        // The badge and VoiceOver speak pixel percent.
        if emit { delegate?.metalImageViewDidChangeZoom(self, zoom: pixelScale) }
    }

    /// Build the clip-space transform for the current image/geometry state.
    /// Helper kept internal to simplify unit tests (see
    /// `MetalImageViewTransformTests` in the test target).
    internal func clipSpaceTransform() -> simd_float4x4 {
        guard let texture = currentTexture else {
            return matrix_identity_float4x4
        }
        let shown = shownZoomAndPan
        return Self.clipSpaceTransform(
            textureWidth: texture.width,
            textureHeight: texture.height,
            viewSize: bounds.size,
            zoom: shown.zoom,
            pan: CGPoint(x: fitCentreOffset.x + shown.pan.x + bandOffset.x + swipeOffsetX,
                         y: fitCentreOffset.y + shown.pan.y + bandOffset.y),
            rotationDegrees: rotationDegrees,
            flippedH: isFlippedHorizontally,
            flippedV: isFlippedVertically
        )
    }

    /// Pure function — builds the clip-space matrix for a given geometry.
    /// Factored out so unit tests can exercise the math without a GPU.
    /// `nonisolated` so the synchronous XCTest bodies can call it directly.
    internal nonisolated static func clipSpaceTransform(
        textureWidth: Int,
        textureHeight: Int,
        viewSize: CGSize,
        zoom: Double,
        pan: CGPoint,
        rotationDegrees: Double,
        flippedH: Bool,
        flippedV: Bool
    ) -> simd_float4x4 {
        let texW = Double(textureWidth)
        let texH = Double(textureHeight)
        let viewW = Double(viewSize.width)
        let viewH = Double(viewSize.height)
        guard texW > 0, texH > 0, viewW > 0, viewH > 0 else {
            return matrix_identity_float4x4
        }

        // Final on-screen image size in points, considering rotation.
        let (effW, effH): (Double, Double)
        if Int(rotationDegrees) % 180 == 0 {
            effW = texW * zoom
            effH = texH * zoom
        } else {
            effW = texH * zoom
            effH = texW * zoom
        }

        // Scale → clip space (2/view). Pan is in view points, mapped same way.
        let sx = effW / viewW
        let sy = effH / viewH

        // Compose: scale → rotate → flip → translate (pan).
        let scale = simd_float4x4(diagonal: SIMD4<Float>(Float(sx), Float(sy), 1, 1))

        // `rotationDegrees` is clockwise-positive on screen. Clip space is
        // y-up, where the matrix below turns counter-clockwise for a
        // positive angle, so the angle is negated (before
        // this, Rotate Left turned the view right while the file got a
        // left turn).
        let theta = -Float(rotationDegrees) * .pi / 180.0
        let c = cosf(theta)
        let s = sinf(theta)
        // Rotation is applied in clip-space; because clip space is square
        // while the image isn't, we rotate the un-scaled [-1, 1] quad first.
        // We fold it into the transform by inverting: rotate first, then scale.
        // Order (applied to the quad): mirror, then turn — the EXIF order.
        let rot = simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let flipX: Float = flippedH ? -1 : 1
        let flipY: Float = flippedV ? -1 : 1
        let flip = simd_float4x4(diagonal: SIMD4<Float>(flipX, flipY, 1, 1))

        let tx = Float(pan.x * 2.0 / viewW)
        // Metal clip-space Y is up-positive, AppKit view-space pan.y is up-positive
        // (view isFlipped == false), so keep the sign as-is.
        let ty = Float(pan.y * 2.0 / viewH)
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4<Float>(tx, ty, 0, 1)

        return translate * scale * rot * flip
    }

    // MARK: - Rendering

    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        redraw()
    }

    public override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { redraw() }
        }
    }

    /// Test seam: skip the GPU frame (timing tests measure the handler's
    /// own work, not the wait for a free drawable at the display rate).
    internal var skipsFramesForTesting = false

    /// Frames actually drawn (tests).
    private var framesDrawn = 0
    internal var framesDrawnForTesting: Int { framesDrawn }
    internal private(set) var frameSubmissionsForTesting = 0
    internal private(set) var lastSubmittedDrawableSizeForTesting: CGSize?

    /// (launch): a redraw request no longer draws at once. All
    /// requests in one run-loop turn make ONE frame, drawn later in the
    /// same turn (before Core Animation commits, so a resize never shows
    /// a stretched old frame). Building a viewer used to draw ~20 blocking
    /// ~8 ms frames. Common modes, so live resize, menus and modal sheets
    /// still draw.
    private var redrawScheduled = false

    private func redraw() {
        guard !isPermanentlyDisposed else { return }
        redrawAttemptCount &+= 1
        guard !redrawScheduled else { return }
        redrawScheduled = true
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.redrawScheduled = false
                self.drawFrame()
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func drawFrame() {
        guard !isPermanentlyDisposed, !drawableWasReleased, !skipsFramesForTesting, let metalLayer,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else {
            return
        }
        framesDrawn &+= 1

        let token = ShrikeSignposts.navigation.begin("drawFrame")
        defer { ShrikeSignposts.navigation.end("drawFrame", token) }

        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Shrike viewer frame"

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = clearColorForDraw()

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }
        encoder.label = "Shrike viewer encoder"

        // Waits here only if the background build has not finished yet.
        if let pipelines = MetalPipelines.shared {
            let pipeline = drawable.texture.pixelFormat == .rgba16Float
                ? pipelines.pipelineHalf : pipelines.pipeline8
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setFragmentSamplerState(pipelines.sampler, index: 0)
            if let display = currentDisplay, swipeFade < 1 {
                encodeQuad(encoder, display: display, transform: clipSpaceTransform(),
                           alpha: Float(1 - swipeFade))
            }
            // The neighbour page, in the same render pass
            // (sliding, or cross-fading in place under Reduce Motion).
            if swipeOffsetX != 0 || swipeFade > 0, let state = swipe,
               let n = state.neighbour, let rect = neighbourRect(state) {
                let zoom = Double(rect.width) / Double(n.texture.width)
                let transform = Self.clipSpaceTransform(
                    textureWidth: n.texture.width, textureHeight: n.texture.height,
                    viewSize: bounds.size, zoom: zoom,
                    pan: CGPoint(x: rect.midX - bounds.midX, y: rect.midY - bounds.midY),
                    rotationDegrees: 0, flippedH: false, flippedV: false)
                encodeQuad(encoder, display: n, transform: transform,
                           alpha: Float(swipeFade > 0 ? swipeFade : 1))
            }
        }
        encoder.endEncoding()

        // Emit `imageFrame` (full image) or `placeholderFrame` (preview /
        // thumbnail stand-in) when a frame carrying a NEW image texture
        // actually reaches the glass (presented handler), so key → glass
        // latency can be read from signposts instead of guessed from the
        // encode time. Separate static names because the unified log
        // redacts dynamic signpost messages outside Instruments.
        if let texture = currentTexture, texture !== lastPresentedTexture {
            lastPresentedTexture = texture
            let info = "w=\(texture.width) h=\(texture.height)"
            if isCurrentImagePlaceholder {
                drawable.addPresentedHandler { [presentationIsLive] _ in
                    guard presentationIsLive.withLock({ $0 }) else { return }
                    ShrikeSignposts.navigation.event("placeholderFrame", info)
                    let first = MetalImageView.firstPlaceholderFrameFired.withLock { fired -> Bool in
                        defer { fired = true }; return !fired
                    }
                    if first { NotificationCenter.default.post(name: Notification.Name("shrike.firstPlaceholderPresented"), object: nil, userInfo: ["presentedUptime": ProcessInfo.processInfo.systemUptime]) }
                }
            } else {
                drawable.addPresentedHandler { [weak self, presentationIsLive] _ in
                    guard presentationIsLive.withLock({ $0 }) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.isPermanentlyDisposed, !self.firstPhotoPresented else { return }
                        self.firstPhotoPresented = true; self.onFirstImagePresented?()
                    }
                    ShrikeSignposts.navigation.event("imageFrame", info)
                    MetalImageView.noteFirstRealImageFrame(presentedUptime: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        if !firstDrawableFired {
            firstDrawableFired = true
            drawable.addPresentedHandler { [weak self, presentationIsLive] _ in
                guard presentationIsLive.withLock({ $0 }) else { return }
                ShrikeSignposts.launch.event("firstMetalDrawable")
                NotificationCenter.default.post(name: Notification.Name("shrike.firstMetalDrawable"), object: nil)
                Task { @MainActor [weak self] in
                    guard let self, !self.isPermanentlyDisposed else { return }
                    self.delegate?.metalImageViewDidPresentFirstDrawable(self)
                }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameSubmissionsForTesting &+= 1
        lastSubmittedDrawableSizeForTesting = CGSize(width: drawable.texture.width, height: drawable.texture.height)
    }

    /// Fragment uniforms; layout matches `FragUniforms` in the shader
    /// (float3x3 = 48 bytes, then the alpha; 64 bytes with padding).
    private struct QuadFragmentUniforms {
        var toP3: simd_float3x3
        var alpha: Float
    }

    /// One textured quad. `alpha` multiplies the photo's own alpha (the
    /// pipeline blends source-over), for the Reduce Motion cross-fade.
    private func encodeQuad(_ encoder: any MTLRenderCommandEncoder, display: DisplayTexture,
                            transform: simd_float4x4, alpha: Float) {
        var uniforms = QuadFragmentUniforms(toP3: display.toLinearP3, alpha: alpha)
        withUnsafeBytes(of: &uniforms) { raw in
            guard let base = raw.baseAddress else { return }
            encoder.setFragmentBytes(base, length: MemoryLayout<QuadFragmentUniforms>.stride, index: 0)
        }
        var matrix = transform
        withUnsafeBytes(of: &matrix) { raw in
            guard let base = raw.baseAddress else { return }
            encoder.setVertexBytes(base, length: MemoryLayout<simd_float4x4>.size, index: 1)
        }
        encoder.setFragmentTexture(display.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Display link (optional, for pan/zoom smoothness)

    private func startDisplayLink() {
        // The viewer redraws on demand via `needsDisplay`; the display link is
        // not used today. This is the hook if zoom/pan easing is ever
        // driven by a display link.
    }

    // MARK: - Input

    private func registerForTrackingAndKeys() {
        let opts: NSTrackingArea.Options = [
            .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    public override func mouseDown(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        finishZoomAnimation()
        // Clear any stale start point first: only this down may arm a drag.
        lastDragPoint = nil
        dragStartPoint = nil
        // Safety net: a down in the window-move strip never
        // arms a file drag, a pan or the zoom toggle.
        if isInWindowMoveStrip(event) {
            performWindowStripAction(for: event)
            return
        }
        // Double-click toggles Fit ↔ 100 %.
        if event.clickCount == 2 {
            lastDragPoint = nil
            dragStartPoint = nil
            toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        lastDragPoint = event.locationInWindow
        dragStartPoint = event.locationInWindow
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        // At Fit (or with ⌥ at any zoom) a move of 4 pt
        // starts a file drag of the displayed file; zoomed in, it pans.
        if fileDragEnabled, let url = dragSourceURL,
           event.modifierFlags.contains(.option) || isAtFit {
            guard let start = dragStartPoint else { return }
            let now = event.locationInWindow
            if hypot(now.x - start.x, now.y - start.y) >= 4 {
                beginDragSession(with: event, url: url)
                lastDragPoint = nil
                dragStartPoint = nil
            }
            return
        }

        guard let last = lastDragPoint else { return }
        let now = event.locationInWindow
        applyPan(dx: now.x - last.x, dy: now.y - last.y)
        lastDragPoint = now
    }

    public override func mouseUp(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        lastDragPoint = nil
        dragStartPoint = nil
    }

    /// Pans with a hard stop at the clamp (wheel, mouse drag, momentum).
    /// Returns true when the clamp cut the move on an axis that can move.
    @discardableResult
    private func applyPan(dx: CGFloat, dy: CGFloat) -> Bool {
        resetRubberBand()
        let wanted = CGPoint(x: panOffset.x + dx, y: panOffset.y + dy)
        let next = clampedPan(wanted)
        let slack = panSlack
        let cut = (slack.width > 0 && abs(next.x - wanted.x) > 0.001)
            || (slack.height > 0 && abs(next.y - wanted.y) > 0.001)
        guard next != panOffset else { return cut }
        panOffset = next
        needsDisplay = true
        delegate?.metalImageViewDidChangePan(self, pan: panOffset)
        return cut
    }

    /// How far the image centre may move from the view centre, per axis
    /// (0 on an axis where the image is not larger than the canvas).
    private var panSlack: CGSize {
        let size = displayedImageSize
        let area = fitArea
        return CGSize(width: max(0, (size.width - area.width) / 2),
                      height: max(0, (size.height - area.height) / 2))
    }

    /// Trackpad pan while the fingers are down. Inside the
    /// clamp the image moves 1:1; past it the overscroll `x` shows as
    /// `d × (1 − 1 / (x × 0.55 / d + 1))` (`d` = canvas size on that axis).
    private func applyRubberBandPan(dx: CGFloat, dy: CGFloat) {
        let slack = panSlack
        func axis(_ pan: inout CGFloat, _ stretch: inout CGFloat, _ band: inout CGFloat,
                  _ delta: CGFloat, _ limit: CGFloat, _ canvas: CGFloat) {
            guard limit > 0, canvas > 0 else { pan = 0; stretch = 0; band = 0; return }
            if stretch == 0 {
                let wanted = pan + delta
                let clamped = min(max(wanted, -limit), limit)
                pan = clamped
                stretch = wanted - clamped
            } else {
                let next = stretch + delta
                if next == 0 || (next > 0) != (stretch > 0) {
                    // Came back inside: the rest moves the image 1:1.
                    stretch = 0
                    pan = min(max(pan + next, -limit), limit)
                } else {
                    stretch = next
                }
            }
            band = stretch == 0 ? 0
                : (stretch > 0 ? 1 : -1) * Self.rubberBand(abs(stretch), dimension: canvas)
        }
        var p = panOffset, s = stretch, b = bandOffset
        axis(&p.x, &s.x, &b.x, dx, slack.width, bounds.width)
        axis(&p.y, &s.y, &b.y, dy, slack.height, bounds.height)
        guard p != panOffset || b != bandOffset || s != stretch else { return }
        panOffset = p; stretch = s; bandOffset = b
        needsDisplay = true
        delegate?.metalImageViewDidChangePan(self, pan: pan)
    }

    /// The rubber-band formula (points in, points out).
    nonisolated static func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        guard d > 0, x > 0 else { return 0 }
        return d * (1 - 1 / (x * 0.55 / d + 1))
    }

    private func resetRubberBand() {
        stretch = .zero
        bandOffset = .zero
    }

    /// Fingers lifted while stretched: back to the clamp in 200 ms
    /// ease-out (`motion.standard`), on the zoom animation timer; at once
    /// under Reduce Motion.
    private func springBackRubberBand() {
        guard bandOffset != .zero || stretch != .zero else { return }
        finishZoomAnimation()
        let from = bandOffset
        stretch = .zero
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.bandOffset = .zero
            self.needsDisplay = true
            self.delegate?.metalImageViewDidChangePan(self, pan: self.pan)
        }
        if Self.reduceMotion {
            finish()
            return
        }
        runViewAnimation(duration: 0.2, finish: finish) { [weak self] t in
            let e = 1 - pow(1 - t, 3)   // ease-out
            self?.bandOffset = CGPoint(x: from.x * (1 - e), y: from.y * (1 - e))
        }
    }

    // MARK: - Drag-out

    /// Start a drag session carrying `url` as a `.fileURL` on the
    /// pasteboard, with a preview thumbnail sourced from the current image.
    private func beginDragSession(with event: NSEvent, url: URL) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(url.absoluteString, forType: .fileURL)

        // The displayed image scaled to fit 256 pt, alpha
        // 0.8, placed so the pointer keeps its relative spot on it.
        let drag = NSDraggingItem(pasteboardWriter: pbItem)
        let point = convert(event.locationInWindow, from: nil)
        let shown = displayedImageRect()
        var size = CGSize(width: 256, height: 256)
        if shown.width > 0, shown.height > 0 {
            let k = 256 / max(shown.width, shown.height)
            size = CGSize(width: shown.width * k, height: shown.height * k)
        }
        let fx = shown.width > 0 ? min(max((point.x - shown.minX) / shown.width, 0), 1) : 0.5
        let fy = shown.height > 0 ? min(max((point.y - shown.minY) / shown.height, 0), 1) : 0.5
        let frame = NSRect(x: point.x - fx * size.width, y: point.y - fy * size.height,
                           width: size.width, height: size.height)
        if let cg = image {
            let img = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.setAlpha(0.8)
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: rect)
                return true
            }
            drag.setDraggingFrame(frame, contents: img)
        } else {
            drag.setDraggingFrame(frame, contents: nil)
        }

        if let hook = beginFileDragForTesting { hook(); return }
        beginDraggingSession(
            with: [drag],
            event: event,
            source: self
        )
    }

    // MARK: - Pinch, smart zoom, wheel, swipe

    /// True during a pinch (between its first and last magnify event).
    public var isPinching: Bool { pinch != nil }

    public override func magnify(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        handleMagnify(magnification: Double(event.magnification), phase: event.phase,
                      anchor: convert(event.locationInWindow, from: nil))
    }

    /// One pinch step (`magnify(with:)`), testable without a gesture event.
    internal func handleMagnify(magnification: Double, phase: NSEvent.Phase, anchor: CGPoint) {
        guard currentTexture != nil else { return }
        finishZoomAnimation()
        if phase == .began || pinch == nil {
            pinch = PinchZoomState(scale: pixelScale, fit: fitPixelScale)
        }
        if pinch?.apply(magnification: magnification) == true {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if let scale = pinch?.scale { setPixelScale(scale, anchor: anchor) }
        if phase == .ended || phase == .cancelled {
            // Released below the fit scale: back to Fit, 120 ms ease-out;
            // instant under Reduce Motion.
            if pinch?.releaseScale == nil {
                animateZoomChange(duration: Self.pinchReleaseDuration, anchor: nil) {
                    contentMode = .bestFit
                }
            }
            pinch = nil
            delegate?.metalImageViewDidFinishUserZoom(self)
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        toggleZoom(at: convert(event.locationInWindow, from: nil))
    }

    // Rotate gesture: ignored — `rotate(with:)` is not
    // overridden.

    /// The host shows a "Can't open" card and hides the canvas (the old texture
    /// stays for the next photo): the wheel then behaves as with no photo, so a
    /// zoomed-in earlier photo cannot turn it into a pan on an invisible image.
    public var canvasIsEmptyBehindCard = false

    public override func scrollWheel(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        // No photo (a folder whose first photos cannot be opened, 0.2.10 audit
        // item 7): only changing the image makes sense, so the wheel still does
        // that. Zoom, pan and swipe need a texture.
        let hasTexture = currentTexture != nil && !canvasIsEmptyBehindCard
        // Land a running double-click / smart-zoom animation on its end
        // state BEFORE the routing reads `isAtFit` (root cause of the
        // "slide while zoomed does nothing": the half-done
        // animation still counted as Fit, so the slide was handed to the
        // swipe tracker, which then owned the whole gesture).
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            finishZoomAnimation()
        }
        // Edges: a new touch or a new fling starts clean;
        // fingers lifting with the image stretched spring it back.
        if event.phase == .began || event.phase == .mayBegin || event.momentumPhase == .began {
            if event.momentumPhase == .began, stretch != .zero || zoomAnimationFinish != nil {
                momentumBlocked = true   // the spring-back owns the edge
            } else {
                momentumBlocked = false
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            springBackRubberBand()
        }
        let input = ScrollInput(
            isPrecise: event.hasPreciseScrollingDeltas,
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            phaseBegan: event.phase == .began,
            isMomentum: event.momentumPhase != [],
            phaseEnded: event.phase == .ended || event.phase == .cancelled,
            hasPhase: event.phase != [],
            swapsAction: !event.modifierFlags.intersection([.command, .option]).isEmpty,
            timestamp: event.timestamp
        )
        let action = scrollRouter.route(
            input, atFit: hasTexture ? isAtFit : true,
            wheelChangesImage: Prefs.scrollWheelNavigates,
            swipeEnabled: hasTexture && (Self.swipeEnabledOverrideForTesting
                ?? NSEvent.isSwipeTrackingFromScrollEventsEnabled)
        )
        if !hasTexture {
            if case .navigate(let forward) = action {
                delegate?.metalImageView(self, requestsNavigation: forward)
            }
            return
        }
        switch action {
        case .none:
            break
        case .navigate(let forward):
            delegate?.metalImageView(self, requestsNavigation: forward)
        case .zoom(let factor):
            let fit = fitPixelScale
            let target = min(max(pixelScale * factor, ZoomLadder.lowest(fit: fit)), ZoomLadder.maxScale)
            setPixelScale(target, anchor: convert(event.locationInWindow, from: nil))
            delegate?.metalImageViewDidFinishUserZoom(self)
        case .pan(let dx, let dy):
            if event.momentumPhase != [] {
                // Momentum: hard stop at the clamp, drop the rest (no bounce).
                guard !momentumBlocked else { return }
                finishZoomAnimation()
                if applyPan(dx: dx, dy: dy) { momentumBlocked = true }
            } else if event.hasPreciseScrollingDeltas,
                      event.phase == .began || event.phase == .changed {
                // Fingers down: 1:1, with the rubber band past the clamp.
                finishZoomAnimation()
                applyRubberBandPan(dx: dx, dy: dy)
            } else {
                // Notched wheel: hard stop, no band.
                finishZoomAnimation()
                applyPan(dx: dx, dy: dy)
            }
        case .beginSwipe:
            trackSwipe(event)
        }
    }

    private func trackSwipe(_ event: NSEvent) {
        guard fileDragEnabled else { return }   // no swipe in edit mode
        // A new swipe finishes the last one at once to its known outcome.
        finishActiveSwipe()
        let inverted = event.isDirectionInvertedFromDevice
        let hasNext = delegate?.metalImageView(self, canNavigate: true) ?? false
        let hasPrevious = delegate?.metalImageView(self, canNavigate: false) ?? false
        beginSwipe(isDirectionInverted: inverted, hasNext: hasNext, hasPrevious: hasPrevious)
        if let hook = swipeTrackerForTesting { hook(event); return }
        let t = SwipeMapping.thresholds(hasPrevious: hasPrevious, hasNext: hasNext,
                                        isDirectionInverted: inverted)
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: t.min, max: t.max
        ) { [weak self, generation = swipeGeneration] amount, phase, isComplete, stop in
            // The closure only forwards.
            let halt = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.swipeGeneration == generation else { return true }
                return self.handleSwipe(amount: Double(amount), phase: phase, isComplete: isComplete)
            }
            if halt { stop.pointee = true }
        }
    }

    /// Three-finger swipe (System Settings "Swipe with three fingers"):
    /// AppKit sends one event per gesture, with no tracking. The photo
    /// changes at once, with no slide; fingers left = next.
    public override func swipe(with event: NSEvent) {
        guard !isPermanentlyDisposed else { return }
        guard fileDragEnabled, currentTexture != nil, isAtFit,
              let forward = SwipeMapping.threeFingerForward(deltaX: Double(event.deltaX)) else { return }
        finishActiveSwipe()
        delegate?.metalImageView(self, requestsNavigation: forward)
    }

    /// Starts the swipe state (tests call it before scripting amounts).
    func beginSwipe(isDirectionInverted: Bool, hasNext: Bool, hasPrevious: Bool) {
        guard !isPermanentlyDisposed else { return }
        swipeGeneration &+= 1
        swipe = SwipeState(isDirectionInverted: isDirectionInverted,
                           hasNext: hasNext, hasPrevious: hasPrevious,
                           crossFades: Self.reduceMotion)
        swipeOffsetX = 0
        swipeFade = 0
    }

    /// Page stride `S = W + G`.
    var swipePageStride: CGFloat { bounds.width + Self.swipePageGap }

    /// Stretch toward an empty end (points, as if the slide were on)
    /// that earns the "Last image" toast.
    public static let endOfListToastStretch: CGFloat = 12

    /// One `trackSwipeEvent` handler call. Returns true when the tracking
    /// must stop (the swipe was finished at once or ended elsewhere).
    /// Never waits: it only updates state and asks for one redraw.
    @discardableResult
    func handleSwipe(amount: Double, phase: NSEvent.Phase, isComplete: Bool) -> Bool {
        guard !isPermanentlyDisposed else { return true }
        guard var state = swipe, !state.stopRequested else {
            return true
        }
        let inverted = state.isDirectionInverted
        let right = SwipeMapping.fingersMoveRight(amount: amount, isDirectionInverted: inverted)
        let forward = !right    // fingers left = next
        let sideHasPhoto = forward ? state.hasNext : state.hasPrevious
        if phase == .ended {
            state.knownOutcome = (sideHasPhoto && amount != 0) ? forward : nil
        } else if phase == .cancelled {
            state.knownOutcome = nil
        }
        let magnitude = CGFloat(min(abs(amount), 1)) * swipePageStride
        // End of the list: remember the peak stretch toward the empty side
        // (measured as if the slide were on, also under Reduce Motion).
        if amount != 0, !sideHasPhoto, magnitude > state.peakEndStretch {
            state.peakEndStretch = magnitude
            state.peakEndForward = forward
        }
        if isComplete {
            swipe = state
            let result = SwipeMapping.result(finalAmount: amount, isComplete: true,
                                             isDirectionInverted: inverted)
            // Never toward a side with no photo.
            let navigate = result.flatMap { ($0 ? state.hasNext : state.hasPrevious) ? $0 : nil }
            endSwipe(navigate: navigate)
            if navigate == nil, state.peakEndStretch >= Self.endOfListToastStretch {
                delegate?.metalImageView(self, didStretchPastEndOfList: state.peakEndForward)
            }
            return false
        }
        // The neighbour on the side the row moves toward; asked for once,
        // never waited for.
        if amount != 0, state.neighbourForward != forward {
            state.neighbourForward = forward
            state.neighbour = nil
            state.neighbourIsStandIn = false
            state.neighbourLogicalSize = nil
            swipe = state
            if sideHasPhoto {
                delegate?.metalImageView(self, wantsSwipeNeighbour: forward)
                // The host may answer at once (setSwipeNeighbour).
                state = swipe ?? state
            }
        }
        state.lastAmount = amount
        swipe = state
        if state.crossFades {
            // Reduce Motion: no slide; cross-fade in place. Nothing fades
            // at an end of the list.
            swipeOffsetX = 0
            swipeFade = sideHasPhoto ? CGFloat(min(abs(amount), 1)) : 0
        } else {
            swipeOffsetX = right ? magnitude : -magnitude
            swipeFade = 0
        }
        applyLayerFormat()
        needsDisplay = true
        return false
    }

    /// The host hands over the neighbour's picture. `isStandIn`: a
    /// thumbnail standing in for a photo not decoded yet, drawn at the
    /// Fit rect of `logicalSize` (the photo's oriented pixel size; nil =
    /// the thumbnail's aspect). A full photo is never replaced by a
    /// stand-in. Ignored when the swipe moved on or ended.
    public func setSwipeNeighbour(_ display: DisplayTexture?, forward: Bool,
                                  isStandIn: Bool = false, logicalSize: CGSize? = nil) {
        guard !isPermanentlyDisposed else { return }
        guard var state = swipe, state.neighbourForward == forward else { return }
        if isStandIn, state.neighbour != nil, !state.neighbourIsStandIn { return }
        state.neighbour = display
        state.neighbourIsStandIn = display != nil && isStandIn
        state.neighbourLogicalSize = isStandIn ? logicalSize : nil
        swipe = state
        applyLayerFormat()
        needsDisplay = true
    }

    /// Key, wheel, button or menu navigation during a swipe:
    /// finish it at once to its known outcome.
    public func finishActiveSwipe() {
        guard let state = swipe else { return }
        endSwipe(navigate: state.knownOutcome)
    }

    /// The list, size, mode or window changed: stop, stay on the photo.
    public func cancelActiveSwipe() {
        guard swipe != nil else { return }
        endSwipe(navigate: nil)
    }

    /// Ends the swipe. A change makes the neighbour's picture the current
    /// one in the same pass, as it is (no decode, no upload, no re-fit):
    /// the photo, the thumbnail stand-in, or an empty canvas when nothing
    /// had arrived. Then the host navigates; it lands the same prepared
    /// texture, or replaces the stand-in in the same rect.
    private func endSwipe(navigate forward: Bool?) {
        let state = swipe
        swipe = nil
        swipeOffsetX = 0
        swipeFade = 0
        guard let forward else {
            applyLayerFormat()
            needsDisplay = true
            return
        }
        let handOver: SwipeHandOver
        if let neighbour = state?.neighbour, state?.neighbourForward == forward {
            let standIn = state?.neighbourIsStandIn ?? false
            currentDisplay = neighbour
            isCurrentImagePlaceholder = standIn
            standInLogicalSize = standIn ? (state?.neighbourLogicalSize ?? .zero) : nil
            handOver = standIn ? .standIn : .photo
        } else {
            currentDisplay = nil
            isCurrentImagePlaceholder = true
            standInLogicalSize = nil
            handOver = .nothing
        }
        rotationDegrees = 0
        isFlippedHorizontally = false
        isFlippedVertically = false
        contentMode = .bestFit
        applyLayerFormat()
        needsDisplay = true
        lastSwipeHandOverForTesting = handOver
        delegate?.metalImageView(self, didCompleteSwipe: forward, handOver: handOver)
    }

    /// Test seam: what the last completed swipe left on screen.
    internal private(set) var lastSwipeHandOverForTesting: SwipeHandOver?

    /// Test seam: the texture on screen (identity checks).
    internal var currentDisplayForTesting: DisplayTexture? { currentDisplay }

    /// Test seam: the neighbour picture the slide holds.
    internal var swipeNeighbourForTesting: DisplayTexture? { swipe?.neighbour }

    /// Test seam: true while a swipe is tracked or finishing.
    internal var isSwipeActiveForTesting: Bool { swipe != nil }

    /// Test seam: the alphas the next frame draws the two photos with.
    internal var swipeAlphasForTesting: (current: Double, neighbour: Double) {
        (Double(1 - swipeFade), Double(swipeFade > 0 ? swipeFade : 1))
    }

    /// Test seam: the drawn rects (view points) of the current photo and
    /// of the neighbour, as the next frame draws them.
    internal var swipeDrawnRectsForTesting: (current: CGRect, neighbour: CGRect?) {
        var current = displayedImageRect()
        current.origin.x += swipeOffsetX
        guard let state = swipe else { return (current, nil) }
        return (current, neighbourRect(state))
    }

    /// The neighbour's Fit rect moved by `offset ± S` (on its own Fit
    /// rect, unmoved, when cross-fading). Same Fit rule as the current
    /// photo: never past one texel per point. A stand-in uses the photo's
    /// own pixel size, else its aspect filling the page.
    private func neighbourRect(_ state: SwipeState) -> CGRect? {
        guard let n = state.neighbour, let forward = state.neighbourForward else { return nil }
        let w = CGFloat(n.texture.width), h = CGFloat(n.texture.height)
        guard w > 0, h > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let size: CGSize
        if state.neighbourIsStandIn {
            if let l = state.neighbourLogicalSize, l.width > 0, l.height > 0 {
                let fit = min(bounds.width / l.width, bounds.height / l.height, 1)
                size = CGSize(width: l.width * fit, height: l.height * fit)
            } else {
                let fit = min(bounds.width / w, bounds.height / h)
                size = CGSize(width: w * fit, height: h * fit)
            }
        } else {
            let fit = min(bounds.width / w, bounds.height / h, 1)
            size = CGSize(width: w * fit, height: h * fit)
        }
        let shift = state.crossFades ? 0 : swipeOffsetX + (forward ? swipePageStride : -swipePageStride)
        return CGRect(x: bounds.midX - size.width / 2 + shift, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Double-click and smart zoom: Fit → 100 % at the point, else → Fit.
    /// `motion.standard` (200 ms); instant under Reduce Motion.
    private func toggleZoom(at point: CGPoint) {
        guard currentTexture != nil else { return }
        finishZoomAnimation()   // decide from the landed state, not a half-done one
        let fromZoom = zoomLevel
        let fromPan = panOffset
        let toFit = ToggleZoom.target(atFit: isAtFit) == nil
        let toZoom: Double
        let toPan: CGPoint
        if toFit {
            toZoom = fitZoomLevel
            toPan = .zero
        } else {
            toZoom = 1.0 / max(pixelsPerZoomUnit, 0.0001)
            let anchored = PanGeometry.anchoredPan(pan: panOffset, anchor: panAnchor(point), viewSize: bounds.size,
                                                   from: zoomLevel, to: toZoom)
            let size = rotatedTextureSize ?? .zero
            toPan = PanGeometry.clamp(pan: anchored,
                                      imageSize: CGSize(width: size.width * toZoom,
                                                        height: size.height * toZoom),
                                      viewSize: bounds.size)
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            if toFit {
                self.contentMode = .bestFit
            } else {
                self.panOffset = toPan
                self.contentMode = .zoom(toZoom)
            }
            self.needsDisplay = true
            self.delegate?.metalImageViewDidFinishUserZoom(self)
        }
        finishZoomAnimation()
        resetRubberBand()
        if Self.reduceMotion || fromZoom <= 0 {
            finish()
            return
        }
        runViewAnimation(duration: 0.2, finish: finish) { [weak self] t in
            guard let self else { return }
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // ease in-out
            self.zoomLevel = fromZoom * pow(toZoom / fromZoom, e)
            self.panOffset = CGPoint(x: fromPan.x + (toPan.x - fromPan.x) * e,
                                     y: fromPan.y + (toPan.y - fromPan.y) * e)
        }
    }

    /// Runs a view animation on the 120 Hz timer: `step(t)` for t in
    /// 0..<1, then `finish` (the end state). `leadFrame`: the first step
    /// is applied now, so the next frame drawn already moves (no frame
    /// of lag), and the timer carries on from there.
    private func runViewAnimation(duration: TimeInterval,
                                  leadFrame: Bool = false,
                                  finish: @escaping @MainActor () -> Void,
                                  step: @escaping @MainActor (Double) -> Void) {
        guard !isPermanentlyDisposed else { return }
        let frame = 1.0 / 120.0
        let start = CACurrentMediaTime() - (leadFrame ? frame : 0)
        lastZoomAnimationDurationForTesting = duration
        zoomAnimationFinish = finish
        if leadFrame {
            step(min(1, frame / duration))
            needsDisplay = true
        }
        zoomAnimationTimer = ActiveAnimationClock(view: self) { [weak self] now in
            guard let self, !self.isPermanentlyDisposed else { return false }
            let t = min(1, (now - start) / duration)
            if t >= 1 { self.finishZoomAnimation(); return false }
            step(t)
            self.needsDisplay = true
            return true
        }
    }

    /// `change` moves the zoom and pan (the model) to the
    /// target at once; the drawing follows from what was on screen with
    /// an ease-out, the image point under `anchor` (nil: the view centre)
    /// held still, the last part blended into any pan clamp. Instant under
    /// Reduce Motion. A new step during the animation starts from the
    /// target of the last one and from the picture on screen.
    private func animateZoomChange(duration: TimeInterval, anchor: CGPoint?, _ change: () -> Void) {
        guard !isPermanentlyDisposed else { return }
        let shownBefore = shownZoomAndPan
        finishZoomAnimation()
        change()
        guard !Self.reduceMotion, currentTexture != nil, bounds.width > 0, bounds.height > 0,
              shownBefore.zoom > 0, zoomLevel > 0 else { return }
        let fromZoom = shownBefore.zoom, fromPan = shownBefore.pan
        let toZoom = zoomLevel, toPan = panOffset
        guard abs(toZoom - fromZoom) > toZoom * 1e-6 || fromPan != toPan else { return }
        let size = bounds.size
        let pivot = anchor.map(panAnchor) ?? CGPoint(x: bounds.midX, y: bounds.midY)
        // Where the anchor rule alone lands; the clamp moves the rest.
        let landing = PanGeometry.anchoredPan(pan: fromPan, anchor: pivot, viewSize: size,
                                              from: fromZoom, to: toZoom)
        let rest = CGPoint(x: toPan.x - landing.x, y: toPan.y - landing.y)
        let ppu = pixelsPerZoomUnit
        let finish: @MainActor () -> Void = { [weak self] in
            self?.zoomPresentation = nil
            self?.needsDisplay = true
        }
        runViewAnimation(duration: duration, leadFrame: true, finish: finish) { [weak self] t in
            guard let self else { return }
            let e = 1 - pow(1 - t, 3)   // ease-out
            let z = fromZoom * pow(toZoom / fromZoom, e)
            let p = PanGeometry.anchoredPan(pan: fromPan, anchor: pivot, viewSize: size, from: fromZoom, to: z)
            self.zoomPresentation = ZoomPresentation(
                pixelScale: z * ppu,
                pan: CGPoint(x: p.x + rest.x * e, y: p.y + rest.y * e))
        }
    }

    /// Ends a zoom step or pinch-release animation at its end state (the
    /// model is there already). Other animations are left alone.
    private func dropZoomPresentation() {
        guard zoomPresentation != nil else { return }
        finishZoomAnimation()
        zoomPresentation = nil
    }

    /// The zoom and pan the next frame draws.
    private var shownZoomAndPan: (zoom: Double, pan: CGPoint) {
        guard let shown = zoomPresentation else { return (zoomLevel, panOffset) }
        let ppu = pixelsPerZoomUnit
        guard ppu > 0 else { return (zoomLevel, panOffset) }
        return (shown.pixelScale / ppu, shown.pan)
    }

    /// Stops the running zoom or spring-back animation AT ITS END STATE.
    ///
    /// Root cause of "a two-finger slide does not move a zoomed photo"
    /// (found in a trackpad test): this used to only invalidate the
    /// timer. Every scroll, click, pinch and zoom stops the animation
    /// first, so input that arrived while the 200 ms double-click / smart
    /// zoom animation ran threw it away half-done: the zoom level was
    /// already large, but `contentMode` was still `.bestFit` (the
    /// animation sets it only in its finish block). The view then
    /// counted as "at Fit": the slide went to the page swipe instead of
    /// the pan, a drag became a file drag, and the next layout pass
    /// snapped the photo back to Fit.
    private func finishZoomAnimation() {
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
        guard let finish = zoomAnimationFinish else { return }
        zoomAnimationFinish = nil
        finish()
    }

    // Provide a bitmap snapshot for the loupe without coupling to the raw
    // texture storage. Returns the raw backing CGImage — the loupe crops.
    public func snapshotCGImage() -> CGImage? {
        image
    }
}

// MARK: - NSDraggingSource

extension MetalImageView: NSDraggingSource {
    public nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Outside the app (Finder, Mail, etc.) → copy.
        // Inside the app → none (no internal drop targets yet).
        switch context {
        case .outsideApplication: return [.copy]
        case .withinApplication:  return []
        @unknown default:         return [.copy]
        }
    }
}
