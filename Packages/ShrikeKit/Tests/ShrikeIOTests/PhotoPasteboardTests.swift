//
//  PhotoPasteboardTests.swift
//  ShrikeIOTests
//
//  A private named pasteboard only — never
//  `.general`.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os
import ShrikeCore
@testable import ShrikeIO

@MainActor
final class PhotoPasteboardTests: XCTestCase {

    private var folder: URL!
    private var pasteboard: NSPasteboard!
    private let reads = OSAllocatedUnfairLock<[String]>(initialState: [])

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasteboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.shrike.tests.\(UUID().uuidString)"))
        let reads = self.reads
        PhotoPasteboard.readHook = { url, type in
            reads.withLock { $0.append("\(url.lastPathComponent):\(type.rawValue)") }
        }
    }

    override func tearDown() async throws {
        PhotoPasteboard.readHook = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 60 × 40 image in `type`, EXIF orientation 6 when the format has it.
    private func makeFile(_ name: String, type: UTType) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func types(_ item: NSPasteboardItem) -> [String] { item.types.map(\.rawValue) }

    func testTypesPerFormat() throws {
        let jpeg = try makeFile("a.jpg", type: .jpeg)
        let png = try makeFile("b.png", type: .png)
        let heic = try makeFile("c.heic", type: .heic)
        let tiff = try makeFile("d.tiff", type: .tiff)
        let gif = try makeFile("e.gif", type: .gif)
        let bmp = try makeFile("f.bmp", type: .bmp)

        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: jpeg))),
                       ["public.file-url", "public.jpeg", "public.png"])
        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: png))),
                       ["public.file-url", "public.png"])
        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: heic))),
                       ["public.file-url", "public.heic", "public.png"])
        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: tiff))),
                       ["public.file-url", "public.tiff", "public.png"])
        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: gif))),
                       ["public.file-url", "com.compuserve.gif", "public.png"])
        // Other formats: file URL and a PNG only.
        XCTAssertEqual(types(PhotoPasteboard.item(for: ImageGroup(primary: bmp))),
                       ["public.file-url", "public.png"])
        // Nothing private.
        XCTAssertFalse(types(PhotoPasteboard.item(for: ImageGroup(primary: jpeg)))
            .contains(PhotoPasteboard.groupIDsType.rawValue))
        XCTAssertEqual(PhotoPasteboard.groupIDsType.rawValue, "app.shrike.group-ids")
        XCTAssertEqual(reads.withLock { $0 }, [], "building items reads nothing")
    }

    func testWrite_isLazyUntilAPasteAsks() throws {
        let jpeg = try makeFile("photo.jpg", type: .jpeg)
        let png = try makeFile("shot.png", type: .png)
        // The RAW companion never travels: only the primary.
        let raw = folder.appendingPathComponent("photo.orf")
        try Data("raw".utf8).write(to: raw)
        let groups = [ImageGroup(primary: jpeg, companions: [.init(url: raw, kind: .raw)]),
                      ImageGroup(primary: png)]

        PhotoPasteboard.write(groups, to: pasteboard)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].types.first, .fileURL)
        XCTAssertEqual(items[0].string(forType: .fileURL), jpeg.absoluteString)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["photo.jpg", "shot.png"])
        XCTAssertEqual(reads.withLock { $0 }, [], "nothing read or decoded before a paste asks")

        // A paste asks for the JPEG bytes: exactly the file, read once.
        let bytes = try XCTUnwrap(items[0].data(forType: NSPasteboard.PasteboardType("public.jpeg")))
        XCTAssertEqual(bytes, try Data(contentsOf: jpeg))
        XCTAssertEqual(reads.withLock { $0 }, ["photo.jpg:public.jpeg"])

        // A paste asks for PNG: a full-resolution, oriented decode.
        let pngData = try XCTUnwrap(items[0].data(forType: .png))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(pngData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.width, 40, "orientation 6 applied")
        XCTAssertEqual(image.height, 60)
        XCTAssertEqual(reads.withLock { $0 }, ["photo.jpg:public.jpeg", "photo.jpg:public.png"])

        // The PNG file's PNG type is its own bytes, not a re-encode.
        let second = try XCTUnwrap(items[1].data(forType: .png))
        XCTAssertEqual(second, try Data(contentsOf: png))
    }
}
