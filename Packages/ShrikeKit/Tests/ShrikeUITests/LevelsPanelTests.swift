//
//  LevelsPanelTests.swift
//  ShrikeUITests
//
//  The Levels panel, Auto Contrast / Auto Color,
//  undo, Reset, and the viewer entry points.
//  Fixture: a blue-tinted gradient, R and G 40…200, B 70…250.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class LevelsPanelTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-levels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    /// Columns run left to right; each channel goes `lo…hi` linearly.
    private static func gradient(width: Int = 256, height: Int = 32,
                                 r: ClosedRange<Double>, g: ClosedRange<Double>,
                                 b: ClosedRange<Double>) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            let t = Double(x) / Double(width - 1)
            func v(_ range: ClosedRange<Double>) -> UInt8 {
                UInt8((range.lowerBound + t * (range.upperBound - range.lowerBound)).rounded())
            }
            let px = (v(r), v(g), v(b))
            for y in 0..<height {
                let i = (y * width + x) * 4
                bytes[i] = px.0; bytes[i + 1] = px.1; bytes[i + 2] = px.2
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Fixture: blue-tinted gradient.
    private static func tinted() -> CGImage {
        gradient(r: 40...200, g: 40...200, b: 70...250)
    }

    /// A grey ramp 0…255 in every channel.
    private static func fullRange() -> CGImage {
        gradient(r: 0...255, g: 0...255, b: 0...255)
    }

    /// Straight RGBA bytes of `image` in sRGB.
    private static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }

    private struct Stats {
        var min = [255, 255, 255], max = [0, 0, 0]
        var atZero = [0, 0, 0], atFull = [0, 0, 0]
        var sum = [0.0, 0.0, 0.0]
        var count = 0
        func mean(_ c: Int) -> Double { sum[c] / Double(Swift.max(count, 1)) }
        func share(_ n: Int) -> Double { Double(n) / Double(Swift.max(count, 1)) }
    }

    private static func stats(_ image: CGImage) -> Stats {
        let px = rgba(image)
        var s = Stats()
        var i = 0
        while i < px.count {
            for c in 0..<3 {
                let v = Int(px[i + c])
                s.min[c] = Swift.min(s.min[c], v)
                s.max[c] = Swift.max(s.max[c], v)
                if v == 0 { s.atZero[c] += 1 }
                if v == 255 { s.atFull[c] += 1 }
                s.sum[c] += Double(v)
            }
            s.count += 1
            i += 4
        }
        return s
    }

    private func controller(_ image: CGImage, tool: EditTool = .levels) -> (EditModeController, () -> CGImage?) {
        let c = EditModeController()
        var last: CGImage?
        c.onPresentImage = { last = $0 }
        c.enter(image: image, url: nil, landOn: tool)
        return (c, { last })
    }

    private func panel(_ c: EditModeController) throws -> LevelsPanel {
        try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
    }

    private func finalImage(_ c: EditModeController, _ original: CGImage) async -> CGImage {
        await EditRenderer().renderFinal(recipe: c.recipe!, from: original)
    }

    // MARK: Input black 20: pixels ≤ 20 become 0 in the saved file

    func testInputBlack20ZeroesDarkPixelsInTheSavedFile() async throws {
        let source = dir.appendingPathComponent("ramp.png")
        let ramp = Self.fullRange()
        let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ramp, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let (c, _) = controller(ramp)
        let p = try panel(c)
        let field = try XCTUnwrap(p._field(.inBlack))
        field.stringValue = "20"
        _ = field.sendAction(field.action, to: field.target)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1, "a field commit is one step")
        XCTAssertEqual(EditRecipe.effectiveLevels(ops).master.inBlack, 20)

        let out = dir.appendingPathComponent("saved.png")
        _ = try await ImageExporter(backupStore: nil).export(recipe: c.recipe!, from: source, to: out, format: .png)
        let saved = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let before = Self.rgba(ramp), after = Self.rgba(saved)
        XCTAssertEqual(before.count, after.count)
        var checked = 0
        for i in stride(from: 0, to: before.count, by: 4) where before[i] <= 20 {
            XCTAssertEqual(after[i], 0, "source \(before[i]) should be 0")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
        // Above the black point the ramp still rises.
        let brightest = stride(from: 0, to: after.count, by: 4).map { after[$0] }.max()
        XCTAssertEqual(brightest, 255)
    }

    // MARK: Auto Contrast on the fixture

    func testAutoContrastStretchesAndKeepsTheTint() async throws {
        let image = Self.tinted()
        let (c, _) = controller(image)
        let p = try panel(c)
        p.setChannel(.blue)
        c.applyLevelsAuto(.contrast)
        await c.settleForTesting()

        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
        let levels = EditRecipe.effectiveLevels(ops)
        XCTAssertFalse(levels.master.isIdentity)
        XCTAssertTrue(levels.red.isIdentity && levels.green.isIdentity && levels.blue.isIdentity)
        XCTAssertEqual(p.channel, .rgb, "Auto Contrast switches the popup to RGB")
        XCTAssertEqual(p._channelPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(p._statusLabel.stringValue, "Auto Contrast applied to RGB.")
        for kind in LevelsHandleKind.allCases {
            XCTAssertEqual(LevelsRules.value(kind, of: p.params.red), LevelsRules.value(kind, of: .identity))
            XCTAssertEqual(LevelsRules.value(kind, of: p.params.blue), LevelsRules.value(kind, of: .identity))
        }

        let before = Self.stats(image)
        let s = Self.stats(await finalImage(c, image))
        XCTAssertLessThanOrEqual(s.min.min()!, 2, "the combined range reaches black")
        XCTAssertGreaterThanOrEqual(s.max.max()!, 253, "the combined range reaches white")
        let total = s.count * 3
        XCTAssertLessThanOrEqual(Double(s.atZero.reduce(0, +)) / Double(total), 0.001)
        XCTAssertLessThanOrEqual(Double(s.atFull.reduce(0, +)) / Double(total), 0.001 + 1.0 / 256)
        XCTAssertGreaterThan(s.mean(2) - s.mean(0), 0, "the tint remains")
        XCTAssertGreaterThan(before.mean(2) - before.mean(0), 0)
    }

    // MARK: Auto Color on the fixture

    func testAutoColorStretchesEachChannelAndReducesTheTint() async throws {
        let image = Self.tinted()
        let (c, _) = controller(image)
        let p = try panel(c)
        p.setChannel(.green)
        c.applyLevelsAuto(.color)
        await c.settleForTesting()

        let levels = EditRecipe.effectiveLevels(await c.recipe!.snapshot())
        XCTAssertTrue(levels.master.isIdentity, "RGB goes back to identity")
        XCTAssertFalse(levels.red.isIdentity)
        XCTAssertFalse(levels.blue.isIdentity)
        XCTAssertEqual(p.channel, .green, "Auto Color leaves the popup where it is")
        XCTAssertEqual(p._statusLabel.stringValue, "Auto Color applied to Red, Green and Blue.")
        XCTAssertTrue(p.params.master.isIdentity, "the RGB handles show identity")

        let before = Self.stats(image)
        let s = Self.stats(await finalImage(c, image))
        for ch in 0..<3 {
            XCTAssertLessThanOrEqual(s.min[ch], 2, "channel \(ch) reaches black")
            XCTAssertGreaterThanOrEqual(s.max[ch], 253, "channel \(ch) reaches white")
            XCTAssertLessThanOrEqual(s.share(s.atZero[ch]), 0.001 + 1.0 / 256)
            XCTAssertLessThanOrEqual(s.share(s.atFull[ch]), 0.001 + 1.0 / 256)
        }
        let tintBefore = abs(before.mean(2) - before.mean(0))
        let tintAfter = abs(s.mean(2) - s.mean(0))
        XCTAssertLessThanOrEqual(tintAfter, tintBefore * 0.5, "tint \(tintBefore) → \(tintAfter)")
    }

    // MARK: Auto Contrast twice

    func testAutoContrastTwiceWritesNothingTheSecondTime() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        c.applyLevelsAuto(.contrast)
        await c.settleForTesting()
        let first = await c.recipe!.snapshot()
        XCTAssertEqual(c.undoMenuTitle, "Undo Auto Contrast")

        c.applyLevelsAuto(.contrast)
        await c.settleForTesting()
        let second = await c.recipe!.snapshot()
        XCTAssertEqual(second, first, "the second press writes nothing")
        XCTAssertEqual(c.operationCount, 1, "no undo step added")
        XCTAssertEqual(p._statusLabel.stringValue, "Already applied. Nothing to change.")
    }

    // MARK: Auto Contrast, Auto Color, ⌘Z, ⌘Z

    func testAutoContrastThenAutoColorUndoesOneStepEach() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        c.applyLevelsAuto(.contrast)
        await c.settleForTesting()
        let contrast = c.effectiveLevels
        c.applyLevelsAuto(.color)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "each press is one undo step")
        XCTAssertTrue(c.effectiveLevels.master.isIdentity, "Auto Color replaces Auto Contrast")
        XCTAssertEqual(c.undoMenuTitle, "Undo Auto Color")

        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(c.effectiveLevels, contrast)
        XCTAssertEqual(p.params, contrast, "the panel re-reads the recipe")
        XCTAssertEqual(p._statusLabel.stringValue, "", "undo clears the status line")
        XCTAssertEqual(c.undoMenuTitle, "Undo Auto Contrast")
        XCTAssertEqual(c.redoMenuTitle, "Redo Auto Color")

        c.performUndo()
        await c.settleForTesting()
        XCTAssertTrue(c.effectiveLevels.isIdentity)
        XCTAssertTrue(p.params.isIdentity)
        XCTAssertEqual(c.undoMenuTitle, "Undo")
    }

    // MARK: Already full range

    func testAutoContrastOnAFullRangeImageChangesNothing() async throws {
        let (c, _) = controller(Self.fullRange())
        let p = try panel(c)
        c.applyLevelsAuto(.contrast)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertTrue(ops.isEmpty, "recipe unchanged: \(ops)")
        XCTAssertFalse(c.hasPendingEdits)
        XCTAssertEqual(p._statusLabel.stringValue, "Already full range. Nothing to change.")
        // The next handle change clears the line.
        p._drag(.inBlack, through: [5])
        XCTAssertEqual(p._statusLabel.stringValue, "")
    }

    // MARK: Reset after Auto Color

    func testResetAfterAutoColorGivesThePreLevelsImage() async throws {
        let image = Self.tinted()
        let (c, lastImage) = controller(image)
        let p = try panel(c)
        c.applyLevelsAuto(.color)
        await c.settleForTesting()
        XCTAssertEqual(p.channel, .rgb)
        XCTAssertEqual(p._resetButton.title, "Reset Levels")
        XCTAssertEqual(p._resetButton.toolTip, "Reset All Channels")

        p._resetButton.performClick(nil)
        await c.settleForTesting()
        XCTAssertTrue(c.effectiveLevels.isIdentity, "every channel is identity")
        XCTAssertTrue(p.params.isIdentity)
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "Reset is one undo step")
        let shown = try XCTUnwrap(lastImage())
        XCTAssertEqual(Self.rgba(shown), Self.rgba(image), "the image matches the pre-Levels render")
    }

    func testOptionResetResetsOnlyTheShownChannel() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        c.applyLevelsAuto(.color)
        await c.settleForTesting()
        p.setChannel(.red)
        p.setOptionHeld(true)
        XCTAssertEqual(p._resetButton.title, "Reset Channel")
        p.reset(channelOnly: true)
        await c.settleForTesting()
        XCTAssertTrue(c.effectiveLevels.red.isIdentity)
        XCTAssertFalse(c.effectiveLevels.blue.isIdentity, "other channels keep their values")
        p.setOptionHeld(false)
        XCTAssertEqual(p._resetButton.title, "Reset Levels")
    }

    // MARK: ⌘Z after a drag

    func testUndoAfterADragRestoresThePreviousHandles() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        p._drag(.inBlack, through: [10, 20, 30])
        await c.settleForTesting()
        p._drag(.inWhite, through: [240, 230])
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "one step per drag: \(ops)")
        XCTAssertEqual(p.params.master.inWhite, 230)

        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(p.params.master.inBlack, 30)
        XCTAssertEqual(p.params.master.inWhite, 255, "the handle is back")
        XCTAssertEqual(p._field(.inWhite)?.stringValue, "255")
    }

    // MARK: Handle rules and keys

    func testHandleRangesFollowTheTable() {
        var ch = LevelsChannel.identity
        ch = LevelsRules.setting(.inWhite, to: 100, in: ch)
        ch = LevelsRules.setting(.inBlack, to: 150, in: ch)
        XCTAssertEqual(ch.inBlack, 98, "black ≤ white − 2")
        ch = LevelsRules.setting(.inWhite, to: 10, in: ch)
        XCTAssertEqual(ch.inWhite, 100, "white ≥ black + 2")
        ch = LevelsRules.setting(.gamma, to: 20, in: ch)
        XCTAssertEqual(ch.gamma, 9.99)
        ch = LevelsRules.setting(.gamma, to: 0.01, in: ch)
        XCTAssertEqual(ch.gamma, 0.10)
        ch = LevelsRules.setting(.gamma, to: 1.234, in: ch)
        XCTAssertEqual(ch.gamma, 1.23, "2 decimals")
        ch = LevelsRules.setting(.outBlack, to: 300, in: ch)
        XCTAssertEqual(ch.outBlack, 255)
        XCTAssertEqual(LevelsRules.text(.gamma, of: ch), "1.23")
        // The midtones handle sits halfway at gamma 1 and moves left as
        // gamma rises (brighter).
        let id = LevelsChannel.identity
        XCTAssertEqual(LevelsRules.position(.gamma, of: id), 0.5, accuracy: 1e-9)
        var bright = id; bright.gamma = 2
        XCTAssertLessThan(LevelsRules.position(.gamma, of: bright), 0.5)
        XCTAssertEqual(LevelsRules.value(.gamma, at: LevelsRules.position(.gamma, of: bright), in: bright),
                       2, accuracy: 0.01, "position and value round-trip")
    }

    func testArrowKeysStepAndShareOneUndoStep() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        let handle = try XCTUnwrap(p._handle(.inBlack))
        handle.onStep?(.inBlack, 1, false)
        handle.onStep?(.inBlack, 1, true)
        XCTAssertEqual(p.params.master.inBlack, 11, "→ +1, ⇧→ +10")
        let gamma = try XCTUnwrap(p._handle(.gamma))
        gamma.onStep?(.gamma, 1, false)
        XCTAssertEqual(p.params.master.gamma, 0.99, accuracy: 1e-9, "→ moves the midtones handle right")
        gamma.onAccessibilityStep?(.gamma, 1)
        XCTAssertEqual(p.params.master.gamma, 1.00, accuracy: 1e-9, "VoiceOver increment raises the value")
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1, "quick key presses join one step: \(ops)")
    }

    func testPanelLayoutAndAccessibility() throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
        host.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: host.topAnchor), p.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            p.widthAnchor.constraint(equalToConstant: 280), p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(p._histogramView.frame.size, NSSize(width: 248, height: 96))
        XCTAssertEqual(p._autoContrastButton.frame.width, 120)
        XCTAssertEqual(p._autoColorButton.frame.width, 120)
        XCTAssertEqual(p._autoColorButton.frame.minX - p._autoContrastButton.frame.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(p._statusLabel.frame.height, 16)
        XCTAssertEqual(p._field(.gamma)?.frame.width, 48)
        XCTAssertEqual(p._autoContrastButton.keyEquivalent, "", "the menu owns the keys")
        XCTAssertEqual(p._field(.outWhite)?.nextKeyView, p._autoContrastButton)
        XCTAssertEqual(p._autoContrastButton.nextKeyView, p._autoColorButton)
        XCTAssertEqual(p._autoColorButton.nextKeyView, p._resetButton)
        let labels = LevelsHandleKind.allCases.compactMap { p._handle($0)?.accessibilityLabel() }
        XCTAssertEqual(labels, ["Input black point", "Midtones", "Input white point",
                                "Output black point", "Output white point"])
        XCTAssertEqual(p._handle(.gamma)?.accessibilityRole(), .slider)
        XCTAssertEqual(p._autoContrastButton.toolTip, LiveTooltips.text(
            .autoContrast, context: .viewer, preset: ShortcutTable.livePreset))
        XCTAssertEqual(p._autoContrastButton.accessibilityHelp(),
                       "Stretches brightness and contrast. Keeps the colors in balance.")
    }

    func testPanelShowsTheInputHistogram() async throws {
        let (c, _) = controller(Self.tinted())
        let p = try panel(c)
        await c.settleLevelsHistogramForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        await c.settleLevelsHistogramForTesting()
        XCTAssertNotNil(p._histogramView.state.data)
        p.setChannel(.blue)
        XCTAssertEqual(p._histogramView.soloChannel, .blue)
    }

    // MARK: Entry points

    func testLevelsPickerSymbolAndMenuKeys() {
        XCTAssertEqual(EditChromeTools.symbol(.levels), "slider.horizontal.below.rectangle")
        XCTAssertEqual(EditChromeTools.order.last, .levels, "after Color")
        XCTAssertEqual(ViewerKeyMap.action(for: .levels, context: .viewer), .selectEditTool(.levels))
        XCTAssertEqual(ViewerKeyMap.action(for: .autoContrast, context: .viewer), .autoLevels(.contrast))
        XCTAssertEqual(ViewerKeyMap.action(for: .autoColor, context: .editMode), .autoLevels(.color))
    }

    // MARK: ⇧⌘B outside edit mode

    func testAutoColorFromTheViewerEntersEditModeAndWritesNothingToDisk() async throws {
        let url = dir.appendingPathComponent("tint.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Self.tinted(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let bytesBefore = try Data(contentsOf: url)

        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 800, height: 600))
        let content = viewer.contentRootForTesting
        try await waitUntil("photo") { content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder }

        XCTAssertFalse(content.isEditModeActive)
        XCTAssertTrue(viewer.canPerform(.autoColor))
        XCTAssertTrue(viewer.canPerform(.levels))
        viewer.perform(.autoColor)
        await viewer.waitForEditLoad()
        try await waitUntil("edit mode") { content.isEditModeActive }
        let c = content.editModeController
        await c.settleForTesting()
        XCTAssertEqual(c.currentTool, .levels, "edit mode opens on Levels")
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
        guard case .levels = ops.first else { return XCTFail("one .levels op: \(ops)") }
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "the file on disk is unchanged")
        c.finalizeExit()
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.descendants(of: type) }
    }
}
