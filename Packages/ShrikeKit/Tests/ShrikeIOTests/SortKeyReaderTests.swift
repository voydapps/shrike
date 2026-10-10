//
//  SortKeyReaderTests.swift
//  ShrikeIOTests
//
//  A.19. Temp folders only.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeIO

final class SortKeyReaderTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sortkeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A small JPEG, optionally with an EXIF capture date ("yyyy:MM:dd HH:mm:ss").
    @discardableResult
    private func jpeg(_ name: String, width: Int = 40, height: Int = 30, captured: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let captured {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: captured,
                                                     kCGImagePropertyExifOffsetTimeOriginal: "+00:00"]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func collect(_ stream: AsyncStream<[URL: SortValue]>) async -> [[URL: SortValue]] {
        var batches: [[URL: SortValue]] = []
        for await batch in stream { batches.append(batch) }
        return batches
    }

    private func store() throws -> MetadataStore {
        try MetadataStore(databaseURL: folder.appendingPathComponent("meta.sqlite"), writeFileAttributes: { false })
    }

    private func utc(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)!
    }

    // MARK: SortValue

    func testSortValue_naturalOrder_missingLast() {
        XCTAssertLessThan(SortValue.text("IMG_2.jpg"), .text("IMG_10.jpg"))
        XCTAssertLessThan(SortValue.text("apple"), .text("Banana"))
        XCTAssertLessThan(SortValue.number(5), .number(10))
        XCTAssertLessThan(SortValue.date(Date(timeIntervalSince1970: 1)), .date(Date(timeIntervalSince1970: 2)))
        XCTAssertLessThan(SortValue.number(Int64.max), .missing)
        XCTAssertFalse(SortValue.missing < .missing)
        XCTAssertEqual([SortValue.missing, .text("b"), .text("a10"), .text("a9")].sorted(),
                       [.text("a9"), .text("a10"), .text("b"), .missing])
    }

    func testSorted_missingLastBothWays_tiesByName() {
        let a = ImageGroup(primary: URL(fileURLWithPath: "/x/a.jpg"))
        let b = ImageGroup(primary: URL(fileURLWithPath: "/x/b.jpg"))
        let c = ImageGroup(primary: URL(fileURLWithPath: "/x/c.jpg"))
        let d = ImageGroup(primary: URL(fileURLWithPath: "/x/d.jpg"))
        let values: [URL: SortValue] = [a.primary: .number(2), b.primary: .missing,
                                        c.primary: .number(1), d.primary: .number(2)]
        XCTAssertEqual(SortKeyReader.sorted([b, d, a, c], by: values, ascending: true), [c, a, d, b])
        XCTAssertEqual(SortKeyReader.sorted([b, d, a, c], by: values, ascending: false), [a, d, c, b])
    }

    // MARK: Reading

    func testBatchesOf500_keyedByPrimary() async {
        let groups = (0..<1_200).map { i in
            ImageGroup(primary: folder.appendingPathComponent("IMG_\(i).jpg"),
                       companions: [.init(url: folder.appendingPathComponent("IMG_\(i).orf"), kind: .raw)])
        }
        let reader = SortKeyReader(metadata: nil)
        let batches = await collect(await reader.values(for: groups, key: .name))
        XCTAssertEqual(batches.map(\.count), [500, 500, 200])
        let all = batches.reduce(into: [URL: SortValue]()) { $0.merge($1) { a, _ in a } }
        XCTAssertEqual(all[groups[7].primary], .text("IMG_7.jpg"))
        XCTAssertNil(all[groups[7].companions[0].url])
    }

    func testHeaderKeys_fileKeys_andFallbacks() async throws {
        let old = try jpeg("old.jpg", width: 40, height: 30, captured: "2020:01:02 03:04:05")
        let new = try jpeg("new.jpg", width: 100, height: 10, captured: "2024:06:07 08:09:10")
        let plain = try jpeg("plain.jpg", width: 20, height: 20)
        let junk = folder.appendingPathComponent("junk.jpg")
        try Data("not an image".utf8).write(to: junk)
        let groups = [old, new, plain, junk].map { ImageGroup(primary: $0) }
        let meta = try store()
        try await meta.setRating(4, for: new)
        let reader = SortKeyReader(metadata: meta)

        func values(_ key: SortKey) async -> [URL: SortValue] {
            await collect(await reader.values(for: groups, key: key)).first ?? [:]
        }
        let captured = await values(.dateCaptured)
        XCTAssertEqual(captured[old], .date(utc("2020:01:02 03:04:05")))
        XCTAssertEqual(captured[new], .date(utc("2024:06:07 08:09:10")))
        // No EXIF date: the file's creation date.
        let created = try XCTUnwrap(plain.resourceValues(forKeys: [.creationDateKey]).creationDate)
        XCTAssertEqual(captured[plain], .date(created))

        let dims = await values(.dimensions)
        XCTAssertEqual(dims[old], .number(1_200))
        XCTAssertEqual(dims[new], .number(1_000))
        XCTAssertEqual(dims[junk], .missing)

        let ratings = await values(.rating)
        XCTAssertEqual(ratings[new], .number(4))
        XCTAssertEqual(ratings[old], .number(0))

        let sizes = await values(.size)
        XCTAssertEqual(sizes[junk], .number(12))
        let kinds = await values(.kind)
        XCTAssertEqual(kinds[old], .text(UTType.jpeg.localizedDescription!))
        let modified = await values(.dateModified)
        if case .date = modified[old] {} else { XCTFail("dateModified") }
    }

    func testHeaderCache_reusedUntilTheFileChanges() async throws {
        let url = try jpeg("a.jpg", width: 40, height: 30, captured: "2021:01:01 00:00:00")
        let meta = try store()
        let reader = SortKeyReader(metadata: meta)
        let groups = [ImageGroup(primary: url)]
        _ = await collect(await reader.values(for: groups, key: .dimensions))
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let cached = await meta.cachedHeaders(for: [url: modified])
        XCTAssertEqual(cached[url], ImageHeaderInfo(dateCaptured: utc("2021:01:01 00:00:00"),
                                                    pixelWidth: 40, pixelHeight: 30))

        // Same path, new content and mtime: the stale row is ignored.
        try FileManager.default.removeItem(at: url)
        try jpeg("a.jpg", width: 50, height: 50)
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(10)],
                                              ofItemAtPath: url.path)
        let dims = await collect(await reader.values(for: groups, key: .dimensions)).first
        XCTAssertEqual(dims?[url], .number(2_500))
    }

    func testCancellation_stopsBetweenBatches() async throws {
        let master = try jpeg("master.jpg", captured: "2022:02:02 02:02:02")
        let groups = try (0..<2_000).map { i -> ImageGroup in
            let url = folder.appendingPathComponent("c\(i).jpg")
            try FileManager.default.copyItem(at: master, to: url)
            return ImageGroup(primary: url)
        }
        let reader = SortKeyReader(metadata: nil)
        let stream = await reader.values(for: groups, key: .dateCaptured)
        let consumer = Task { () -> Int in
            var n = 0
            for await _ in stream {
                n += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return n
        }
        let received = await consumer.value
        XCTAssertEqual(received, 1, "no batch after the cancel")
    }

    /// Timing print: 2,000 files, first pass (headers read) vs cached pass.
    func testTiming_2000Files_firstVsCached() async throws {
        let master = try jpeg("master.jpg", width: 64, height: 48, captured: "2023:03:03 03:03:03")
        let groups = try (0..<2_000).map { i -> ImageGroup in
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            try FileManager.default.copyItem(at: master, to: url)
            return ImageGroup(primary: url)
        }
        let reader = SortKeyReader(metadata: try store())
        let clock = ContinuousClock()
        var first: [[URL: SortValue]] = []
        let t1 = try await clock.measure {
            first = await collect(await reader.values(for: groups, key: .dateCaptured))
        }
        var second: [[URL: SortValue]] = []
        let t2 = try await clock.measure {
            second = await collect(await reader.values(for: groups, key: .dateCaptured))
        }
        print("[sortkeys] 2,000 files dateCaptured: first pass \(t1), cached pass \(t2)")
        XCTAssertEqual(first.map(\.count), [500, 500, 500, 500])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[0][groups[0].primary], .date(utc("2023:03:03 03:03:03")))
    }
}

private extension ContinuousClock {
    func measure(_ work: () async throws -> Void) async throws -> Duration {
        let start = now
        try await work()
        return now - start
    }
}
