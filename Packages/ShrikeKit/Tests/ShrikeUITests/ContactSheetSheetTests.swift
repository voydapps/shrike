//
//  ContactSheetSheetTests.swift
//  ShrikeUITests
//
//  Contact sheet through the Browser: the
//  real sheet's controls (answered in code, no sheet on screen), the Save
//  panel answered with a temp file, the PDF made by the renderer.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
import ShrikeEdit

@MainActor
final class ContactSheetSheetTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var out: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-contact-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        PrintSettingsStore.standard.reset()
    }

    override func tearDown() async throws {
        ContactSheetSheet.responderForTesting = nil
        BrowserWindowController.contactSheetSaveResponderForTesting = nil
        PrintSettingsStore.standard.reset()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// `count` tiny JPEGs, copies of two masters (landscape / portrait).
    private func makeImages(_ count: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var masters: [URL] = []
        for (i, size) in [(64, 48), (48, 64)].enumerated() {
            let ctx = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: CGFloat(i), alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            let url = root.appendingPathComponent("master\(i).jpg")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            masters.append(url)
        }
        for i in 0..<count {
            try FileManager.default.copyItem(at: masters[i % 2],
                                             to: dir.appendingPathComponent(String(format: "IMG_%04d.jpg", i)))
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func openBrowser(expecting count: Int) async throws -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == count }
        XCTAssertTrue(listed, "listed \(browser.contentController.visibleItems.count) of \(count)")
        return browser
    }

    /// Answers the sheet through its real controls: columns by the
    /// stepper, paper and caption by the popups, Export….
    private func answerSheet(columns: Int, paper: ContactSheetPaper, caption: ContactSheetCaption,
                             selectedOnly: Bool = false,
                             seen: @escaping (ContactSheetScope, ContactSheetOptions) -> Void = { _, _ in }) {
        ContactSheetSheet.responderForTesting = { scope, initial in
            seen(scope, initial)
            var answer: ContactSheetRequest?
            let sheet = ContactSheetSheet.makeForTesting(scope: scope, initial: initial) { answer = $0 }
            sheet.stepperForTesting.integerValue = columns
            sheet.stepForTesting()
            sheet.paperPopupForTesting.selectItem(withTitle: paper == .a4 ? "A4" : "US Letter")
            let captionTitle = ContactSheetForm.captions.first { $0.value == caption }!.title
            sheet.captionPopupForTesting.selectItem(withTitle: captionTitle)
            if selectedOnly { sheet.selectRadioForTesting(true) }
            sheet.exportForTesting()
            return answer
        }
    }

    private func pageCount(_ url: URL) throws -> Int {
        try XCTUnwrap(CGPDFDocument(url as CFURL)).numberOfPages
    }

    // MARK: The sheet's controls

    // Spec 25 §9: 2+ selected default to the selection; 1 or 0 to All.
    func testDefaultRadioFollowsTheSelectionCount() {
        let initial = ContactSheetOptions(title: "T", columns: 5, paper: .usLetter, caption: .fileName)
        for (selected, selectedOn) in [(0, false), (1, false), (2, true), (12, true)] {
            let scope = ContactSheetScope(allCount: 25, folderName: "F", selectedCount: selected)
            let sheet = ContactSheetSheet.makeForTesting(scope: scope, initial: initial) { _ in }
            XCTAssertEqual(sheet.selectedRadioForTesting.state == .on, selectedOn, "\(selected) selected")
            XCTAssertEqual(sheet.allRadioForTesting.state == .on, !selectedOn, "\(selected) selected")
        }
    }

    func testControlsMapToOptions() {
        let scope = ContactSheetScope(allCount: 180, folderName: "Italy 2026", selectedCount: 12)
        XCTAssertEqual(scope.allTitle, "All 180 in “Italy 2026”")
        XCTAssertEqual(scope.selectedTitle, "The 12 selected")
        let initial = ContactSheetOptions(title: "Italy 2026", columns: 5, paper: .usLetter, caption: .fileName)
        var answer: ContactSheetRequest?
        let sheet = ContactSheetSheet.makeForTesting(scope: scope, initial: initial) { answer = $0 }
        XCTAssertEqual(sheet.titleFieldForTesting.stringValue, "Italy 2026")
        XCTAssertEqual(sheet.stepperForTesting.integerValue, 5)
        XCTAssertEqual(sheet.stepperForTesting.minValue, 3)
        XCTAssertEqual(sheet.stepperForTesting.maxValue, 8)
        XCTAssertEqual(sheet.paperPopupForTesting.titleOfSelectedItem, "US Letter")
        XCTAssertEqual(sheet.captionPopupForTesting.itemTitles, ["None", "File name", "File name and date"])
        XCTAssertEqual(sheet.captionPopupForTesting.titleOfSelectedItem, "File name")
        XCTAssertEqual(sheet.allRadioForTesting.state, .off, "12 selected: the selection is the default")
        XCTAssertEqual(sheet.selectedRadioForTesting.state, .on)

        // A typed 12 is clamped to 8 on Export….
        sheet.columnsFieldForTesting.stringValue = "12"
        sheet.titleFieldForTesting.stringValue = "  Roma  "
        sheet.paperPopupForTesting.selectItem(withTitle: "A4")
        sheet.captionPopupForTesting.selectItem(withTitle: "None")
        sheet.selectRadioForTesting(true)
        sheet.exportForTesting()
        XCTAssertEqual(answer, ContactSheetRequest(
            options: ContactSheetOptions(title: "Roma", columns: 8, paper: .a4, caption: .none),
            selectedOnly: true))

        var cancelled = false
        let other = ContactSheetSheet.makeForTesting(scope: scope, initial: initial) { cancelled = $0 == nil }
        other.cancelForTesting()
        XCTAssertTrue(cancelled)
    }

    func testCopy() {
        XCTAssertEqual(ContactSheetForm.fileName(for: "Italy 2026"), "Italy 2026 contact sheet.pdf")
        XCTAssertEqual(ContactSheetForm.fileName(for: "  "), "Contact sheet.pdf")
        XCTAssertEqual(ContactSheetForm.fileName(for: "a/b:c"), "a-b-c contact sheet.pdf")
        XCTAssertEqual(ContactSheetForm.progressText(0.4), "Making contact sheet… 40%")
        XCTAssertEqual(ContactSheetForm.savedText("Italy 2026 contact sheet.pdf"),
                       "Saved “Italy 2026 contact sheet.pdf”.")
        XCTAssertEqual(ContactSheetScope(allCount: 3, folderName: "", selectedCount: 0).allTitle, "All 3 images")
    }

    // MARK: 180 images

    /// 180 images, 5 columns, A4, captions on → 6 pages.
    /// The same with 8 columns → 3 pages (80 + 80 + 20).
    func test180Images_pageCounts() async throws {
        try makeImages(180)
        let browser = try await openBrowser(expecting: 180)
        defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.exportContactSheet))

        var names: [String] = []
        BrowserWindowController.contactSheetSaveResponderForTesting = { [out] name in
            names.append(name)
            return out!.appendingPathComponent(names.count == 1 ? name : "eight.pdf")
        }
        var seenScope: ContactSheetScope?
        var seenInitial: ContactSheetOptions?
        answerSheet(columns: 5, paper: .a4, caption: .fileName) { seenScope = $0; seenInitial = $1 }
        var saved: [URL?] = []
        browser.contactSheetSavedForTesting = { saved.append($0) }

        browser.perform(.exportContactSheet)
        await browser.waitForContactSheet()
        XCTAssertEqual(seenScope, ContactSheetScope(allCount: 180, folderName: "Italy 2026", selectedCount: 1))
        XCTAssertEqual(seenInitial?.title, "Italy 2026")
        XCTAssertEqual(seenInitial?.columns, 5)
        XCTAssertEqual(names.first, "Italy 2026 contact sheet.pdf")
        let five = out.appendingPathComponent("Italy 2026 contact sheet.pdf")
        XCTAssertEqual(saved, [five])
        XCTAssertEqual(try pageCount(five), 6)
        XCTAssertEqual(browser.toastHost.content?.message, "Saved “Italy 2026 contact sheet.pdf”.")
        XCTAssertEqual(browser.toastHost.actionTitleForTesting, "Show")
        // The choices are remembered in the print prefs.
        XCTAssertEqual(PrintSettingsStore.standard.load().contactSheetColumns, 5)
        XCTAssertEqual(PrintSettingsStore.standard.load().contactSheetPaper, .a4)

        answerSheet(columns: 8, paper: .a4, caption: .fileName) { _, initial in seenInitial = initial }
        browser.perform(.exportContactSheet)
        await browser.waitForContactSheet()
        let eight = out.appendingPathComponent("eight.pdf")
        XCTAssertEqual(saved.last, eight)
        XCTAssertEqual(try pageCount(eight), 3)
        XCTAssertEqual(PrintSettingsStore.standard.load().contactSheetColumns, 8)

        // No temp files next to the PDFs.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    /// "The N selected" makes a sheet of the selection only; the next
    /// sheet starts from the remembered choices.
    func testSelectionOnlyAndRememberedChoices() async throws {
        try makeImages(40)
        let browser = try await openBrowser(expecting: 40)
        defer { browser.close() }
        let picked = (0..<12).map { dir.appendingPathComponent(String(format: "IMG_%04d.jpg", $0)) }
        XCTAssertTrue(browser.contentController.select(urls: picked))
        BrowserWindowController.contactSheetSaveResponderForTesting = { [out] name in
            out!.appendingPathComponent(name)
        }
        var scope: ContactSheetScope?
        answerSheet(columns: 3, paper: .usLetter, caption: .none, selectedOnly: true) { s, _ in scope = s }
        browser.perform(.exportContactSheet)
        await browser.waitForContactSheet()
        XCTAssertEqual(scope?.selectedCount, 12)
        let url = out.appendingPathComponent("Italy 2026 contact sheet.pdf")
        // 3 columns on US Letter without captions: 175 pt cells, 3 rows,
        // 9 per page, so the 12 selected make 2 pages (all 40 would be 5).
        XCTAssertEqual(try pageCount(url), 2)
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let box = try XCTUnwrap(doc.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 612, accuracy: 0.1)

        var initial: ContactSheetOptions?
        ContactSheetSheet.responderForTesting = { _, i in initial = i; return nil }
        browser.perform(.exportContactSheet)
        XCTAssertEqual(initial?.columns, 3)
        XCTAssertEqual(initial?.paper, .usLetter)
        XCTAssertEqual(initial?.caption, ContactSheetCaption.none)
    }

    func testCancelledSaveMakesNothing() async throws {
        try makeImages(3)
        let browser = try await openBrowser(expecting: 3)
        defer { browser.close() }
        answerSheet(columns: 5, paper: .a4, caption: .fileName)
        BrowserWindowController.contactSheetSaveResponderForTesting = { _ in nil }
        browser.perform(.exportContactSheet)
        XCTAssertNil(browser.contactSheetExport)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testDisabledWithNothingListed() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(browser.canPerform(.exportContactSheet))
    }
}
