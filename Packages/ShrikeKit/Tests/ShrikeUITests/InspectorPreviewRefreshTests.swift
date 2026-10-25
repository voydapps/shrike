//
//  InspectorPreviewRefreshTests.swift
//  ShrikeUITests
//
//  The Browser's side panel shows the file again when it changed on disk
//  (a photo rotated in place showed its old upright picture until it was
//  selected again).
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class InspectorPreviewRefreshTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-prevrefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testPreviewReadsAChangedFileAgain() async throws {
        let url = dir.appendingPathComponent("a.png")
        try write(SaveFlowTests.image(width: 40, height: 20), to: url)
        let view = InspectorPreviewImageView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        view.show(url)
        await view.waitForLoad()
        XCTAssertEqual(view.image?.size.width ?? 0, 40)

        // Rotated in place: same path, new pixels.
        try write(SaveFlowTests.image(width: 20, height: 40), to: url)
        view.show(url)   // the same URL: ignored, as before
        await view.waitForLoad()
        XCTAssertEqual(view.image?.size.width ?? 0, 40, "show() alone keeps the old picture")

        XCTAssertTrue(view.isShowing([url]))
        XCTAssertFalse(view.isShowing([dir.appendingPathComponent("other.png")]))
        view.reloadIfShowing([url], lookups: nil)
        await view.waitForLoad()
        XCTAssertEqual(view.image?.size.width ?? 0, 20, "the changed file is read again")
        XCTAssertEqual(view.image?.size.height ?? 0, 40)
    }

    func testPreviewOfAnotherFileIsLeftAlone() async throws {
        let url = dir.appendingPathComponent("a.png")
        try write(SaveFlowTests.image(width: 40, height: 20), to: url)
        let view = InspectorPreviewImageView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        view.show(url)
        await view.waitForLoad()
        let before = view.image
        view.reloadIfShowing([dir.appendingPathComponent("zzz.png")], lookups: nil)
        await view.waitForLoad()
        XCTAssertTrue(view.image === before)
    }

    func testRatingOrTagWriteDoesNotReloadButARewriteDoes() async throws {
        let url = dir.appendingPathComponent("a.png")
        try write(SaveFlowTests.image(width: 40, height: 20), to: url)
        let view = InspectorPreviewImageView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        view.show(url)
        await view.waitForLoad()
        let before = view.image
        XCTAssertFalse(view.shownFileContentChanged())

        // A rating / flag / tag is an extended attribute: size and content date stay.
        let value = Data("x".utf8)
        let rc = value.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:test", $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(rc, 0)
        XCTAssertFalse(view.shownFileContentChanged(), "an xattr write is not a content change")
        view.reloadIfShowing([url], lookups: nil)
        await view.waitForLoad()
        XCTAssertTrue(view.image === before, "no reload, no new decode")

        try write(SaveFlowTests.image(width: 20, height: 40), to: url)
        XCTAssertTrue(view.shownFileContentChanged())
        view.reloadIfShowing([url], lookups: nil)
        await view.waitForLoad()
        XCTAssertEqual(view.image?.size.width ?? 0, 20)
        XCTAssertFalse(view.shownFileContentChanged(), "the new content is the baseline")
    }
}
