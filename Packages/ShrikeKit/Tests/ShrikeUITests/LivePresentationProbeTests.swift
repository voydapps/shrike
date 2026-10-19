import AppKit
import Metal
import XCTest
import ShrikeCore
import ShrikeRendering

private actor PresentationDecodeGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func presentationProbeImage() throws -> CGImage {
    guard let context = CGContext(data: nil, width: 128, height: 128,
                                  bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.coderInvalidValue)
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
    return image
}

private struct GatedPresentationSource: ImageSource {
    let id: String
    let gate: PresentationDecodeGate
    var displayName: String { "Presentation probe" }
    var fileSize: Int64? { 0 }
    var mtime: Date? { nil }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        await gate.hold()
        try Task.checkCancellation()
        return try presentationProbeImage()
    }
    func loadProperties() async throws -> ImageProperties {
        ImageProperties(pixelWidth: 128, pixelHeight: 128, orientation: .up,
                        colorSpaceName: "sRGB", bitDepth: 8, hasAlpha: true,
                        exif: nil, utType: .png, fileSize: 0)
    }
}

/// Visible-hardware integration evidence, separate from the pure launch-state
/// reducer and from the AppDelegate's full cold-open path. Run alone on an
/// unlocked console: SHRIKE_PRESENTATION_PROBE=1 swift test --filter LivePresentationProbeTests.
@MainActor
final class LivePresentationProbeTests: XCTestCase {
    @MainActor private final class Observations: MetalImageViewDelegate {
        var drawableSeen = false
        var realFrames: [TimeInterval] = []
        func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) {
            drawableSeen = true
        }
    }
    private struct Sample {
        let heldSeconds: Double
        let entryToPhoto: Double
        let releaseToPhoto: Double
    }

    private func waitUntil(_ ready: () -> Bool, message: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard ready() else {
            XCTFail(message)
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func sample(hold: Duration) async throws -> Sample {
        let observations = Observations()
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Shrike live presentation probe"
        window.contentView = view
        view.delegate = observations
        defer {
            view.delegate = nil
            view.onFirstImagePresented = nil
            view.releaseResources()
            window.orderOut(nil)
            window.close()
        }
        view.onFirstImagePresented = { observations.realFrames.append(ProcessInfo.processInfo.systemUptime) }
        view.setPlaceholderImage(try presentationProbeImage(), sourceID: "probe-placeholder")
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try await waitUntil({ observations.drawableSeen }, message: "No actual visible placeholder drawable presented")
        XCTAssertTrue(observations.realFrames.isEmpty, "A placeholder must not finish real-photo presentation")

        let gate = PresentationDecodeGate()
        let source = GatedPresentationSource(id: "probe-\(UUID())", gate: gate)
        let queue = DecodeQueue(windowRadius: 1, preparer: DisplayTextureFactory.preparer)
        await queue.setNavigation(list: [source], currentIndex: 0)
        let request = Task { try await queue.jumpToEntry(index: 0) }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while !(await gate.entered), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard await gate.entered else { throw CocoaError(.coderInvalidValue) }
            let enteredAt = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: hold)
            XCTAssertTrue(observations.realFrames.isEmpty, "Held decode/placeholder cannot report a real photo")
            let releasedAt = ProcessInfo.processInfo.systemUptime
            await gate.release()
            let decoded = try await request.value
            XCTAssertNotNil(decoded.prepared as? DisplayTexture,
                            "The real DecodeQueue must prepare a GPU texture before presentation")
            view.setImage(decoded.image, sourceID: source.id, prepared: decoded.prepared as? DisplayTexture,
                          resourceLease: decoded.resourceLease, imageIsLazy: decoded.imageIsLazy)
            try await waitUntil({ !observations.realFrames.isEmpty }, message: "Real decoded image never reached a presented drawable")
            let photoAt = try XCTUnwrap(observations.realFrames.first)
            XCTAssertGreaterThanOrEqual(photoAt, releasedAt)
            view.setImage(decoded.image, sourceID: source.id, prepared: decoded.prepared as? DisplayTexture,
                          resourceLease: decoded.resourceLease, imageIsLazy: decoded.imageIsLazy)
            try await Task.sleep(for: .milliseconds(75))
            XCTAssertEqual(observations.realFrames.count, 1, "First-photo callback is per view, not per redraw")
            await queue.purge()
            return Sample(heldSeconds: releasedAt - enteredAt, entryToPhoto: photoAt - enteredAt,
                          releaseToPhoto: photoAt - releasedAt)
        } catch {
            await gate.release()
            request.cancel()
            _ = try? await request.value
            await queue.purge()
            throw error
        }
    }

    func testHeldDecodeDelaysActualPhotoButNeverPromotesPlaceholder() async throws {
        guard ProcessInfo.processInfo.environment["SHRIKE_PRESENTATION_PROBE"] == "1" else {
            throw XCTSkip("Set SHRIKE_PRESENTATION_PROBE=1 for the isolated visible-Metal integration probe")
        }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        _ = NSApplication.shared
        let immediate = try await sample(hold: .zero)
        let delayed = try await sample(hold: .seconds(1))
        XCTAssertGreaterThanOrEqual(delayed.heldSeconds, 0.95)
        XCTAssertGreaterThanOrEqual(delayed.entryToPhoto - immediate.entryToPhoto, 0.8,
                                    "The controlled one-second decode hold must shift actual photo presentation")
        print("LIVE_PRESENTATION immediate entryToPhotoMs=\(immediate.entryToPhoto * 1000) releaseToPhotoMs=\(immediate.releaseToPhoto * 1000)")
        print("LIVE_PRESENTATION delayed heldMs=\(delayed.heldSeconds * 1000) entryToPhotoMs=\(delayed.entryToPhoto * 1000) releaseToPhotoMs=\(delayed.releaseToPhoto * 1000)")
    }
}
