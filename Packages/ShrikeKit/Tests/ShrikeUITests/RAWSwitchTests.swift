//
//  RAWSwitchTests.swift
//  ShrikeUITests
//
//  Spec 24 §4: ⌥R switches a pair between its primary and its RAW file. A
//  view-only switch: it resets on the next photo, edits and rotates are off
//  on the RAW, rate / flag act on the group, an unreadable RAW toasts and
//  stays on the primary. (The test "RAW" is the same JPEG bytes under an
//  .ORF name: ImageIO reads by content, so it decodes.)
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class RAWSwitchTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-rawswitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.resetAll()
    }

    private func jpegData(width: Int = 160, height: Int = 120) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return cond()
    }

    private func makeViewer(rawData: Data? = nil) async throws -> (ViewerWindow, ImageGroup, ImageGroup) {
        let jpeg = jpegData()
        let p1 = try write("P1.JPG", jpeg), o1 = try write("P1.ORF", rawData ?? jpeg)
        let p2 = try write("P2.JPG", jpeg)
        let pair = ImageGroup(primary: p1, companions: [.init(url: o1, kind: .raw)])
        let single = ImageGroup(primary: p2)
        let window = ViewerWindow(groups: [pair, single], startIndex: 0, services: .makeDefault())
        window.setContentSize(NSSize(width: 800, height: 600))
        let shown = await waitUntil {
            window.canPerform(.editImage) && window.displayedItem?.group.primary == p1
                && window.contentRootForTesting.imageView.image != nil
                && !window.contentRootForTesting.imageView.isCurrentImagePlaceholder
        }
        XCTAssertTrue(shown, "the first photo shows")
        return (window, pair, single)
    }

    func testOptionRSwitchesToTheRAWAndBack() async throws {
        let (window, pair, _) = try await makeViewer()
        defer { window.close() }
        let raw = try XCTUnwrap(pair.rawURL)
        XCTAssertEqual(ShortcutTable.bindings(for: .toggleRAWFile, context: .viewer, preset: .macNative)
            .first?.displayString, "⌥R")
        XCTAssertTrue(window.canPerform(.toggleRAWFile))
        XCTAssertEqual(window.panelMenuTitle(.toggleRAWFile), "Show RAW File")
        XCTAssertEqual(window.displayedItem?.shownURL, pair.primary)
        XCTAssertEqual(window.contentRootForTesting.positionPillMarksForTesting.pairKind, "JPG")

        window.perform(.toggleRAWFile)
        let on = await waitUntil { window.displayedItem?.shownURL == raw }
        XCTAssertTrue(on, "the RAW is on screen")
        XCTAssertEqual(window.title, "P1.ORF", "title follows the shown file")
        XCTAssertEqual(window.representedURL, raw)
        XCTAssertEqual(window.commandFileURLs, [raw], "Reveal / Copy Path act on the shown file")
        XCTAssertEqual(window.displayedItem?.group, pair, "rate, flag, trash still act on the group")
        XCTAssertEqual(window.panelMenuTitle(.toggleRAWFile), "Show JPEG File")
        XCTAssertTrue(window.contentRootForTesting.positionPillMarksForTesting.rawShown)

        window.perform(.toggleRAWFile)
        let off = await waitUntil { window.displayedItem?.shownURL == pair.primary }
        XCTAssertTrue(off, "back on the JPEG")
        XCTAssertEqual(window.title, "P1.JPG")
    }

    /// Spec 27 N11: Edit and Rotate are off the moment the switch to RAW starts.
    func testEditAndRotateGoOffAtTheSwitchAndComeBack() async throws {
        let (window, _, _) = try await makeViewer()
        defer { window.close() }
        XCTAssertTrue(window.canPerform(.editImage))
        window.perform(.toggleRAWFile)
        // No waiting: the same turn.
        XCTAssertTrue(window.contentRootForTesting.editBlockedByRAW)
        XCTAssertFalse(window.canPerform(.editImage))
        XCTAssertFalse(window.canPerform(.rotateLeft))
        XCTAssertFalse(window.canPerform(.rotateRight))
        let landed = await waitUntil { window.displayedItem?.isRAWShown == true }
        XCTAssertTrue(landed)
        window.perform(.toggleRAWFile)
        let back = await waitUntil { window.displayedItem?.isRAWShown == false && window.canPerform(.editImage) }
        XCTAssertTrue(back)
        XCTAssertTrue(window.canPerform(.editImage))
    }

    func testEditsAndRotatesAreOffOnTheRAW() async throws {
        let (window, pair, _) = try await makeViewer()
        defer { window.close() }
        let raw = try XCTUnwrap(pair.rawURL)
        let before = try Data(contentsOf: raw)
        window.perform(.toggleRAWFile)
        let on = await waitUntil { window.displayedItem?.shownURL == raw }
        XCTAssertTrue(on)
        for command in [ShrikeCommand.editImage, .rotateLeft, .rotateRight, .flipHorizontal, .editCrop, .levels] {
            XCTAssertFalse(window.canPerform(command), "\(command) is off on the RAW")
        }
        XCTAssertTrue(window.canPerform(.zoomToFit), "viewing still works")
        window.dispatch(.rotateLeft)
        XCTAssertTrue(window.contentRootForTesting.toastHost.isShowing, "refused with a reason")
        window.dispatch(.openEditMode)
        XCTAssertFalse(window.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(try Data(contentsOf: raw), before, "nothing was written")
        XCTAssertEqual(ViewerWindow.rawEditBlockedCopy, "RAW files are not changed. Switch to the JPEG to edit.")
        // The Edit button says why; back on the JPEG it is plain again.
        XCTAssertTrue(window.contentRootForTesting.editBlockedByRAW)
        let editItem = try XCTUnwrap(window.toolbarController?.item(ViewerWindowToolbar.ID.edit))
        XCTAssertTrue(try XCTUnwrap(editItem.toolTip).hasSuffix("\n" + ViewerWindow.rawEditBlockedCopy),
                      "the Edit button's tooltip carries the reason: \(editItem.toolTip ?? "nil")")
        window.perform(.toggleRAWFile)
        let off = await waitUntil { window.displayedItem?.shownURL == pair.primary && window.canPerform(.editImage) }
        XCTAssertTrue(off)
        XCTAssertFalse(window.contentRootForTesting.editBlockedByRAW)
        XCTAssertFalse(try XCTUnwrap(editItem.toolTip).contains("\n"), "the reason is gone on the JPEG")
        XCTAssertTrue(window.canPerform(.editImage))
    }

    func testMovingOnResetsTheSwitch() async throws {
        let (window, pair, single) = try await makeViewer()
        defer { window.close() }
        let raw = try XCTUnwrap(pair.rawURL)
        window.perform(.toggleRAWFile)
        let on = await waitUntil { window.displayedItem?.shownURL == raw }
        XCTAssertTrue(on)
        await window.advance()
        let moved = await waitUntil { window.displayedItem?.group.primary == single.primary }
        XCTAssertTrue(moved)
        XCTAssertFalse(window.canPerform(.toggleRAWFile), "a single file has no RAW to switch to")
        await window.retreat()
        let back = await waitUntil { window.displayedItem?.group.primary == pair.primary }
        XCTAssertTrue(back)
        XCTAssertEqual(window.displayedItem?.shownURL, pair.primary, "shows the JPEG again")
        XCTAssertEqual(window.title, "P1.JPG")
    }

    func testRatingWithTheRAWShownLandsOnTheGroup() async throws {
        let (window, pair, _) = try await makeViewer()
        defer { window.close() }
        let raw = try XCTUnwrap(pair.rawURL)
        window.perform(.toggleRAWFile)
        let on = await waitUntil { window.displayedItem?.shownURL == raw }
        XCTAssertTrue(on)
        window.dispatch(.rate(3))
        let rated = await waitUntil { window.cullingRecords[pair.primary]?.rating == 3 }
        XCTAssertTrue(rated, "the primary's record (the group's) has the rating")
        let both = await waitUntil { window.cullingRecords[raw]?.rating == 3 }
        XCTAssertTrue(both, "both files of the group get the rating")
    }

    func testAnUnreadableRAWToastsAndStaysOnThePrimary() async throws {
        let (window, pair, _) = try await makeViewer(rawData: Data(repeating: 0x41, count: 64))
        defer { window.close() }
        window.perform(.toggleRAWFile)
        let toasted = await waitUntil { window.contentRootForTesting.toastHost.isShowing }
        XCTAssertTrue(toasted, "macOS can\u{2019}t open this RAW file.")
        XCTAssertEqual(ViewerWindow.rawCannotOpenCopy, "macOS can\u{2019}t open this RAW file.")
        XCTAssertEqual(window.displayedItem?.shownURL, pair.primary)
        XCTAssertTrue(window.canPerform(.toggleRAWFile), "the chip stays; a click retries")
    }

    func testShowBothFilesAndRAWOnlyPhotosHaveNothingToSwitch() async throws {
        let jpeg = jpegData()
        let raw = try write("R1.ORF", jpeg)
        let window = ViewerWindow(groups: [ImageGroup(primary: raw, primaryIsRAW: true)], startIndex: 0,
                                  services: .makeDefault())
        defer { window.close() }
        let shown = await waitUntil { window.displayedItem != nil }
        XCTAssertTrue(shown)
        XCTAssertFalse(window.canPerform(.toggleRAWFile), "a RAW-only photo has no switch")
        // Spec 27 B5: the line stays in the menu, greyed.
        let line = NSMenuItem(title: "Show RAW File", action: ShrikeMainMenu.commandAction, keyEquivalent: "")
        line.representedObject = ShrikeCommand.toggleRAWFile.rawValue
        XCTAssertFalse(window.validateMenuItem(line))
        XCTAssertFalse(line.isHidden)
        XCTAssertEqual(line.title, "Show RAW File")
        XCTAssertNil(window.contentRootForTesting.positionPillMarksForTesting.pairKind, "and no chip")
        XCTAssertFalse(window.contentRootForTesting.navigationPositionOverlayForTesting.chipButton.isHidden == false
                       && window.contentRootForTesting.navigationPositionOverlayForTesting.chipButtonFrameForTesting != nil)
        // "Show both files": the grouping gives two items, none with a companion.
        let two = [ImageGroup(primary: try write("S1.JPG", jpeg)), ImageGroup(primary: try write("S1.ORF", jpeg))]
        let both = ViewerWindow(groups: two, startIndex: 0, services: .makeDefault())
        defer { both.close() }
        let up = await waitUntil { both.displayedItem != nil }
        XCTAssertTrue(up)
        XCTAssertFalse(both.canPerform(.toggleRAWFile))
        XCTAssertNil(both.contentRootForTesting.positionPillMarksForTesting.pairKind)
    }

    func testThePillChipIsTheOnlyClickableTargetAndSwitches() async throws {
        let (window, pair, _) = try await makeViewer()
        defer { window.close() }
        let raw = try XCTUnwrap(pair.rawURL)
        let pill = window.contentRootForTesting.navigationPositionOverlayForTesting
        pill.alphaValue = 1
        pill.isHidden = false
        let frame = try XCTUnwrap(pill.chipButtonFrameForTesting, "the chip has a hit area")
        XCTAssertGreaterThanOrEqual(frame.width, 28)
        XCTAssertGreaterThanOrEqual(frame.height, 22)
        XCTAssertEqual(pill.chipButton.accessibilityLabel(), "File type")
        XCTAssertEqual(pill.chipButton.accessibilityValue() as? String, "JPG shown, RAW available")
        XCTAssertTrue(pill.chipButton.toolTip?.contains("⌥R") ?? false, pill.chipButton.toolTip ?? "")
        // The rest of the pill passes clicks on.
        XCTAssertNil(pill.hitTest(NSPoint(x: pill.frame.minX + 4, y: pill.frame.midY)))
        pill.chipButton.performClick(nil)
        let on = await waitUntil { window.displayedItem?.shownURL == raw }
        XCTAssertTrue(on, "a click on the chip switches")
        XCTAssertEqual(pill.chipButton.accessibilityValue() as? String, "RAW shown, JPG available")
    }

    func testChipMetricsFindTheChipInsideTheMarks() {
        let marks = PillMarks(rating: 3, flagged: true, hasRAW: true, pairKind: "JPG", rawShown: false)
        let metrics = PillMarks.pairChipMetrics(marks)
        XCTAssertNotNil(metrics)
        XCTAssertGreaterThan(metrics?.offset ?? 0, 10, "after the stars and the flag")
        XCTAssertGreaterThan(metrics?.width ?? 0, 20)
        XCTAssertNil(PillMarks.pairChipMetrics(PillMarks(hasRAW: true)), "a RAW-only photo keeps the static chip")
        XCTAssertEqual(ViewerWindow.chipKindName(of: URL(fileURLWithPath: "/x/a.jpeg")), "JPG")
        XCTAssertEqual(ViewerWindow.kindName(of: URL(fileURLWithPath: "/x/a.heic")), "HEIC")
    }

    func testTheAlsoLineNamesTheOtherFile() throws {
        let jpg = try write("A1.JPG", jpegData()), orf = try write("A1.ORF", jpegData())
        let group = ImageGroup(primary: jpg, companions: [.init(url: orf, kind: .raw)])
        XCTAssertTrue(PairCopy.alsoLine(for: group, shownURL: jpg)?.hasPrefix("Also: A1.ORF") ?? false)
        XCTAssertTrue(PairCopy.alsoLine(for: group, shownURL: orf)?.hasPrefix("Also: A1.JPG") ?? false)
    }
}
