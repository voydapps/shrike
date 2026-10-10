//
//  MetalImageViewSwipeTests.swift
//  ShrikeRenderingTests
//
//  Paging swipe, driven through the testable
//  `handleSwipe(amount:phase:isComplete:)` with scripted amounts
//  (23 and the interruption rules).
//

import AppKit
import XCTest
@testable import ShrikeRendering

@MainActor
private final class SwipeRecorder: MetalImageViewDelegate {
    var navigations: [Bool] = []
    var neighbourRequests: [Bool] = []
    var canNext = true
    var canPrevious = true
    func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double) {}
    func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint) {}
    func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) {}
    func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool) { navigations.append(forward) }
    func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool {
        forward ? canNext : canPrevious
    }
    func metalImageViewDidFinishUserZoom(_ view: MetalImageView) {}
    func metalImageView(_ view: MetalImageView, wantsSwipeNeighbour forward: Bool) {
        neighbourRequests.append(forward)
    }
    var handOvers: [SwipeHandOver] = []
    var endStretches: [Bool] = []
    func metalImageView(_ view: MetalImageView, didCompleteSwipe forward: Bool, handOver: SwipeHandOver) {
        handOvers.append(handOver)
        navigations.append(forward)
    }
    func metalImageView(_ view: MetalImageView, didStretchPastEndOfList forward: Bool) {
        endStretches.append(forward)
    }
}

@MainActor
final class MetalImageViewSwipeTests: XCTestCase {

    private var window: NSWindow!
    private var view: MetalImageView!
    private var recorder: SwipeRecorder!

    override func setUp() async throws {
        MetalImageView.reduceMotionOverrideForTesting = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        recorder = SwipeRecorder()
        view.delegate = recorder
        view.image = Self.solidImage(width: 400, height: 300)
    }

    override func tearDown() async throws {
        MetalImageView.reduceMotionOverrideForTesting = nil
        view.delegate = nil
        window.orderOut(nil)
        window = nil
        view = nil
        recorder = nil
    }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func neighbourTexture(width: Int = 300, height: Int = 600) throws -> DisplayTexture {
        guard let t = DisplayTextureFactory.make(from: Self.solidImage(width: width, height: height),
                                                 commandQueue: nil, waitUntilCompleted: true) else {
            throw XCTSkip("no Metal device")
        }
        return t
    }

    /// Natural scrolling (the default): negative amount = fingers left = next.
    private func begin() {
        view.beginSwipe(isDirectionInverted: true, hasNext: true, hasPrevious: true)
    }

    // Offset = amount × (W + 24), not a 40 pt nudge.
    func testSlideOffsetIsAmountTimesPageStride() {
        begin()
        let before = view.swipeDrawnRectsForTesting.current
        view.handleSwipe(amount: -0.5, phase: .changed, isComplete: false)
        let after = view.swipeDrawnRectsForTesting.current
        XCTAssertEqual(view.swipePageStride, 824, accuracy: 0.001)
        XCTAssertEqual(before.minX - after.minX, 412, accuracy: 0.5,
                       "half a page toward the next photo")
        view.handleSwipe(amount: 0.25, phase: .changed, isComplete: false)
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current.minX - before.minX, 206, accuracy: 0.5)
    }

    // The neighbour is asked for once and drawn one page away,
    // at its own Fit size.
    func testNeighbourIsDrawnOnePageAwayAtFit() throws {
        begin()
        view.handleSwipe(amount: -0.1, phase: .changed, isComplete: false)
        view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
        XCTAssertEqual(recorder.neighbourRequests, [true], "asked once for the next photo")
        view.setSwipeNeighbour(try neighbourTexture(), forward: true)
        let rects = view.swipeDrawnRectsForTesting
        let n = try XCTUnwrap(rects.neighbour)
        XCTAssertEqual(n.height, 600, accuracy: 0.5, "neighbour at Fit")
        XCTAssertEqual(n.width, 300, accuracy: 0.5)
        let offset = -0.3 * 824.0
        XCTAssertEqual(n.midX - view.bounds.midX, offset + 824, accuracy: 0.5, "offset + S")
        // Direction flip asks for the other side.
        view.handleSwipe(amount: 0.2, phase: .changed, isComplete: false)
        XCTAssertEqual(recorder.neighbourRequests, [true, false])
        XCTAssertNil(view.swipeDrawnRectsForTesting.neighbour, "the next photo is not reused for previous")
    }

    // (view side): a completed page hands the neighbour's
    // texture over (no decode) and asks for navigation once.
    func testCompletedPageHandsOverTheNeighbourTexture() throws {
        begin()
        view.handleSwipe(amount: -0.4, phase: .changed, isComplete: false)
        view.setSwipeNeighbour(try neighbourTexture(), forward: true)
        view.handleSwipe(amount: -0.7, phase: .ended, isComplete: false)
        view.handleSwipe(amount: -1, phase: .ended, isComplete: true)
        XCTAssertEqual(recorder.navigations, [true])
        XCTAssertEqual(view.displayedImageSizeForTesting, CGSize(width: 300, height: 600))
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current.minX,
                       view.bounds.midX - 150, accuracy: 0.5, "slide offset back to 0")
        XCTAssertTrue(view.handleSwipe(amount: -1, phase: .ended, isComplete: true),
                      "late calls after the end stop the tracker")
    }

    func testCancelledSwipeStaysOnThePhoto() {
        begin()
        view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
        view.handleSwipe(amount: 0, phase: .cancelled, isComplete: false)
        view.handleSwipe(amount: 0, phase: .cancelled, isComplete: true)
        XCTAssertEqual(recorder.navigations, [])
        XCTAssertEqual(view.displayedImageSizeForTesting, CGSize(width: 400, height: 300))
    }

    // Reduce Motion, no slide.
    func testReduceMotionDoesNotSlide() {
        MetalImageView.reduceMotionOverrideForTesting = true
        begin()
        let before = view.swipeDrawnRectsForTesting.current
        view.handleSwipe(amount: -0.6, phase: .changed, isComplete: false)
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current, before)
        view.handleSwipe(amount: -1, phase: .ended, isComplete: true)
        XCTAssertEqual(recorder.navigations, [true], "the page still changes")
    }

    // Interruptions: after lift, a key finishes the swipe at once to its
    // known outcome; during the drag, it only ends the slide.
    func testInterruptionFinishesToKnownOutcome() {
        begin()
        view.handleSwipe(amount: -0.5, phase: .changed, isComplete: false)
        view.handleSwipe(amount: -0.6, phase: .ended, isComplete: false)
        view.finishActiveSwipe()
        XCTAssertEqual(recorder.navigations, [true])
        XCTAssertTrue(view.handleSwipe(amount: -0.8, phase: .ended, isComplete: false),
                      "the tracker is told to stop")

        begin()
        view.handleSwipe(amount: 0.4, phase: .changed, isComplete: false)
        view.cancelActiveSwipe()
        XCTAssertEqual(recorder.navigations, [true], "a cancel never navigates")
    }

    func testEndOfListSideNeverAsksForANeighbour() {
        view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
        view.handleSwipe(amount: -0.2, phase: .changed, isComplete: false)
        XCTAssertEqual(recorder.neighbourRequests, [])
        view.handleSwipe(amount: -0.2, phase: .ended, isComplete: false)
        view.finishActiveSwipe()
        XCTAssertEqual(recorder.navigations, [], "no photo on that side")
    }

    // MARK: - Fallback, cross-fade, ends, flicks, HDR

    private func hdrTexture(width: Int = 300, height: Int = 600) throws -> DisplayTexture {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw XCTSkip("no half-float context")
        }
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let t = DisplayTextureFactory.make(from: ctx.makeImage()!, commandQueue: nil,
                                                 waitUntilCompleted: true) else {
            throw XCTSkip("no Metal device")
        }
        return t
    }

    func testShaderPipelinesBuildWithTheAlphaUniform() {
        XCTAssertNotNil(MetalPipelines.shared, "the quad shader (with alpha) must compile")
    }

    // Nothing decoded yet. The handler never waits; the next
    // page is empty canvas until the thumbnail arrives, which is then drawn
    // at the photo's Fit rect. Completing on it keeps it in that rect,
    // and the full photo later lands in the same rect.
    func testStandInFallbackAndHandOver() throws {
        begin()
        // The handler's own work; a real frame may also wait for a free
        // drawable at the display rate, which is pacing, not a decode.
        view.skipsFramesForTesting = true
        view.handleSwipe(amount: -0.2, phase: .changed, isComplete: false)
        var worst: CFTimeInterval = 0
        for _ in 0..<5 {
            let t0 = CACurrentMediaTime()
            view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
            worst = max(worst, CACurrentMediaTime() - t0)
        }
        XCTAssertLessThan(worst, 0.002, "handleSwipe never waits")
        view.skipsFramesForTesting = false
        XCTAssertNil(view.swipeDrawnRectsForTesting.neighbour, "empty canvas: nothing drawn")
        // A 256 x 192 thumbnail of a 4000 x 3000 photo.
        let thumb = try neighbourTexture(width: 256, height: 192)
        view.setSwipeNeighbour(thumb, forward: true, isStandIn: true,
                               logicalSize: CGSize(width: 4000, height: 3000))
        let n = try XCTUnwrap(view.swipeDrawnRectsForTesting.neighbour)
        XCTAssertEqual(n.size.width, 800, accuracy: 0.5, "the photo's Fit rect, not the thumbnail's")
        XCTAssertEqual(n.size.height, 600, accuracy: 0.5)
        XCTAssertEqual(n.midX - view.bounds.midX, -0.3 * 824 + 824, accuracy: 0.5)
        // A better source mid-slide replaces the stand-in; never the reverse.
        let full = try neighbourTexture(width: 1600, height: 1200)
        view.setSwipeNeighbour(full, forward: true)
        view.setSwipeNeighbour(thumb, forward: true, isStandIn: true, logicalSize: nil)
        XCTAssertTrue(view.swipeNeighbourForTesting === full, "a stand-in never replaces the photo")

        // Complete on a stand-in.
        begin()
        view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
        view.setSwipeNeighbour(thumb, forward: true, isStandIn: true,
                               logicalSize: CGSize(width: 4000, height: 3000))
        view.handleSwipe(amount: -0.8, phase: .ended, isComplete: false)
        view.handleSwipe(amount: -1, phase: [], isComplete: false)
        let last = try XCTUnwrap(view.swipeDrawnRectsForTesting.neighbour)
        view.handleSwipe(amount: -1, phase: [], isComplete: true)
        XCTAssertEqual(recorder.handOvers.last, .standIn)
        XCTAssertTrue(view.currentDisplayForTesting === thumb)
        XCTAssertTrue(view.isCurrentImagePlaceholder)
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current, last, "same rect after completion")
        // The full decode lands in the same rect.
        view.setImage(Self.solidImage(width: 1600, height: 1200), sourceID: "next")
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current, last)
        XCTAssertFalse(view.isCurrentImagePlaceholder)
    }

    func testSwipeCompletingOnNothingLeavesAnEmptyCanvas() {
        begin()
        view.handleSwipe(amount: -0.7, phase: .ended, isComplete: false)
        view.handleSwipe(amount: -1, phase: [], isComplete: true)
        XCTAssertEqual(recorder.handOvers, [.nothing])
        XCTAssertNil(view.currentDisplayForTesting, "no jump back to the old photo")
    }

    // Reduce Motion cross-fades in place.
    func testReduceMotionCrossFadesInPlace() throws {
        MetalImageView.reduceMotionOverrideForTesting = true
        begin()
        let before = view.swipeDrawnRectsForTesting.current
        view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
        view.setSwipeNeighbour(try neighbourTexture(), forward: true)
        let rects = view.swipeDrawnRectsForTesting
        XCTAssertEqual(rects.current, before, "no offset")
        let n = try XCTUnwrap(rects.neighbour)
        XCTAssertEqual(n.midX, view.bounds.midX, accuracy: 0.5, "neighbour on its own Fit rect")
        XCTAssertEqual(n.height, 600, accuracy: 0.5)
        XCTAssertEqual(view.swipeAlphasForTesting.current, 0.7, accuracy: 0.001)
        XCTAssertEqual(view.swipeAlphasForTesting.neighbour, 0.3, accuracy: 0.001)
        // At an end of the list nothing fades.
        view.cancelActiveSwipe()
        view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
        view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
        XCTAssertEqual(view.swipeAlphasForTesting.current, 1, accuracy: 0.001)
    }

    // End of the list. A peak of 12 pt or more toward the empty
    // side asks for the toast; less does not; nothing navigates.
    func testEndOfListStretchAsksForTheToast() {
        view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
        view.handleSwipe(amount: -0.01, phase: .changed, isComplete: false)   // 8.2 pt
        view.handleSwipe(amount: 0, phase: [], isComplete: true)
        XCTAssertEqual(recorder.endStretches, [], "under 12 pt: no toast")
        view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
        view.handleSwipe(amount: -0.02, phase: .changed, isComplete: false)   // 16.5 pt
        view.handleSwipe(amount: 0, phase: [], isComplete: true)
        XCTAssertEqual(recorder.endStretches, [true])
        XCTAssertEqual(recorder.navigations, [])
        // Under Reduce Motion the stretch is measured as if the slide were on.
        MetalImageView.reduceMotionOverrideForTesting = true
        view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
        view.handleSwipe(amount: -0.02, phase: .changed, isComplete: false)
        view.handleSwipe(amount: 0, phase: [], isComplete: true)
        XCTAssertEqual(recorder.endStretches, [true, true])
        XCTAssertEqual(recorder.navigations, [], "a swipe never changes the photo at an end")
    }

    // Five fast flicks, each new one beginning while the last
    // is finishing at 0.7 after .ended: five navigations, none twice.
    func testFastFlicksNeverDropOrRepeat() throws {
        let texture = try neighbourTexture()
        for _ in 0..<5 {
            // trackSwipe's order: finish the last one at once, then begin.
            view.finishActiveSwipe()
            begin()
            view.handleSwipe(amount: -0.3, phase: .changed, isComplete: false)
            view.setSwipeNeighbour(texture, forward: true)
            view.handleSwipe(amount: -0.6, phase: .ended, isComplete: false)
            view.handleSwipe(amount: -0.7, phase: [], isComplete: false)
        }
        view.finishActiveSwipe()
        XCTAssertEqual(recorder.navigations, [true, true, true, true, true])
        XCTAssertEqual(recorder.handOvers, [.photo, .photo, .photo, .photo, .photo])
        XCTAssertTrue(view.handleSwipe(amount: -1, phase: [], isComplete: true),
                      "the old tracker's late completion is dropped")
        XCTAssertEqual(recorder.navigations.count, 5)
    }

    // An HDR neighbour switches the layer to rgba16Float before
    // it is drawn; back on the SDR photo the layer is 8-bit again.
    func testHDRNeighbourSwitchesTheLayerFormat() throws {
        XCTAssertEqual(view.layerPixelFormatForTesting, .bgra8Unorm_srgb)
        let sdr = try XCTUnwrap(view.currentDisplayForTesting)
        begin()
        view.handleSwipe(amount: -0.1, phase: .changed, isComplete: false)
        let hdr = try hdrTexture()
        XCTAssertEqual(hdr.encoding, .linearP3Half)
        view.setSwipeNeighbour(hdr, forward: true)
        XCTAssertEqual(view.layerPixelFormatForTesting, .rgba16Float)
        view.handleSwipe(amount: -0.6, phase: .ended, isComplete: false)
        view.handleSwipe(amount: -1, phase: [], isComplete: true)
        XCTAssertEqual(view.layerPixelFormatForTesting, .rgba16Float, "the HDR photo is current")
        // Swipe back to the SDR photo.
        view.beginSwipe(isDirectionInverted: true, hasNext: true, hasPrevious: true)
        view.handleSwipe(amount: 0.3, phase: .changed, isComplete: false)
        view.setSwipeNeighbour(sdr, forward: false)
        view.handleSwipe(amount: 0.7, phase: .ended, isComplete: false)
        view.handleSwipe(amount: 1, phase: [], isComplete: true)
        XCTAssertEqual(view.layerPixelFormatForTesting, .bgra8Unorm_srgb)
    }
}
