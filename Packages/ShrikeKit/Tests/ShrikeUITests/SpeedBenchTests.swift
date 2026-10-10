//
//  SpeedBenchTests.swift
//  ShrikeUITests
//
//  Headless timing of the core pieces on two user-facing paths:
//    * the cold open of one photo (services, DB, scan, first decode);
//    * the full-resolution decode used when the user zooms past the
//      display texture.
//  Skipped unless `SHRIKE_BENCH_DIR` points at a folder with `jpg/` (18 MP
//  JPEGs) and optionally `orf/` subfolders. Run alone for a fresh process:
//
//    SHRIKE_BENCH_DIR=<scratchpad>/perf-photos swift test --filter SpeedBenchTests
//
//  Everything Shrike writes goes under `ShrikeDataPaths` (a temp folder
//  under XCTest).
//

import XCTest
import CoreGraphics
import ImageIO
@testable import ShrikeCore
import ShrikeIO
import ShrikeRendering
@testable import ShrikeUI

final class SpeedBenchTests: XCTestCase {

    private var benchDir: URL {
        get throws {
            guard let path = ProcessInfo.processInfo.environment["SHRIKE_BENCH_DIR"] else {
                throw XCTSkip("set SHRIKE_BENCH_DIR to run speed benches")
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private func files(_ sub: String, ext: String) throws -> [URL] {
        let dir = try benchDir.appendingPathComponent(sub, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func ms(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    private func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

    /// Warm the file cache: the numbers measure decode, not the disk.
    private func warm(_ url: URL) { _ = try? Data(contentsOf: url) }

    // MARK: - Cold open

    func testColdOpenPieces() async throws {
        let jpgs = try files("jpg", ext: "jpg")
        guard let first = jpgs.first else { throw XCTSkip("no jpg folder") }
        let folder = first.deletingLastPathComponent()
        for url in jpgs { warm(url) }
        var rows: [(String, Double)] = []

        var t = DispatchTime.now()
        Prefs.removeRetiredKeys()
        rows.append(("Prefs.removeRetiredKeys", ms(t)))

        t = DispatchTime.now()
        let services = ShrikeServices.makeDefault()
        rows.append(("ShrikeServices.makeDefault (first, fresh DB)", ms(t)))

        let dbURL = ShrikeDataPaths.applicationSupport.appendingPathComponent("metadata.sqlite")
        t = DispatchTime.now()
        let reopened = MetadataStore.openWithFallback(primary: dbURL, fallback: nil)
        rows.append(("MetadataStore open, existing DB", ms(t)))
        _ = reopened

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        t = DispatchTime.now()
        let fresh = MetadataStore.openWithFallback(
            primary: scratch.appendingPathComponent("m.sqlite"), fallback: nil)
        rows.append(("MetadataStore open + all migrations", ms(t)))
        _ = fresh

        t = DispatchTime.now()
        _ = try ThumbnailCache(diskURL: scratch.appendingPathComponent("thumbs", isDirectory: true))
        rows.append(("ThumbnailCache init", ms(t)))

        t = DispatchTime.now()
        _ = BackupStore(root: scratch.appendingPathComponent("backups", isDirectory: true))
        rows.append(("BackupStore init", ms(t)))

        t = DispatchTime.now()
        let groups = try await FolderScanner.imageGroups(in: folder, including: first)
        rows.append(("FolderScanner.imageGroups (\(groups.count) files, first)", ms(t)))

        t = DispatchTime.now()
        let listed = await WindowCoordinator.viewerList(for: [first], showHidden: false)
        rows.append(("WindowCoordinator.viewerList (again)", ms(t)))
        XCTAssertEqual(listed.groups.count, groups.count)

        let file = FileImageSource(url: first)
        t = DispatchTime.now()
        let img = try file.decodeDisplayImage(targetLongEdge: 2560)
        rows.append(("first display decode 2560 (\(img.width)x\(img.height))", ms(t)))

        var warmDecodes: [Double] = []
        for url in jpgs.dropFirst().prefix(5) {
            let t2 = DispatchTime.now()
            _ = try FileImageSource(url: url).decodeDisplayImage(targetLongEdge: 2560)
            warmDecodes.append(ms(t2))
        }
        rows.append(("display decode 2560, median of 5 more", median(warmDecodes)))

        // The queue path the viewer takes: setNavigation + jumpToEntry,
        // with the real texture builder.
        let queue = services.makeDecodeQueue(preparer: DisplayTextureFactory.preparer)
        await queue.setMaxLongEdge(2560)
        let sources: [any ImageSource] = jpgs.dropFirst(10).map { FileImageSource(url: $0) }
        t = DispatchTime.now()
        await queue.setNavigation(list: sources, currentIndex: 0)
        let entry = try await queue.jumpToEntry(index: 0)
        rows.append(("DecodeQueue setNavigation + jumpToEntry + texture", ms(t)))
        XCTAssertNotNil(entry.prepared)

        print("BENCH cold-open pieces (ms):")
        for (name, value) in rows { print("BENCH  \(name): \(fmt(value))") }
    }

    // MARK: - Full resolution

    func testFullResolutionDecode() async throws {
        let jpgs = Array(try files("jpg", ext: "jpg").prefix(5))
        let orfs = Array(try files("orf", ext: "orf").prefix(1))
        guard !jpgs.isEmpty else { throw XCTSkip("no jpg folder") }
        var sets: [(String, [URL])] = [("JPEG 18 MP", jpgs)]
        if !orfs.isEmpty { sets.append(("ORF", Array(repeating: orfs[0], count: 5))) }

        for (label, urls) in sets {
            for url in urls { warm(url) }
            let sources: [any ImageSource] = urls.map { FileImageSource(url: $0) }
            let queue = DecodeQueue(windowRadius: 1, preparer: DisplayTextureFactory.preparer)
            await queue.setNavigation(list: sources, currentIndex: 0)
            var ready: [Double] = []
            var textured: [Double] = []
            var size = ""
            for i in sources.indices {
                // The user looks at the photo, then zooms: the window's
                // prefetch has settled by then. Both variants run after
                // the same idle gap (the CPU clocks down while idle).
                let gap: Duration = .milliseconds(label == "ORF" ? 1500 : 400)
                _ = try await queue.jumpToEntry(index: i)
                try await Task.sleep(for: gap)
                // Before: the old `loadFullRes` (lazy `CreateImageAtIndex`)
                // + a texture built by the caller.
                let t0 = DispatchTime.now()
                let old = try FileImageSource(url: urls[i]).decodeImage(maxPixelSize: nil)
                _ = DisplayTextureFactory.make(from: old, commandQueue: nil,
                                               waitUntilCompleted: true, maxLongEdge: nil)
                textured.append(ms(t0))
                try await Task.sleep(for: gap)
                let t = DispatchTime.now()
                let full = try await queue.loadFullResolution(at: i)
                ready.append(ms(t))
                XCTAssertNotNil(full.prepared)
                size = "\(full.image.width)x\(full.image.height), lazy \(full.imageIsLazy)"
            }
            print("BENCH full-res \(label) [\(size)]: BEFORE loadFullRes + caller texture \(fmt(median(textured))) ms; AFTER loadFullResolution (texture included) \(fmt(median(ready))) ms (median of \(ready.count))")
        }
    }

    /// Rotated JPEG (an EXIF-6 copy of a perf photo) and RAW: both full-
    /// resolution paths, decode + texture.
    func testFullResolutionRotatedPaths() throws {
        let jpgs = try files("jpg", ext: "jpg")
        guard let jpg = jpgs.first else { throw XCTSkip("no jpg folder") }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-rot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rotated = tmp.appendingPathComponent("rot6.jpg")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(rotated as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(dst, src, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        var cases: [(String, URL)] = [("JPEG EXIF 6", rotated)]
        if let orf = try files("orf", ext: "orf").first { cases.append(("ORF", orf)) }
        for (label, url) in cases {
            warm(url)
            let file = FileImageSource(url: url)
            for path in [FileImageSource.FullResolutionPath.thumbnailTransform, .decodeThenDraw] {
                var ready: [Double] = [], textured: [Double] = []
                var size = ""
                for _ in 0..<5 {
                    let t = DispatchTime.now()
                    let img = try file.decodeFullResolution(rotatedPath: path)
                    ready.append(ms(t))
                    _ = DisplayTextureFactory.make(from: img, commandQueue: nil,
                                                   waitUntilCompleted: true, maxLongEdge: nil)
                    textured.append(ms(t))
                    size = "\(img.width)x\(img.height)"
                }
                print("BENCH full-res \(label) \(path) [\(size)]: pixels ready \(fmt(median(ready))) ms, + texture \(fmt(median(textured))) ms")
            }
            // Old path: lazy CreateImageAtIndex, no orientation.
            var old: [Double] = []
            for _ in 0..<5 {
                let t = DispatchTime.now()
                let img = try file.decodeImage(maxPixelSize: nil)
                _ = DisplayTextureFactory.make(from: img, commandQueue: nil,
                                               waitUntilCompleted: true, maxLongEdge: nil)
                old.append(ms(t))
            }
            print("BENCH full-res \(label) BEFORE (lazy, unrotated) + texture: \(fmt(median(old))) ms")
        }
    }
}
