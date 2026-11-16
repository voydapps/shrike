//
//  WindowByWindow2gTests.swift
//  ShrikeUITests
//
//  Spec 28 §14 (L-c): Slideshow, Batch, Settings, Browser pieces of pass 2g.
//

import AppKit
import XCTest
import ShrikeIO
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class WindowByWindow2gTests: XCTestCase {

    // MARK: Slideshow

    func testBarScale() {
        XCTAssertEqual(SlideshowBarScale.scale(screenWidth: 1280), 1)
        XCTAssertEqual(SlideshowBarScale.scale(screenWidth: 1440), 1)
        XCTAssertEqual(SlideshowBarScale.scale(screenWidth: 1800), 1.25, accuracy: 0.0001)
        XCTAssertEqual(SlideshowBarScale.scale(screenWidth: 3000), 1.6)
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1, largerText: false), 32)
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1.6, largerText: false), 48, "spec: 48 pt max (was 51)")
        XCTAssertEqual(SlideshowBarScale.barHeight(scale: 1, largerText: false), 44)
    }

    func testControlBarAppliesTheScale() {
        let bar = SlideshowControlBar()
        XCTAssertTrue(bar.buttonWidthsForTesting.allSatisfy { $0 == 32 })
        bar.applyScale(1.5)
        XCTAssertEqual(bar.barScale, 1.5)
        XCTAssertTrue(bar.buttonWidthsForTesting.allSatisfy { $0 == 48 })
    }

    func testShowRowIsAPlainLineForOneChoice() {
        let one = SlideshowScope(allCount: 5, folderName: "x", selectedCount: 0)
        XCTAssertFalse(one.offersSelection)
        let sheet = SlideshowSheet.makeForTesting(scope: one, settings: SlideshowSettings(), completion: { _ in })
        XCTAssertEqual(sheet.plainShowLineForTesting?.stringValue, "All 5 visible photos in “x”")
        let two = SlideshowScope(allCount: 5, folderName: "x", selectedCount: 2)
        XCTAssertNil(SlideshowSheet.makeForTesting(scope: two, settings: SlideshowSettings(), completion: { _ in }).plainShowLineForTesting)
    }

    // MARK: Batch

    func testOutputFormDecision() {
        typealias C = BatchModel.Copy
        // Rename only, in place: no pixel backup, so the confirm's words.
        XCTAssertEqual(C.outputForm(inPlaceText: C.inPlace(2), writesToFolder: false), .notice("Only the names change. Undo Batch can put the old names back."))
        XCTAssertEqual(C.inPlace(2), BatchModel.ConfirmCopy.information(2, renameOnly: true))
        XCTAssertEqual(C.inPlace(1), BatchModel.ConfirmCopy.information(1, renameOnly: true))
        XCTAssertEqual(C.outputForm(inPlaceText: C.inPlaceRotate, writesToFolder: false), .notice(C.inPlaceRotate))
        XCTAssertEqual(C.outputForm(inPlaceText: nil, writesToFolder: true), .folder(note: "Your originals are not changed."))
        XCTAssertEqual(C.outputForm(inPlaceText: nil, writesToFolder: false), .none)
        // A-3: a folder output that lands on a photo's own file (FS-1).
        XCTAssertEqual(C.outputForm(inPlaceText: nil, writesToFolder: true, changesOriginals: true),
                       .folderNotice("Replaces the originals. You can undo while Shrike keeps the backup."))
    }

    /// A-3: one predicate for the Output notice, the Run dots and the confirm question.
    func testOriginalsAtRiskPredicate() {
        let a = ImageGroup(primary: URL(fileURLWithPath: "/x/a.jpg"))
        let b = ImageGroup(primary: URL(fileURLWithPath: "/x/b.jpg"))
        XCTAssertEqual(BatchModel.originalsAtRisk(inPlace: true, items: [a, b], overwritten: [], unreadable: [b.primary],
                                                  invalidName: []).map(\.primary), [a.primary])
        XCTAssertTrue(BatchModel.originalsAtRisk(inPlace: false, items: [a, b], overwritten: [], unreadable: [],
                                                 invalidName: []).isEmpty)
        XCTAssertEqual(BatchModel.originalsAtRisk(inPlace: false, items: [a, b], overwritten: [b], unreadable: [],
                                                  invalidName: []).map(\.primary), [b.primary])
    }

    /// A-5: the Run accessibility label is the footer title, retry count included.
    func testFooterRunTitle() {
        typealias C = BatchModel.Copy
        XCTAssertEqual(C.footerRunTitle(reviewingRemaining: true, queueCount: 3, processable: 3, changesOriginals: true),
                       "Retry 3 Remaining Photos")
        XCTAssertEqual(C.footerRunTitle(reviewingRemaining: true, queueCount: 1, processable: 1, changesOriginals: false),
                       "Retry 1 Remaining Photo")
        XCTAssertEqual(C.footerRunTitle(reviewingRemaining: false, queueCount: 3, processable: 2, changesOriginals: true),
                       "Run 2 Photos…")
    }

    func testRunTitle() {
        typealias C = BatchModel.Copy
        XCTAssertEqual(C.runTitle(22, changesOriginals: true), "Run 22 Photos…")
        XCTAssertEqual(C.runTitle(1, changesOriginals: true), "Run 1 Photo…")
        XCTAssertEqual(C.runTitle(22, changesOriginals: false), "Run 22 Photos")
        XCTAssertEqual(C.runTitle(0, changesOriginals: true), "Run")
    }

    // MARK: Settings

    func testSettingsHeightRule() {
        XCTAssertEqual(SettingsWindowSize.height(fitting: 200, visibleScreenHeight: 1000), 320)
        XCTAssertEqual(SettingsWindowSize.height(fitting: 500, visibleScreenHeight: 1000), 500)
        XCTAssertEqual(SettingsWindowSize.height(fitting: 900, visibleScreenHeight: 1000), 800)
        XCTAssertEqual(SettingsWindowSize.height(fitting: 900, visibleScreenHeight: 300), 320, "a tiny screen keeps the floor")
        // Pass 2p: the 320 pt floor is the window's (content + title bar and toolbar).
        XCTAssertEqual(SettingsWindowSize.height(fitting: 160, chrome: 88, visibleScreenHeight: 1000), 232,
                       "a short tab: window 320, no empty band")
        XCTAssertEqual(SettingsWindowSize.height(fitting: 300, chrome: 88, visibleScreenHeight: 1000), 300,
                       "the real content wins over the floor")
        XCTAssertEqual(SettingsWindowSize.height(fitting: 900, chrome: 88, visibleScreenHeight: 1000), 800)
        XCTAssertEqual(SettingsWindowSize.width, 560)
        XCTAssertEqual(SettingsWindowSize.animationDuration(reduceMotion: false), 0.15)
        XCTAssertEqual(SettingsWindowSize.animationDuration(reduceMotion: true), 0)
    }

    // MARK: Browser path bar

    func testPathBarWritesTheRealChainUnderPrivate() {
        let entries = BrowserBottomBar.quickEntries(for: URL(fileURLWithPath: "/tmp/shoot", isDirectory: true))
        XCTAssertEqual(entries.map(\.title), ["/", "private", "tmp", "shoot"])
        XCTAssertEqual(entries.map(\.url.path), ["/", "/private", "/private/tmp", "/private/tmp/shoot"])
        let plain = BrowserBottomBar.quickEntries(for: URL(fileURLWithPath: "/Users/me/Pictures", isDirectory: true))
        XCTAssertEqual(plain.map(\.title), ["/", "Users", "me", "Pictures"])
        let finder = BrowserBottomBar.finderEntries(for: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertEqual(finder.map(\.url.path), ["/", "/private", "/private/tmp"])
    }

    /// A-4: under /tmp the display chain goes through /private, but the
    /// shown folder's own crumb does not re-navigate (canonical identity).
    func testPrivateChainLastCrumbIsTheShownFolder() {
        let bar = BrowserBottomBar(slider: NSSlider())
        var went: [URL] = []
        bar.onNavigate = { went.append($0) }
        bar.setFolder(URL(fileURLWithPath: "/tmp/shoot", isDirectory: true))
        XCTAssertEqual(bar.pathControl.pathItems.map { $0.title }.suffix(3), ["private", "tmp", "shoot"])
        bar.navigate(toPathIndex: bar.pathURLs.count - 1)
        XCTAssertTrue(went.isEmpty, "the shown folder's crumb is not a navigation")
        bar.navigate(toPathIndex: bar.pathURLs.count - 2)
        XCTAssertEqual(went.map(\.path), ["/private/tmp"])
    }

    /// 28a B.5: result title 15 pt semibold, summary 13 pt regular secondary, 6 pt under it.
    func testResultHeadingMetrics() {
        XCTAssertEqual(BatchLayout.resultTitleSize, 15)
        XCTAssertEqual(BatchLayout.resultSummarySize, 13)
        XCTAssertEqual(BatchLayout.resultSummarySpacing, 6)
    }

    /// 28a B.9: tag dots use the system colours at full strength, and each
    /// dot's edge has at least 3:1 contrast against the popover in Light and Dark.
    func testTagDotColorTable() throws {
        func luminance(_ c: NSColor) -> CGFloat {
            let s = c.usingColorSpace(.sRGB)!
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
        }
        func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let expected: [FinderTagColor: NSColor] = [.red: .systemRed, .orange: .systemOrange, .yellow: .systemYellow,
            .green: .systemGreen, .blue: .systemBlue, .purple: .systemPurple, .gray: .systemGray]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                for color in FinderTagColor.finderMenuOrder {
                    let fill = TagDotModel.fill(color).usingColorSpace(.sRGB)!
                    XCTAssertEqual(fill, expected[color]!.usingColorSpace(.sRGB)!, "\(color)")
                    XCTAssertEqual(fill.alphaComponent, 1, "\(color) not blended")
                    let best = max(contrast(fill, bg), contrast(TagDotModel.edge(color).usingColorSpace(.sRGB)!, bg))
                    XCTAssertGreaterThanOrEqual(best, 3, "\(color) in \(name.rawValue)")
                }
            }
        }
    }

    /// 28a B.10: the temporary Date Captured column is as wide as a formatted
    /// date in the list font plus padding (never the old fixed 150 that cut it).
    func testSortColumnFitsAFormattedDate() {
        let font = BrowserContentViewController.listFont
        let sample = BrowserContentViewController.sortColumnSample(.dateCaptured)
        let needed = (sample as NSString).size(withAttributes: [.font: font]).width
        let width = BrowserContentViewController.sortColumnWidth(sample: sample, font: font)
        XCTAssertGreaterThanOrEqual(width, needed + 8, "the cell's 4 pt insets fit")
        XCTAssertLessThan(width, needed + 40)
        XCTAssertEqual(BrowserContentViewController.sortColumnWidth(sample: "x", font: font), 100, "minimum")
    }

    /// §14 + F: the Slideshow bar clamps at 48 pt and follows Larger Text.
    func testSlideshowBarClampAndLargerText() {
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1.6, largerText: false), 48, "51 clamped to 48")
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1, largerText: false), 32)
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1, largerText: true), 36)
        XCTAssertEqual(SlideshowBarScale.buttonSize(scale: 1.6, largerText: true), 48)
        XCTAssertEqual(SlideshowBarScale.glyphSize(scale: 1, largerText: true), 16)
        XCTAssertEqual(SlideshowBarScale.barHeight(scale: 1, largerText: false), 44)
        XCTAssertEqual(SlideshowBarScale.barHeight(scale: 1, largerText: true), 48)
    }
}
