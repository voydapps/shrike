//
//  WordsTableTests.swift
//  ShrikeUITests
//
//  Spec 28 §9 (the words table): the new strings that are reachable without a
//  window, and a repo-level check that the old ones are gone from the
//  user-facing string literals of every module.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI
import ShrikeEdit

@MainActor
final class WordsTableTests: XCTestCase {

    // MARK: Old words are gone

    /// Every `Sources` file of the package (all five modules).
    private func sourceFiles() throws -> [(name: String, lines: [String])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var out: [(String, [String])] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url.lastPathComponent, text.components(separatedBy: "\n")))
        }
        XCTAssertGreaterThan(out.count, 100, "the scan found the sources")
        return out
    }

    /// The nine strings of the spec's closing list plus the title forms that §9 replaced.
    /// Case-sensitive; only text inside a string literal counts (a banned word after an
    /// opening quote), comment lines are skipped.
    func testOldWordsAreGoneFromUserFacingLiterals() throws {
        let banned = ["Colour", "colour", "Cancelled", "Custom selection", "Reset All Preferences",
                      "candidate", "Position overlay auto-hides", "Cell size", "Show Review Controls",
                      "What Will Happen", "Show Inspector", "Hide Inspector", "Best Fit",
                      "— Settings", "Batch — "]
        var hits: [String] = []
        for file in try sourceFiles() {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard let firstQuote = line.firstIndex(of: "\"") else { continue }
                let literalPart = line[firstQuote...]
                for word in banned where literalPart.contains(word) {
                    hits.append("\(file.name):\(index + 1) \(word)")
                }
            }
        }
        XCTAssertEqual(hits, [], "old words in user-facing literals")
    }

    // MARK: Menus

    private func mainMenu() -> ShrikeMainMenu {
        ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
    }

    func testMenuBarHasPhotoNotImage() {
        let titles = mainMenu().menu.items.map { $0.submenu?.title ?? $0.title }
        XCTAssertTrue(titles.contains("Photo"), "\(titles)")
        XCTAssertFalse(titles.contains("Image"), "\(titles)")
    }

    func testViewMenuHasInfoAndRatingBar() throws {
        let bar = mainMenu()
        let view = try XCTUnwrap(bar.menu.items.first { $0.submenu?.title == "View" }?.submenu)
        let titles = view.items.map(\.title)
        XCTAssertTrue(titles.contains("Show Info"), "\(titles)")
        XCTAssertTrue(titles.contains("Show Rating Bar"), "\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("Inspector") || $0.contains("Review") }, "\(titles)")
        XCTAssertEqual(ShrikeCommand.toggleInspector.title, "Show Info")
        XCTAssertEqual(ViewerWindow.ratingBarMenuTitle(visible: false), "Show Rating Bar")
        XCTAssertEqual(ViewerWindow.ratingBarMenuTitle(visible: true), "Hide Rating Bar")
    }

    /// Through `validateMenuItem`, the way the menu bar asks: the title follows the saved state.
    func testViewerSwitchesTheRatingBarTitleWithItsState() throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-ratingbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        let saved = Prefs.reviewControlsVisible
        defer { Prefs.reviewControlsVisible = saved }
        let item = NSMenuItem(title: "x", action: #selector(ViewerWindow.toggleReviewControls(_:)), keyEquivalent: "")
        Prefs.reviewControlsVisible = false
        XCTAssertTrue(viewer.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Rating Bar")
        XCTAssertEqual(item.state, .off, "the title says what the click does: no check mark")
        Prefs.reviewControlsVisible = true
        XCTAssertTrue(viewer.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Rating Bar")
    }

    /// The model rule of the Batch example line (spec 28 §9).
    func testBatchExampleLineRule() {
        let first = (outputName: "2026-11-10_001.jpg", skipped: false)
        XCTAssertEqual(BatchModel.exampleLine(renameOn: true, templateError: nil, first: first),
                       "Example: 2026-11-10_001.jpg")
        XCTAssertNil(BatchModel.exampleLine(renameOn: false, templateError: nil, first: first), "rename off")
        XCTAssertNil(BatchModel.exampleLine(renameOn: true, templateError: "Unknown name part {x}.", first: first),
                     "template error")
        XCTAssertNil(BatchModel.exampleLine(renameOn: true, templateError: nil, first: (outputName: "a.jpg", skipped: true)),
                     "the first photo is skipped")
        XCTAssertNil(BatchModel.exampleLine(renameOn: true, templateError: nil, first: nil), "empty queue")
    }

    // MARK: Shortcuts list: Best Fit merged into Zoom to Fit

    func testBestFitIsOneRowWithZoomToFit() throws {
        for preset in ShortcutPreset.allCases {
            let viewer = try XCTUnwrap(ShortcutsTab.sections(for: preset).first { $0.title == "Viewer" })
            XCTAssertFalse(viewer.rows.contains { $0.action == "Best Fit" }, "\(preset)")
            let fit = viewer.rows.filter { $0.action == "Zoom to Fit" }
            XCTAssertEqual(fit.count, 1, "\(preset)")
            XCTAssertTrue(fit[0].keys.contains("⌘0"), fit[0].keys)
            XCTAssertTrue(fit[0].keys.contains("*"), "the Best Fit keys sit on the row: \(fit[0].keys)")
        }
        XCTAssertEqual(ShrikeCommand.zoomToFit.title, "Zoom to Fit")
    }

    // MARK: Settings

    func testSettingsTabNamesAndEditingIcon() {
        XCTAssertEqual(PreferencesTab.editing.title, "Editing")
        XCTAssertEqual(PreferencesTab.editing.symbolName, "pencil")
        XCTAssertNotEqual(PreferencesTab.editing.symbolName, "slider.horizontal.3")
        XCTAssertEqual(AdvancedTab.configurationLabel, "All settings")
        XCTAssertEqual(AdvancedTab.configurationDetail, "Every setting goes back to how it was at install. Restart Shrike to finish.")
        XCTAssertEqual(ThumbnailsTab.cellSizeHint, "How large photos are in the grid. The default is \(Prefs.defaultThumbnailSizePt) pt.")
    }

    // MARK: Batch

    func testBatchTitleAndSubtitle() {
        XCTAssertEqual(BatchModel.Copy.windowTitle, "Batch")
        XCTAssertEqual(BatchModel.Copy.subtitle(23), "23 photos")
        XCTAssertEqual(BatchModel.Copy.subtitle(1), "1 photo")
        XCTAssertEqual(BatchModel.Copy.inPlace(2), "Only the names change. Undo Batch can put the old names back.")
        XCTAssertEqual(BatchModel.Copy.inPlace(1), "Only the name changes. Undo Batch can put the old name back.")
    }

    func testExampleLine() {
        XCTAssertEqual(BatchModel.Copy.exampleLine(outputName: "2026-11-10_001.jpg"), "Example: 2026-11-10_001.jpg")
        XCTAssertNil(BatchModel.Copy.exampleLine(outputName: nil), "no photo, or the first photo is skipped")
        XCTAssertNil(BatchModel.Copy.exampleLine(outputName: ""))
    }

    // MARK: Closing grep (§9 rules 1-2): alert titles are sentences

    func testAlertTitlesFoundByTheClosingGrepUseSentenceCase() {
        XCTAssertEqual(BatchWindowController.Copy.savePresetTitle, "Save preset")
        XCTAssertEqual(BrowserWindowController.newFolderAlertTitle, "New folder")
    }

    // MARK: Resize method names

    func testResizeMethodIsStoredByIndexNotTitle() {
        let panel = ResizePanel()
        let popup = panel._interpPopup
        XCTAssertEqual(popup.itemTitles, ["Sharp (Lanczos)", "Smooth (Bicubic)", "Soft (Bilinear)", "Pixels (Nearest)"])
        // Whatever the items are called, the choice follows the position.
        for (index, expected) in [Interpolation.lanczos, .bicubic, .bilinear, .nearest].enumerated() {
            popup.item(at: index)?.title = "Renamed \(index)"
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
            XCTAssertEqual(panel.interpolation, expected, "index \(index)")
            XCTAssertEqual(ResizePanel.interpolation(forPopupIndex: index), expected)
            XCTAssertEqual(ResizePanel.popupIndex(for: expected), index)
        }
    }
}
