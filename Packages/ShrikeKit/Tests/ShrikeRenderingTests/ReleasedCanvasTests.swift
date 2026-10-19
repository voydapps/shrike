import AppKit
import CoreGraphics
import QuartzCore
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering

@MainActor
private final class ReleasedCanvasDelegate: MetalImageViewDelegate {
    var firstDrawables = 0
    func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) { firstDrawables += 1 }
}

/// Real CAMetalLayer acquisition/encoding lifecycle tests. A successful commit
/// and callback are not compositor-pixel proof; native Empty/Undo captures are
/// still required to prove blanking and a visible restored image.
@MainActor
final class ReleasedCanvasTests: XCTestCase {
    private func image(_ green: CGFloat = 0.2) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: green, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        return try XCTUnwrap(context.makeImage())
    }

    private func window(for view: MetalImageView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    private func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let loop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { continuation.resume() }
            CFRunLoopWakeUp(loop)
        }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "The real Metal submission/callback must settle", file: file, line: line)
    }

    private final class WeakObject<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    func testPermanentDisposalReleasesBackingWhileTheViewIsRetainedAndCannotReactivate() async throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 4 << 20))
        view.resources = budget
        view.setImage(try image(), sourceID: "before-terminal-disposal")
        let oldLayer = WeakObject(view.layer)
        XCTAssertNotNil(oldLayer.value)
        XCTAssertTrue(oldLayer.value is CAMetalLayer)
        view.disposeAfterClose()
        try await until { oldLayer.value == nil }
        XCTAssertNil(view.layer)
        XCTAssertFalse(view.wantsLayer)
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        let uploads = view.mainThreadUploadCountForTesting
        let submissions = view.frameSubmissionsForTesting
        let retirements = view.releasedCanvasAcquisitionAttemptsForTesting
        let late = try image(0.7)
        view.image = late
        view.setPlaceholderImage(late, sourceID: "late-placeholder")
        view.setImage(late, sourceID: "late-decoded-image")
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        var prepared: DisplayTexture? = DisplayTextureFactory.make(from: late, commandQueue: queue, waitUntilCompleted: true, resources: budget)
        XCTAssertNotNil(prepared)
        let rejectedPrepared = WeakObject(prepared)
        view.setImage(late, sourceID: "late-prepared-image", prepared: prepared)
        prepared = nil
        XCTAssertNil(rejectedPrepared.value, "A late prepared texture must not be retained by a disposed view")
        XCTAssertFalse(view.swapInFullResolution(late, prepared: nil, sourceID: "late-decoded-image"))
        XCTAssertFalse(view.swapInLargerDisplayTexture(late, prepared: nil, sourceID: "late-decoded-image"))
        view.beginSwipe(isDirectionInverted: false, hasNext: true, hasPrevious: true)
        _ = view.handleSwipe(amount: 0.5, phase: .changed, isComplete: false)
        view.setSwipeNeighbour(nil, forward: true)
        view.setFrameSize(NSSize(width: 600, height: 400))
        view.layout()
        view.viewDidChangeBackingProperties()
        view.viewDidChangeEffectiveAppearance()
        view.viewDidMoveToWindow()
        view.allowsHDR = true
        view.zoomToActual()
        view.zoomToFit()
        view.needsDisplay = true
        view.releaseResources()
        view.disposeAfterClose()
        await drain()
        XCTAssertNil(view.image)
        XCTAssertNil(view.imageResourceLease)
        XCTAssertNil(view.currentDisplayForTesting)
        XCTAssertNil(view.swipeNeighbourForTesting)
        XCTAssertFalse(view.isShowingFullResolution)
        XCTAssertEqual(view.mainThreadUploadCountForTesting, uploads)
        XCTAssertEqual(view.frameSubmissionsForTesting, submissions)
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, retirements,
                       "Terminal disposal must never acquire a tiny replacement drawable")
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        // A late AppKit backing request may make an ordinary layer, never Metal.
        XCTAssertFalse(view.makeBackingLayer() is CAMetalLayer)
        view.wantsLayer = true
        XCTAssertFalse(view.layer is CAMetalLayer)
        XCTAssertNil(oldLayer.value)
        view.wantsLayer = false
        view.layer = nil
    }

    func testLiveReleaseSubmitsOneActualOnePixelOpaqueClearAndIgnoresLateInvalidation() async throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 4 << 20))
        view.resources = budget
        let window = window(for: view)
        defer { window.orderOut(nil); view.releaseResources(); window.close() }
        view.setImage(try image(), sourceID: "before-release")
        await drain()
        XCTAssertGreaterThan(view.frameSubmissionsForTesting, 0)
        XCTAssertGreaterThan(budget.snapshot().uniqueRetainedBytes, 0)
        view.needsDisplay = true // Queue an ordinary photo redraw before retirement.
        let frames = view.framesDrawnForTesting
        let ordinarySubmissions = view.frameSubmissionsForTesting
        view.releaseResources()
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .submitted)
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1)
        XCTAssertEqual(view.releasedCanvasAcquisitionsForTesting, 1)
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1, "Commit must happen before release returns")
        XCTAssertEqual(view.releasedCanvasTextureSizeForTesting, CGSize(width: 1, height: 1), "The acquired texture, not only requested size, must be tiny")
        XCTAssertEqual(view.releasedCanvasClearColorForTesting, SIMD4<Double>(0, 0, 0, 1), "Encoded clear is opaque black; this is not a screenshot assertion")
        XCTAssertEqual(view.framesDrawnForTesting, frames, "Retirement is separate from ordinary frame production")
        XCTAssertNil(view.image)
        XCTAssertNil(view.imageResourceLease)
        XCTAssertFalse(view.hasTextureForTesting)
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        for size in [CGSize(width: 800, height: 600), CGSize(width: 280, height: 200)] {
            view.setFrameSize(size)
            view.layout()
            view.viewDidChangeBackingProperties()
            view.zoom = 2
            view.zoomToFit()
            view.needsDisplay = true
            view.setNeedsDisplay(view.bounds)
            view.image = nil
            view.releaseResources()
            await drain()
            XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1))
            XCTAssertEqual(view.framesDrawnForTesting, frames)
            XCTAssertEqual(view.frameSubmissionsForTesting, ordinarySubmissions)
            XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1)
            XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1)
            XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        }
    }

    func testImmediateFreshPhotoRestoresDrawableAndTransformsWithoutAnyDelayedBlankCommit() async throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = window(for: view)
        defer { window.orderOut(nil); view.releaseResources(); window.close() }
        view.setImage(try image(), sourceID: "old")
        await drain()
        view.releaseResources()
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .submitted)
        let before = view.frameSubmissionsForTesting
        // Assign before any pending ordinary redraw or blank presentation callback
        // could run. The retirement path must have no later state mutation.
        let restored = try image(0.7)
        view.setImage(restored, sourceID: "restored")
        let fullSize = CGSize(width: view.bounds.width * view.metalLayerContentsScaleForTesting,
                              height: view.bounds.height * view.metalLayerContentsScaleForTesting)
        XCTAssertEqual(view.drawableSizeForTesting, fullSize)
        XCTAssertTrue(view.image === restored)
        XCTAssertTrue(view.hasTextureForTesting)
        await drain()
        XCTAssertGreaterThan(view.frameSubmissionsForTesting, before)
        XCTAssertEqual(view.lastSubmittedDrawableSizeForTesting, fullSize)
        let fit = view.displayedImageRectForTesting
        view.zoom = 2
        await drain()
        let enlarged = view.displayedImageRectForTesting
        XCTAssertGreaterThan(enlarged.width, fit.width)
        XCTAssertGreaterThan(enlarged.height, fit.height)
        let zoomSubmissions = view.frameSubmissionsForTesting
        view.zoomToFit()
        await drain()
        XCTAssertGreaterThan(view.frameSubmissionsForTesting, zoomSubmissions)
        XCTAssertEqual(view.displayedImageRectForTesting.width, fit.width, accuracy: 0.01)
        XCTAssertEqual(view.displayedImageRectForTesting.height, fit.height, accuracy: 0.01)
        XCTAssertEqual(view.drawableSizeForTesting, fullSize)
        XCTAssertEqual(view.lastSubmittedDrawableSizeForTesting, fullSize)
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1, "No delayed completion may submit another blank")
        XCTAssertEqual(view.sourceID, "restored")
        #if DEBUG
        let sample = try XCTUnwrap(view.lastUploadedSampleForTesting)
        XCTAssertGreaterThan(max(sample.x, max(sample.y, sample.z)), 0.05, "Fresh photo has real non-black uploaded pixels; compositor recovery is separate native QA")
        #endif
    }

    func testTinyRetirementDoesNotConsumeFirstDrawableOrFirstPhotoCallbacks() async throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.skipsFramesForTesting = true
        let delegate = ReleasedCanvasDelegate()
        view.delegate = delegate
        let window = window(for: view)
        defer { window.orderOut(nil); view.releaseResources(); window.close() }
        view.releaseResources()
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .submitted)
        await drain()
        XCTAssertEqual(delegate.firstDrawables, 0)
        XCTAssertEqual(view.framesDrawnForTesting, 0)
        var firstPhotos = 0
        view.onFirstImagePresented = { firstPhotos += 1 }
        view.skipsFramesForTesting = false
        view.setImage(try image(), sourceID: "first-real-photo")
        try await until { delegate.firstDrawables == 1 && firstPhotos == 1 }
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1)
        XCTAssertGreaterThan(view.frameSubmissionsForTesting, 0)
    }

    func testDetachedAndClosedCanvasesReleasePhotoAccountingWithoutAcquiringADrawable() throws {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 4 << 20))
        let detached = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        detached.resources = budget
        detached.setImage(try image(), sourceID: "detached")
        XCTAssertGreaterThan(budget.snapshot().uniqueRetainedBytes, 0)
        detached.releaseResources()
        XCTAssertEqual(detached.releasedCanvasOutcomeForTesting, .skippedDetached)
        XCTAssertEqual(detached.releasedCanvasAcquisitionAttemptsForTesting, 0)
        XCTAssertEqual(detached.releasedCanvasSubmissionsForTesting, 0)
        XCTAssertNil(detached.image)
        XCTAssertFalse(detached.hasTextureForTesting)
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        let closed = MetalImageView(frame: detached.frame)
        closed.resources = budget
        let window = window(for: closed)
        closed.setImage(try image(), sourceID: "closed")
        window.close()
        closed.releaseResources()
        XCTAssertEqual(closed.releasedCanvasOutcomeForTesting, .skippedDetached)
        XCTAssertEqual(closed.releasedCanvasAcquisitionAttemptsForTesting, 0)
        XCTAssertNil(closed.imageResourceLease)
        XCTAssertNil(closed.image)
        XCTAssertFalse(closed.hasTextureForTesting)
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
    }

    func testUnavailableDrawableKeepsReleaseQuiescentAndFreshAssignmentCanRecover() async throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 4 << 20))
        view.resources = budget
        let window = window(for: view)
        defer { window.orderOut(nil); view.releaseResources(); window.close() }
        view.setImage(try image(), sourceID: "old")
        await drain()
        view.failsReleasedCanvasAcquisitionForTesting = true
        view.releaseResources()
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .drawableUnavailable)
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1)
        XCTAssertEqual(view.releasedCanvasAcquisitionsForTesting, 0)
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 0)
        XCTAssertNil(view.releasedCanvasClearColorForTesting)
        XCTAssertNil(view.image)
        XCTAssertNil(view.imageResourceLease)
        XCTAssertFalse(view.hasTextureForTesting)
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
        let frames = view.framesDrawnForTesting
        view.setFrameSize(CGSize(width: 400, height: 280))
        view.viewDidChangeBackingProperties()
        view.needsDisplay = true
        view.failsReleasedCanvasAcquisitionForTesting = false
        view.releaseResources() // No automatic retry after a failed retirement.
        await drain()
        XCTAssertEqual(view.framesDrawnForTesting, frames)
        XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1))
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1)
        view.setImage(try image(0.7), sourceID: "fresh-after-unavailable")
        await drain()
        XCTAssertTrue(view.hasTextureForTesting)
        XCTAssertGreaterThan(view.framesDrawnForTesting, frames)
        XCTAssertGreaterThan(view.drawableSizeForTesting.width, 1)
        view.releaseResources()
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .submitted)
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 2)
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1)
    }
}
