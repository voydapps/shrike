//
//  RotatedStoredFrameTests.swift
//  ShrikeCoreTests
//
//  Rotated JPEGs decode their stored pixels on
//  the fast path, the preparer turns them on the GPU, and the entry keeps
//  a lazy, already-rotated CPU twin.
//

import XCTest
import CoreGraphics
import ImageIO
@testable import ShrikeCore

private struct OrientedStub: PreparedDisplayImage {
    let byteCount: Int
    let orientation: CGImagePropertyOrientation
    let storedWidth: Int
    let sourceSize: (width: Int, height: Int)
}

private struct UprightStub: PreparedDisplayImage { let byteCount: Int }

final class RotatedStoredFrameTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(orientation: UInt32, width: Int = 400, height: Int = 240) throws -> FileImageSource {
        let url = dir.appendingPathComponent("o\(orientation).jpg")
        try OrientedImageFixtures.write(OrientedImageFixtures.quadrants(width: width, height: height),
                                        to: url, orientation: orientation)
        return FileImageSource(url: url)
    }

    func testUprightFileHasNoRotatedFrame() throws {
        XCTAssertNil(try jpeg(orientation: 1).decodeRotatedStoredFrame(targetLongEdge: 200))
    }

    func testRotatedFrameIsStoredPixelsAtTheFastSubsample() throws {
        let file = try jpeg(orientation: 6)
        let frame = try XCTUnwrap(file.decodeRotatedStoredFrame(targetLongEdge: 200))
        XCTAssertEqual(frame.orientation, .right)
        XCTAssertEqual(frame.orientedWidth, 240)
        XCTAssertEqual(frame.orientedHeight, 400)
        // Stored frame (not rotated), subsampled by 2: 400 / 2 >= 200.
        XCTAssertEqual(frame.image.width, 200)
        XCTAssertEqual(frame.image.height, 120)
    }

    /// The lazy twin decodes nothing up front, and once read it holds the
    /// same pixels the old eager path (thumbnail + transform) produced.
    func testLazyTwinMatchesTheOldOrientedDecode() throws {
        for orientation: UInt32 in 2...8 {
            let file = try jpeg(orientation: orientation)
            let frame = try XCTUnwrap(file.decodeRotatedStoredFrame(targetLongEdge: 300))
            let twin = try XCTUnwrap(file.lazyOrientedDisplayImage(frame: frame, targetLongEdge: 300))
            let old = try file.decodeDisplayImage(targetLongEdge: 300)
            XCTAssertEqual(twin.width, old.width, "orientation \(orientation)")
            XCTAssertEqual(twin.height, old.height, "orientation \(orientation)")
            XCTAssertLessThan(OrientedImageFixtures.meanAbsDiff(twin, old), 1.0, "orientation \(orientation)")
            for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                XCTAssertLessThanOrEqual(
                    OrientedImageFixtures.sample(twin, fx, fy).distance(to: OrientedImageFixtures.sample(old, fx, fy)),
                    2, "orientation \(orientation) at \(fx),\(fy)")
            }
        }
    }

    func testLazyPixelsDecodeOnFirstReadOnly() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.withLock { n += 1 } }
        }
        let counter = Counter()
        let src = OrientedImageFixtures.quadrants(width: 20, height: 10)
        let twin = try XCTUnwrap(LazyOrientedPixels.makeImage(
            width: 20, height: 10, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            decode: { counter.bump(); return src }
        ))
        XCTAssertEqual(counter.n, 0, "no decode before the pixels are read")
        _ = OrientedImageFixtures.pixels(twin)
        _ = OrientedImageFixtures.pixels(twin)
        XCTAssertEqual(counter.n, 1, "decoded once, then kept")
        XCTAssertLessThan(OrientedImageFixtures.meanAbsDiff(twin, src), 0.5)
    }

    /// A PNG much larger than the target takes the
    /// thumbnail path; its entry keeps a lazy twin, not the decoded pixels.
    func testThumbnailPathDecodeKeepsALazyTwin() throws {
        let url = dir.appendingPathComponent("big.png")
        try OrientedImageFixtures.write(OrientedImageFixtures.quadrants(width: 800, height: 480),
                                        to: url, type: .png)
        let file = FileImageSource(url: url)
        let preparer = DisplayPreparer({ _, _ in UprightStub(byteCount: 1000) })
        let entry = try DecodeQueue.makeEntry(file: file, id: "big", target: 200, preparer: preparer)
        XCTAssertTrue(entry.imageIsLazy)
        let eager = try file.decodeImage(maxPixelSize: 200)
        XCTAssertEqual(entry.image.width, eager.width)
        XCTAssertEqual(entry.image.height, eager.height)
        XCTAssertLessThan(OrientedImageFixtures.meanAbsDiff(entry.image, eager), 1.0)
    }

    func testMakeEntryUsesTheOrientedPreparerForRotatedFiles() throws {
        let file = try jpeg(orientation: 8)
        let preparer = DisplayPreparer(
            oriented: { stored, orientation, size, _ in
                OrientedStub(byteCount: 7, orientation: orientation, storedWidth: stored.width, sourceSize: size)
            },
            { _, _ in UprightStub(byteCount: 1) }
        )
        let entry = try DecodeQueue.makeEntry(file: file, id: file.id, target: 300, preparer: preparer)
        let stub = try XCTUnwrap(entry.prepared as? OrientedStub)
        XCTAssertEqual(stub.orientation, .left)
        XCTAssertEqual(stub.storedWidth, 400, "stored pixels, not rotated on the CPU")
        XCTAssertEqual(stub.sourceSize.width, entry.image.width)
        XCTAssertEqual(stub.sourceSize.height, entry.image.height)
        XCTAssertTrue(entry.imageIsLazy)
        XCTAssertEqual(entry.byteCount, 7, "a lazy twin costs nothing until read")
        XCTAssertEqual(entry.image.width, 180)
        XCTAssertEqual(entry.image.height, 300)
    }

    func testMakeEntryKeepsTheOldPathWithoutAnOrientedPreparer() throws {
        let file = try jpeg(orientation: 6)
        let entry = try DecodeQueue.makeEntry(
            file: file, id: file.id, target: 300,
            preparer: DisplayPreparer { _, _ in UprightStub(byteCount: 1) }
        )
        XCTAssertTrue(entry.prepared is UprightStub)
        XCTAssertEqual(entry.image.width, 180)
        XCTAssertEqual(entry.image.height, 300)
    }

    func testUprightFilesIgnoreTheOrientedPreparer() throws {
        let file = try jpeg(orientation: 1)
        let preparer = DisplayPreparer(
            oriented: { _, o, s, _ in OrientedStub(byteCount: 7, orientation: o, storedWidth: 0, sourceSize: s) },
            { _, _ in UprightStub(byteCount: 1) }
        )
        let entry = try DecodeQueue.makeEntry(file: file, id: file.id, target: 300, preparer: preparer)
        XCTAssertTrue(entry.prepared is UprightStub)
    }
}
