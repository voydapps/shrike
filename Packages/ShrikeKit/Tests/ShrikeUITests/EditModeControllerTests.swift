//
//  EditModeControllerTests.swift
//  ShrikeUITests
//
//  Unit tests for the edit-mode orchestration hub. We exercise the
//  lifecycle, tool-selection side effects, static URL helpers, and the
//  exit flow (for the dirty-free case — the sheet-modal path needs a real
//  window and is excluded from unit scope).
//
//  Covers:
//    - enter(image:url:landOn:) flips isActive, creates recipe, lands on tool
//    - Calling enter twice is idempotent (second call ignored)
//    - selectTool swaps currentTool + crop overlay visibility
//    - finalizeExit tears down session state
//    - Static helpers: exportFormat(for:), destinationURL(for:), urlIsRAW(_:)
//    - Non-dirty attemptExit fast-paths to .exited without a sheet
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeEdit

@MainActor
final class EditModeControllerTests: XCTestCase {

    // MARK: - Helpers

    /// A 1×1 placeholder CGImage — the controller just stashes this, it
    /// never inspects pixel data in the unit-scope tests.
    private func makeImage(width: Int = 1, height: Int = 1) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * width
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    // MARK: - Lifecycle

    func testInit_ControllerStartsInactive() {
        let c = EditModeController()
        XCTAssertFalse(c.isActive)
        XCTAssertNil(c.recipe)
        XCTAssertNil(c.originalImage)
        XCTAssertNil(c.sourceURL)
    }

    func testEnter_FlipsActiveAndCreatesRecipe() {
        let c = EditModeController()
        let url = URL(fileURLWithPath: "/tmp/foo.jpg")
        c.enter(image: makeImage(width: 100, height: 80),
                url: url,
                landOn: .crop)

        XCTAssertTrue(c.isActive)
        XCTAssertEqual(c.currentTool, .crop)
        XCTAssertNotNil(c.recipe)
        XCTAssertNotNil(c.originalImage)
        XCTAssertEqual(c.sourceURL, url)
    }

    func testEnter_LandsOnRequestedTool() {
        let c = EditModeController()
        c.enter(image: makeImage(), url: nil, landOn: .rotate)
        XCTAssertEqual(c.currentTool, .rotate)

        let c2 = EditModeController()
        c2.enter(image: makeImage(), url: nil, landOn: .color)
        XCTAssertEqual(c2.currentTool, .color)
    }

    func testEnter_WhileActiveIsNoOp() {
        let c = EditModeController()
        let url1 = URL(fileURLWithPath: "/tmp/first.jpg")
        let url2 = URL(fileURLWithPath: "/tmp/second.jpg")

        c.enter(image: makeImage(), url: url1, landOn: .crop)
        c.enter(image: makeImage(), url: url2, landOn: .resize)

        // Second call was ignored — state still reflects first session.
        XCTAssertEqual(c.sourceURL, url1)
        XCTAssertEqual(c.currentTool, .crop)
    }

    func testSelectTool_SwapsCurrentTool() {
        let c = EditModeController()
        c.enter(image: makeImage(), url: nil, landOn: .crop)

        c.selectTool(.rotate)
        XCTAssertEqual(c.currentTool, .rotate)

        c.selectTool(.color)
        XCTAssertEqual(c.currentTool, .color)
    }

    func testSelectTool_WhenInactive_IsIgnored() {
        let c = EditModeController()
        c.selectTool(.rotate)
        XCTAssertNil(c.currentTool,
                     "no tool until one is picked in edit mode")
    }

    func testFinalizeExit_TearsDownSessionState() {
        let c = EditModeController()
        c.enter(image: makeImage(),
                url: URL(fileURLWithPath: "/tmp/x.jpg"),
                landOn: .crop)

        c.finalizeExit()
        XCTAssertFalse(c.isActive)
        XCTAssertNil(c.recipe)
        XCTAssertNil(c.originalImage)
        XCTAssertNil(c.sourceURL)
    }

    func testFinalizeExit_WhenInactive_IsNoOp() {
        let c = EditModeController()
        c.finalizeExit()   // Must not crash.
        XCTAssertFalse(c.isActive)
    }

    func testEnter_FiresNoExitedCallback() {
        let c = EditModeController()
        var exitCount = 0
        c.onExitedEditMode = { _ in exitCount += 1 }

        c.enter(image: makeImage(), url: nil, landOn: .crop)
        XCTAssertEqual(exitCount, 0)
    }

    func testFinalizeExit_FiresOnExitedEditMode() {
        let c = EditModeController()
        var exitCount = 0
        c.onExitedEditMode = { _ in exitCount += 1 }

        c.enter(image: makeImage(), url: nil, landOn: .crop)
        c.finalizeExit()
        XCTAssertEqual(exitCount, 1)
    }

    // MARK: - attemptExit — non-dirty fast path

    func testAttemptExit_CleanRecipeResolvesImmediatelyWithExited() async {
        let c = EditModeController()
        c.enter(image: makeImage(), url: nil, landOn: .crop)

        var outcomes: [EditExitOutcome] = []
        let expect = expectation(description: "onExitOutcome fires")
        c.onExitOutcome = { outcome in
            outcomes.append(outcome)
            expect.fulfill()
        }

        c.attemptExit(reason: .userToggled)

        await fulfillment(of: [expect], timeout: 2.0)
        XCTAssertEqual(outcomes, [.exited],
                       "Clean recipe must bypass the modal and resolve to .exited")
        XCTAssertFalse(c.isActive,
                       "Clean exit must also tear down session state")
    }

    func testAttemptExit_WhenInactive_ReportsExited() async {
        let c = EditModeController()

        var outcomes: [EditExitOutcome] = []
        let expect = expectation(description: "onExitOutcome fires")
        c.onExitOutcome = { outcome in
            outcomes.append(outcome)
            expect.fulfill()
        }

        c.attemptExit(reason: .userToggled)
        await fulfillment(of: [expect], timeout: 1.0)
        XCTAssertEqual(outcomes, [.exited])
    }

    // MARK: - Static helpers: exportFormat

    func testExportFormat_NilURL() {
        XCTAssertNil(EditModeController.exportFormat(for: nil))
    }

    func testExportFormat_JPEGFamily() {
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.jpg")),
            .jpeg
        )
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.jpeg")),
            .jpeg
        )
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.JPG")),
            .jpeg,
            "Extension match must be case-insensitive"
        )
    }

    func testExportFormat_PNG() {
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.png")),
            .png
        )
    }

    func testExportFormat_TIFF() {
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.tiff")),
            .tiff
        )
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.tif")),
            .tiff
        )
    }

    func testExportFormat_HEIC() {
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.heic")),
            .heic
        )
        XCTAssertEqual(
            EditModeController.exportFormat(
                for: URL(fileURLWithPath: "/x/y.heif")),
            .heic
        )
    }

    func testExportFormat_RAWFamilyRedirectsToJPEG() {
        for ext in ["cr2", "cr3", "nef", "arw", "dng", "raf", "rw2", "orf"] {
            let url = URL(fileURLWithPath: "/x/y.\(ext)")
            XCTAssertEqual(
                EditModeController.exportFormat(for: url),
                .jpeg,
                "RAW extension .\(ext) must redirect to JPEG"
            )
        }
    }

    // MARK: - Static helpers: urlIsRAW

    func testURLIsRAW_TrueForRAWExtensions() {
        for ext in ["cr2", "cr3", "nef", "arw", "dng", "raf", "rw2", "orf"] {
            XCTAssertTrue(
                EditModeController.urlIsRAW(
                    URL(fileURLWithPath: "/x/y.\(ext)")),
                "\(ext) should be recognised as RAW"
            )
        }
    }

    func testURLIsRAW_FalseForOtherExtensions() {
        for ext in ["jpg", "jpeg", "png", "tiff", "heic", "gif", "bmp"] {
            XCTAssertFalse(
                EditModeController.urlIsRAW(
                    URL(fileURLWithPath: "/x/y.\(ext)")),
                "\(ext) should NOT be recognised as RAW"
            )
        }
    }

    func testURLIsRAW_FalseForNilURL() {
        XCTAssertFalse(EditModeController.urlIsRAW(nil))
    }

    func testURLIsRAW_CaseInsensitive() {
        XCTAssertTrue(EditModeController.urlIsRAW(
            URL(fileURLWithPath: "/x/y.CR2")))
        XCTAssertTrue(EditModeController.urlIsRAW(
            URL(fileURLWithPath: "/x/y.DnG")))
    }

    // MARK: - Static helpers: destinationURL

    func testDestinationURL_RAWGetsEditedSuffixAndJPGExtension() {
        let src = URL(fileURLWithPath: "/photos/IMG_0001.CR2")
        let dest = EditModeController.destinationURL(for: src)

        XCTAssertEqual(dest.pathExtension, "jpg")
        XCTAssertEqual(dest.deletingLastPathComponent().path, "/photos")
        XCTAssertTrue(
            dest.lastPathComponent.contains("IMG_0001"),
            "Stem must survive into destination"
        )
        XCTAssertTrue(
            dest.deletingPathExtension().lastPathComponent.hasSuffix("-edited"),
            "RAW redirect must append -edited per ImageExporter.rawRedirectSuffix"
        )
    }

    func testDestinationURL_NonRAWReturnsUnchanged() {
        let src = URL(fileURLWithPath: "/photos/vacation.jpg")
        XCTAssertEqual(
            EditModeController.destinationURL(for: src),
            src,
            "Non-RAW sources must save over themselves (⌘S = overwrite)"
        )
    }

    func testDestinationURL_PreservesDirectoryForAllRAWExts() {
        for ext in ["nef", "arw", "dng"] {
            let src = URL(fileURLWithPath: "/a/b/c/shot.\(ext)")
            let dest = EditModeController.destinationURL(for: src)
            XCTAssertEqual(dest.deletingLastPathComponent().path, "/a/b/c")
            XCTAssertEqual(dest.pathExtension, "jpg")
        }
    }

    // MARK: - A render that ends after a discard

    /// A rotate starts a full render; the user discards before it ends.
    /// The late result must not replace the pre-edit image on the viewer.
    func testDiscardWhileASlowRenderIsPendingKeepsThePreEditImage() async throws {
        let c = EditModeController()
        let original = makeImage(width: 40, height: 20)
        let rotated = makeImage(width: 20, height: 40)
        var presented: [CGImage] = []
        var restoredDisplay: [Bool] = []
        c.onPresentImage = { presented.append($0) }
        c.onExitedEditMode = { restoredDisplay.append($0) }
        c.renderOverrideForTesting = { _, _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return rotated
        }
        c.enter(image: original, url: nil, landOn: .rotate)
        c.appendSnapped90(quarters: 1)
        try await Task.sleep(nanoseconds: 100_000_000)   // the render is under way
        c.finalizeExit()                                   // discard
        XCTAssertEqual(restoredDisplay, [true], "discard puts the pre-edit image back")
        try await Task.sleep(nanoseconds: 500_000_000)   // the slow render ends
        XCTAssertTrue(presented.isEmpty, "a render that ends after the discard is dropped")
        XCTAssertFalse(c.isActive)
    }

    /// Control: the same slow render with no discard is shown.
    func testSlowRenderIsShownWhileTheSessionIsOpen() async throws {
        let c = EditModeController()
        let rotated = makeImage(width: 20, height: 40)
        var presented: [CGImage] = []
        c.onPresentImage = { presented.append($0) }
        c.renderOverrideForTesting = { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return rotated
        }
        c.enter(image: makeImage(width: 40, height: 20), url: nil, landOn: .rotate)
        c.appendSnapped90(quarters: 1)
        await c.settleForTesting()
        XCTAssertEqual(presented.count, 1)
        XCTAssertTrue(presented.first === rotated)
        c.finalizeExit()
    }
}
