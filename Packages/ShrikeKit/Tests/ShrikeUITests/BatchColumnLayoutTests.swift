//
//  BatchColumnLayoutTests.swift
//  ShrikeUITests
//
//  Batch running and done screens share one centred 560 pt column at a
//  fixed top; the counter is one line under the bar; the queue heading
//  starts where the row names start.
//

import SwiftUI
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

@MainActor
final class BatchColumnLayoutTests: XCTestCase {
    private var dir: URL!
    private var backups: BackupStore!
    private let sizes = [CGSize(width: 880, height: 600), CGSize(width: 760, height: 520)]

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-col-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backups = BackupStore(root: dir.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Fixtures

    private func makeModel() -> BatchModel {
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        return BatchModel(runner: runner, presetStore: BatchPresetStore(fileURL: dir.appendingPathComponent("p.plist")))
    }

    private func jpeg(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A finished model: calm (all converted) or with one skipped WebP.
    private func finishedModel(withSkip: Bool) async throws -> BatchModel {
        var urls = [try jpeg("a.jpg"), try jpeg("b.jpg")]
        if withSkip {
            let webp = dir.appendingPathComponent("z.webp")
            try Data([0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
                      0x56, 0x50, 0x38, 0x4c, 0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
                      0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0x00]).write(to: webp)
            urls.append(webp)
        }
        let model = makeModel()
        model.add(urls.map { ImageGroup(primary: $0) })
        if withSkip {
            model.form.convertOn = false; model.form.resizeOn = false; model.form.renameOn = false
            model.form.rotateOn = true
        } else {
            model.form.format = .png
        }
        for _ in 0..<500 where !model.canRun { try await Task.sleep(for: .milliseconds(10)) }
        model.run()
        await model.waitForRun()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.skippedRows.isEmpty, !withSkip)
        return model
    }

    // MARK: Pixel scans (point units)

    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let bg: CGFloat
        func level(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            return c.redComponent + c.greenComponent + c.blueComponent + c.alphaComponent
        }
        func drawn(_ x: Int, _ y: Int) -> Bool { abs(level(x, y) - bg) > 0.1 }
        /// Topmost drawn row (pt) in the x range (pt) within the first `maxY` pt.
        func top(x: ClosedRange<CGFloat>, maxY: CGFloat) -> CGFloat? {
            for y in 0..<Int(maxY * scale) {
                for px in stride(from: Int(x.lowerBound * scale), to: Int(x.upperBound * scale), by: 1) where drawn(px, y) {
                    return CGFloat(y) / scale
                }
            }
            return nil
        }
        /// Leftmost drawn column (pt) within the y band (pt).
        func left(y: Range<CGFloat>, from: Int = 4, refX: Int? = nil) -> CGFloat? {
            let ref = level(refX ?? rep.pixelsWide - 2, Int(y.lowerBound * scale))
            for px in from..<rep.pixelsWide - 4 {
                for py in Int(y.lowerBound * scale)..<Int(y.upperBound * scale) where abs(level(px, py) - ref) > 0.1 {
                    return CGFloat(px) / scale
                }
            }
            return nil
        }
        /// The bar: the longest unbroken drawn run on any one row, widened to
        /// the extreme columns of the rows around it. The bar is a 6 pt
        /// capsule, so no single row of a 1x bitmap reaches the full width
        /// (the rounded end caps lose about 1 px per side on every row);
        /// only the whole band of rows together covers it.
        func longestRun(maxY: CGFloat) -> (start: CGFloat, end: CGFloat)? {
            func runs(_ y: Int) -> [(Int, Int)] {
                var out: [(Int, Int)] = []
                var s: Int?
                for px in 0...rep.pixelsWide {
                    let on = px < rep.pixelsWide && drawn(px, y)
                    if on, s == nil { s = px }
                    if !on, let from = s { out.append((from, px)); s = nil }
                }
                return out
            }
            var best: (row: Int, run: (Int, Int))?
            for y in 0..<Int(maxY * scale) {
                for r in runs(y) where best == nil || r.1 - r.0 > best!.run.1 - best!.run.0 { best = (y, r) }
            }
            guard let (row, run) = best.map({ ($0.row, $0.run) }) else { return nil }
            // Bar height is 6 pt and the next drawn thing is 8 pt below it.
            let reach = Int(3 * scale)
            let rows = max(0, row - reach)...(row + reach)
            // The track is a faint 12 % fill, so an end pixel that is only
            // part covered falls under the "drawn" threshold. Measure each
            // end by coverage instead: the share of the full bar level the
            // most covered pixel in the outermost column reaches.
            let full = abs(level((run.0 + run.1) / 2, row) - bg)
            func coverage(_ px: Int) -> CGFloat {
                guard px >= 0, px < rep.pixelsWide else { return 0 }
                return rows.map { min(1, abs(level(px, $0) - bg) / full) }.max() ?? 0
            }
            var lo = run.0, hi = run.1 - 1
            while coverage(lo - 1) > 0.05 { lo -= 1 }
            while coverage(hi + 1) > 0.05 { hi += 1 }
            let start = CGFloat(lo) + (1 - min(1, coverage(lo)))
            let end = CGFloat(hi) + min(1, coverage(hi))
            return (start / scale, end / scale)
        }
    }

    /// An empty bitmap with `scale` pixels per point (1 = a 1x CI screen).
    private func makeRep(_ size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        return rep
    }

    private func shoot<V: View>(_ view: V, _ size: CGSize, scale: CGFloat? = nil, then body: (Shot) throws -> Void) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try scale.map { try makeRep(size, scale: $0) }
            ?? XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var shot = Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width, bg: 0)
        shot = Shot(rep: rep, scale: shot.scale, bg: shot.level(2, 2))
        try body(shot)
    }

    private func columnLeft(_ w: CGFloat) -> CGFloat { (w - min(BatchLayout.columnWidth, w - 2 * BatchLayout.columnMargin)) / 2 }

    // MARK: Tests

    func testConstantsFollowTheSpec() {
        XCTAssertEqual(BatchLayout.columnWidth, 560)
        XCTAssertEqual(BatchLayout.columnTopInset, 56)
        XCTAssertEqual(BatchLayout.doneIconSize, 22)
        XCTAssertTrue((14...18).contains(BatchLayout.queueHeadingInset))
    }

    /// The bar is the column: same frame at both sizes, with and without the
    /// time text, and 560 wide, centred.
    func testBarIsTheCentredColumnAndIgnoresTheTimeText() throws {
        let model = makeModel()
        for size in sizes {
            var seen: [CGFloat: [CGFloat]] = [:]  // per scale: [start, end, start, end, ...]
            for (eta, scale) in [nil, "about 47 s left", "about 2 h 15 min left"].flatMap({ e in [1.0, 2.0].map { (e, CGFloat($0)) } }) {
                model.setEtaTextForTesting(eta)
                try shoot(BatchRunningView(model: model), size, scale: scale) { shot in
                    let bar = try XCTUnwrap(shot.longestRun(maxY: size.height * 0.6))
                    XCTAssertEqual(bar.end - bar.start, BatchLayout.columnWidth, accuracy: 1)
                    XCTAssertEqual(bar.start, self.columnLeft(size.width), accuracy: 1)
                    seen[scale, default: []] += [bar.start, bar.end]
                }
            }
            // Same scale, same frame whatever the time text says (the edge
            // estimate may differ by a sliver between runs, never by a pixel).
            for (scale, values) in seen {
                for i in stride(from: 0, to: values.count, by: 2) {
                    XCTAssertEqual(values[i], values[0], accuracy: 0.05, "bar start moved at \(size), \(scale)x: \(values)")
                    XCTAssertEqual(values[i + 1], values[1], accuracy: 0.05, "bar end moved at \(size), \(scale)x: \(values)")
                }
            }
        }
    }

    /// The title text starts at the same height when the batch ends.
    func testTitleTopDoesNotMoveFromRunningToDone() async throws {
        let calm = try await finishedModel(withSkip: false)
        let skipped = try await finishedModel(withSkip: true)
        for size in sizes {
            let left = columnLeft(size.width)
            let band = (left + 30)...(left + 400)
            for scale: CGFloat in [1, 2] {
                var tops: [CGFloat] = []
                try shoot(BatchRunningView(model: calm), size, scale: scale) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
                try shoot(BatchDoneView(model: calm, actions: BatchViewActions()), size, scale: scale) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
                try shoot(BatchDoneView(model: skipped, actions: BatchViewActions()), size, scale: scale) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
                for t in tops { XCTAssertEqual(t, tops[0], accuracy: 2, "title top at \(size), \(scale)x: \(tops)") }
                XCTAssertEqual(tops[0], BatchLayout.columnTopInset, accuracy: 6)
            }
        }
    }

    /// The joined counter line fits the column at both type steps.
    func testCounterLineFitsTheColumn() {
        for step: CGFloat in [13, 15] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: step, weight: .regular)
            let w = NSAttributedString(string: "12345 of 12345 · about 2 h 15 min left",
                                       attributes: [.font: font]).size().width
            XCTAssertLessThan(w, BatchLayout.columnWidth)
        }
    }

    /// The heading's first letter sits above the row names' first letter.
    func testQueueHeadingStartsWhereTheRowNamesStart() throws {
        let model = makeModel()
        model.add([ImageGroup(primary: try jpeg("IMG_0001.jpg")), ImageGroup(primary: try jpeg("IMG_0002.jpg"))])
        for scale: CGFloat in [1, 2] {
            try shoot(BatchQueuePane(model: model, actions: BatchViewActions()), CGSize(width: 280, height: 300), scale: scale) { shot in
                let heading = try XCTUnwrap(shot.left(y: 8..<26))
                let row = try XCTUnwrap(shot.left(y: 56..<90))
                XCTAssertEqual(heading, row, accuracy: 1.5, "\(scale)x")
                XCTAssertEqual(heading, BatchLayout.queueHeadingInset, accuracy: 1.5, "\(scale)x")
            }
        }
    }

    /// At the minimum window the queue pane starts at x >= 0 and sits fully
    /// inside the window, with a long output path and a name clash in the
    /// preview, at both type sizes; its heading starts where the row names do.
    func testQueuePaneFitsInsideTheMinimumWindow() throws {
        for larger in [false, true] {
            let old = Prefs.largerChrome
            Prefs.largerChrome = larger
            defer { Prefs.largerChrome = old }
            let model = makeModel()
            let a = try jpeg("IMG_0001.jpg"), b = try jpeg("IMG_0002.jpg")
            let out = dir.appendingPathComponent("Shrike Export", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: out.appendingPathComponent("IMG_0001.jpg").path) {
                try FileManager.default.copyItem(at: a, to: out.appendingPathComponent("IMG_0001.jpg"))
            }
            model.add([ImageGroup(primary: a), ImageGroup(primary: b)])
            model.form.renameOn = true
            model.form.template = "{yyyy-MM-dd}_{camera}_{lens}_{counter:0000}"
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let size = BatchWindowController.minContentSize
            let root = BatchRootView(model: model, actions: BatchViewActions(), inserter: BatchTokenInserter())
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            var scrolls: [NSRect] = []
            func walk(_ v: NSView) {
                if v is NSScrollView { scrolls.append(host.convert(v.bounds, from: v)) }
                v.subviews.forEach(walk)
            }
            walk(host)
            let pane = try XCTUnwrap(scrolls.first)
            XCTAssertGreaterThanOrEqual(pane.minX, 0, "queue list clipped on the left (larger \(larger))")
            XCTAssertLessThanOrEqual(pane.maxX, size.width)
            for r in scrolls { XCTAssertLessThanOrEqual(r.maxX, size.width + 0.5, "form column past the right edge (larger \(larger))") }
            for scale: CGFloat in [1, 2] {
                let rep = try makeRep(size, scale: scale)
                host.cacheDisplay(in: host.bounds, to: rep)
                let shot = Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width, bg: 0)
                let heading = try XCTUnwrap(shot.left(y: 8..<26, from: 8, refX: 6))
                let row = try XCTUnwrap(shot.left(y: 56..<90, from: 8, refX: 6))
                XCTAssertEqual(heading, row, accuracy: 1.5, "\(scale)x")
                XCTAssertEqual(heading, BatchLayout.queueHeadingInset, accuracy: 1.5, "\(scale)x")
            }
        }
    }
}
