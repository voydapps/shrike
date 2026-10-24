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
        dir = FileManager.default.temporaryDirectory
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
        /// The longest unbroken drawn run on any one row: the bar.
        func longestRun(maxY: CGFloat) -> (start: CGFloat, end: CGFloat)? {
            var best: (Int, Int)?
            for y in 0..<Int(maxY * scale) {
                var s: Int?
                for px in 0...rep.pixelsWide {
                    let on = px < rep.pixelsWide && drawn(px, y)
                    if on, s == nil { s = px }
                    if !on, let from = s {
                        if best == nil || px - from > best!.1 - best!.0 { best = (from, px) }
                        s = nil
                    }
                }
            }
            return best.map { (CGFloat($0.0) / scale, CGFloat($0.1) / scale) }
        }
    }

    private func shoot<V: View>(_ view: V, _ size: CGSize, then body: (Shot) throws -> Void) throws {
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
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
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
            var seen: [String] = []
            for eta in [nil, "about 47 s left", "about 2 h 15 min left"] {
                model.setEtaTextForTesting(eta)
                try shoot(BatchRunningView(model: model), size) { shot in
                    let bar = try XCTUnwrap(shot.longestRun(maxY: size.height * 0.6))
                    XCTAssertEqual(bar.end - bar.start, BatchLayout.columnWidth, accuracy: 1)
                    XCTAssertEqual(bar.start, self.columnLeft(size.width), accuracy: 1)
                    seen.append("\(bar.start)-\(bar.end)")
                }
            }
            XCTAssertEqual(Set(seen).count, 1, "bar moved at \(size): \(seen)")
        }
    }

    /// The title text starts at the same height when the batch ends.
    func testTitleTopDoesNotMoveFromRunningToDone() async throws {
        let calm = try await finishedModel(withSkip: false)
        let skipped = try await finishedModel(withSkip: true)
        for size in sizes {
            let left = columnLeft(size.width)
            let band = (left + 30)...(left + 400)
            var tops: [CGFloat] = []
            try shoot(BatchRunningView(model: calm), size) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
            try shoot(BatchDoneView(model: calm, actions: BatchViewActions()), size) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
            try shoot(BatchDoneView(model: skipped, actions: BatchViewActions()), size) { tops.append(try XCTUnwrap($0.top(x: band, maxY: 150))) }
            for t in tops { XCTAssertEqual(t, tops[0], accuracy: 2, "title top at \(size): \(tops)") }
            XCTAssertEqual(tops[0], BatchLayout.columnTopInset, accuracy: 6)
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
        try shoot(BatchQueuePane(model: model, actions: BatchViewActions()), CGSize(width: 280, height: 300)) { shot in
            let heading = try XCTUnwrap(shot.left(y: 8..<26))
            let row = try XCTUnwrap(shot.left(y: 56..<90))
            XCTAssertEqual(heading, row, accuracy: 1.5)
            XCTAssertEqual(heading, BatchLayout.queueHeadingInset, accuracy: 1.5)
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
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let shot = Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width, bg: 0)
            let heading = try XCTUnwrap(shot.left(y: 8..<26, from: 8, refX: 6))
            let row = try XCTUnwrap(shot.left(y: 56..<90, from: 8, refX: 6))
            XCTAssertEqual(heading, row, accuracy: 1.5)
            XCTAssertEqual(heading, BatchLayout.queueHeadingInset, accuracy: 1.5)
        }
    }
}
