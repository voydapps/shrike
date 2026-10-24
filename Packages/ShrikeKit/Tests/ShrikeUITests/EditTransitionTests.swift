import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class EditTransitionTests: XCTestCase {
    private var ownedRoots: [URL] = []
    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
        EditToolTransitionModal.presenterForTesting = nil
        EditExitModal.responderForTesting = nil
        EditExitModal.presenterForTesting = nil
        for root in ownedRoots { try? FileManager.default.removeItem(at: root) }
        ownedRoots = []
    }

    private func controller(_ tool: EditTool) -> EditModeController {
        let c = EditModeController()
        c.enter(image: SaveFlowTests.image(width: 400, height: 300), url: nil, landOn: tool)
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        return c
    }
    private func width(_ value: String, _ c: EditModeController) throws {
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel._widthField.stringValue = value
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
    }
    private func color(_ exposure: Double, _ c: EditModeController) throws {
        let panel = try XCTUnwrap(c._installedToolForTesting as? ColorAdjustPanel)
        var params = panel.params
        params.exposure = exposure
        panel.onParamsCommitted?(params)
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    private func stageGeometry(_ tool: EditTool, width target: Int, _ c: EditModeController,
                               origin: CGPoint = .zero) throws {
        if tool == .resize { try width(String(target), c) }
        else {
            let size = c.currentPixelSize
            c.cropOverlay.imageFrame = CGRect(origin: .zero, size: size)
            c.cropOverlay.setRectFromImageSpace(CGRect(origin: origin,
                size: CGSize(width: CGFloat(target), height: CGFloat(target) * size.height / size.width)))
        }
    }

    private func applyGeometry(_ tool: EditTool, _ c: EditModeController) throws {
        if tool == .resize {
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            panel.onApply?(try XCTUnwrap(panel.pendingSpec))
        } else {
            let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
            panel._applyButton.performClick(nil)
        }
    }

    func testStagedCropChoicesDoNotConsumeBeforeDecisionAndKeepOnlyOnce() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
            let c = controller(.crop); defer { c.finalizeExit() }
            c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 300))
            let before = c.pendingCropRect()
            var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
            var asks = 0
            EditToolTransitionModal.presenterForTesting = { content, completion in
                asks += 1; XCTAssertEqual(content.outgoing, .crop); XCTAssertEqual(content.destination, .color)
                answer = completion
            }
            c.selectTool(.color)
            try await until { answer != nil }
            let session = try XCTUnwrap(c.recipe)
            let operations = await session.snapshot()
            XCTAssertTrue(operations.isEmpty, "The pending crop is still a draft while deciding")
            XCTAssertEqual(c.pendingCropRect(), before)
            XCTAssertEqual(c.currentTool, .crop)
            let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: SpecialKey.right, charactersIgnoringModifiers: SpecialKey.right,
                isARepeat: false, keyCode: 124))
            c.cropOverlay.keyDown(with: arrow)
            XCTAssertEqual(c.pendingCropRect(), before, "The pending decision also blocks crop nudges")
            c.selectTool(.resize); c.performUndo(); c.revertPendingEdits()
            answer?(choice)
            await c.settleForTesting()
            XCTAssertEqual(asks, 1)
            XCTAssertFalse(c.isTransitioning)
            if choice == .cancel {
                XCTAssertEqual(c.currentTool, .crop); XCTAssertEqual(c.pendingCropRect(), before)
            } else {
                XCTAssertEqual(c.currentTool, .color)
                XCTAssertEqual(c.currentPixelSize, CGSize(width: choice == .keep ? 200 : 400, height: 300))
            }
            let final = await session.snapshot()
            XCTAssertEqual(final.count, choice == .keep ? 1 : 0)
        }
    }

    // New Apply contract: a later draft Discard must retain both accepted
    // resizes, rather than restoring the old tool-entry checkpoint/Redo.
    func testResizeApplyTwiceDraftDiscardPreservesAcceptedHistoryAndLogicalSize() async throws {
        let c = controller(.rotate); defer { c.finalizeExit() }
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        c.performUndo(); await c.settleForTesting()
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        c.selectTool(.resize); await c.settleForTesting()
        let session = try XCTUnwrap(c.recipe)
        XCTAssertTrue(c.chromeState.canRedo, "The entry rotation has a real Redo before Apply")
        try width("200", c)
        var panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel.onApply?(try XCTUnwrap(panel.pendingSpec)); await c.settleForTesting()
        try width("100", c)
        panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel.onApply?(try XCTUnwrap(panel.pendingSpec)); await c.settleForTesting()
        let accepted = await session.checkpoint(), undoTitle = c.undoMenuTitle
        let acceptedDepth = await session.undoDepth
        XCTAssertEqual(acceptedDepth, 2)
        XCTAssertFalse(c.chromeState.canRedo, "Accepted Apply legitimately clears the old rotation Redo")
        try width("50", c)
        var asks = 0
        EditToolTransitionModal.responderForTesting = { _ in asks += 1; return .discard }
        c.selectTool(.color); await c.settleForTesting()
        let retained = await session.checkpoint()
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(retained, accepted)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
        XCTAssertEqual(c.undoMenuTitle, undoTitle)
        XCTAssertTrue(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.canRedo)
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        c.performRedo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        c.performRedo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
        let redone = await session.checkpoint()
        XCTAssertEqual(redone, accepted, "Both accepted resizes retain their exact timeline")
    }

    func testDiscardColorReplacementAndResetPreservesEarlierKeptState() async throws {
        let c = controller(.color); defer { c.finalizeExit() }
        try color(0.5, c); await c.settleForTesting()
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        c.selectTool(.rotate); await c.settleForTesting()
        c.selectTool(.color); await c.settleForTesting()
        let session = try XCTUnwrap(c.recipe), entry = await session.checkpoint()
        try color(1.5, c); await c.settleForTesting()
        c.revertPendingEdits(); await c.settleForTesting()
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        c.selectTool(.resize); await c.settleForTesting()
        let restored = await session.checkpoint()
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(c.effectiveColor.exposure, 0.5)
    }

    func testUndoBackToToolEntryAndIdentityDraftSkipPrompt() async throws {
        let c = controller(.resize); defer { c.finalizeExit() }
        var asks = 0
        EditToolTransitionModal.responderForTesting = { _ in asks += 1; return .cancel }
        try width("400", c); c.selectTool(.resize)
        try width("600", c) // Don’t upscale makes this an identity target.
        c.selectTool(.rotate)
        XCTAssertEqual(c.currentTool, .rotate)
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        c.performUndo(); await c.settleForTesting()
        c.selectTool(.color); await c.settleForTesting()
        XCTAssertEqual(asks, 0); XCTAssertEqual(c.currentTool, .color)
    }

    func testAutoLevelsRunsAfterAcceptedChoiceButNotCancel() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
            let c = controller(.resize); defer { c.finalizeExit() }
            try width("200", c)
            EditToolTransitionModal.responderForTesting = { _ in choice }
            c.applyLevelsAuto(.color)
            await c.settleForTesting()
            XCTAssertEqual(c.currentTool, choice == .cancel ? .resize : .levels)
            let ops = await c.recipe!.snapshot()
            XCTAssertEqual(ops.contains { if case .levels = $0 { true } else { false } }, choice != .cancel)
        }
    }

    func testClosingWithHeldDecisionIgnoresLateResponseAndReleasesController() async throws {
        var c: EditModeController? = controller(.resize)
        weak let weakController = c
        try width("200", c!)
        var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
        EditToolTransitionModal.presenterForTesting = { _, completion in answer = completion }
        c!.selectTool(.color)
        try await until { answer != nil }
        c!.releaseAfterClose(); c = nil
        answer?(.keep); answer = nil
        try await until { weakController == nil }
    }

    func testToolDecisionAndAcceptedLogicalSizeDoNotWaitForHeldRender() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard] {
            let c = controller(.resize); defer { c.finalizeExit() }
            let renderer = EditRenderer()
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume() }
            var first = true
            var lastImage: CGImage?
            c.onPresentImage = { lastImage = $0 }
            c.renderOverrideForTesting = { recipe, original, hint in
                let snapshot = await recipe.snapshot()
                if first { first = false; await withCheckedContinuation { release = $0 } }
                return await renderer.render(recipe: EditRecipe(operations: snapshot), from: original, qualityHint: hint)
            }
            // Apply before the entry checkpoint task gets a MainActor turn.
            try width("200", c)
            let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
            panel.onApply?(try XCTUnwrap(panel.pendingSpec))
            try await until { release != nil }
            // The accepted 200 × 150 Apply remains while a fresh 100 × 75
            // draft is decided, even though the accepted render is held.
            try width("100", c)
            var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
            EditToolTransitionModal.presenterForTesting = { _, completion in answer = completion }
            c.selectTool(.color)
            let end = Date().addingTimeInterval(3)
            while answer == nil, Date() < end { try await Task.sleep(for: .milliseconds(5)) }
            let presentedWhileRenderHeld = answer != nil
            XCTAssertTrue(presentedWhileRenderHeld, "A renderer is not the decision barrier")
            if !presentedWhileRenderHeld { release?.resume(); release = nil; try await until { answer != nil } }
            answer?(choice)
            try await until { c.currentTool == .color && !c.isTransitioning }
            let expected = CGSize(width: choice == .keep ? 100 : 200, height: choice == .keep ? 75 : 150)
            XCTAssertEqual(c.currentPixelSize, expected)
            release?.resume(); release = nil
            await c.settleForTesting()
            XCTAssertEqual(c.currentPixelSize, expected)
            let image = try XCTUnwrap(lastImage)
            XCTAssertEqual(CGSize(width: image.width, height: image.height), expected)
            let operations = await c.recipe!.snapshot()
            XCTAssertEqual(operations.count, choice == .keep ? 2 : 1)
            XCTAssertFalse(c.chromeState.canRedo, "A discarded draft creates no Redo step")
            EditToolTransitionModal.presenterForTesting = nil
        }
    }

    func testRapidGeometryApplyWithoutNewDraftSwitchesWithoutPromptAndStaysUnsaved() async throws {
        for tool in [EditTool.crop, .resize] {
            let c = controller(tool); defer { c.finalizeExit() }
            let session = try XCTUnwrap(c.recipe)
            var asks = 0
            EditToolTransitionModal.responderForTesting = { _ in asks += 1; return .cancel }
            // Both Applies and the switch are admitted before actor writes or
            // the initial checkpoint receive their first MainActor turn.
            try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
            try stageGeometry(tool, width: 100, c); try applyGeometry(tool, c)
            c.selectTool(.color)
            await c.waitForToolTransitionForTesting()
            XCTAssertEqual(c.currentTool, .color)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
            XCTAssertEqual(asks, 0, "Applied geometry is accepted; no pending draft needs a tool decision")
            await c.settleForTesting()
            let accepted = await session.checkpoint(), operations = await session.snapshot()
            XCTAssertEqual(operations.count, 2)
            XCTAssertTrue(c.chromeState.hasEdits, "Apply does not move the photo's saved-state baseline")
            XCTAssertTrue(c.hasPendingEdits)
            let prepared = await c.prepareForSave()
            XCTAssertTrue(prepared)
            let afterPreparation = await session.checkpoint()
            XCTAssertEqual(afterPreparation, accepted, "Preparing a clean tool cannot duplicate an Apply")
            c.selectTool(tool); await c.settleForTesting()
            XCTAssertNil(c.pendingCropRect())
            if tool == .resize {
                let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
                XCTAssertEqual(panel.sourcePixelSize, CGSize(width: 100, height: 75))
                XCTAssertNil(panel.pendingSpec)
            }
        }
    }

    func testResizeIdentityCaptionUsesTheAcceptedCropAsCurrentImage() async throws {
        let c = controller(.crop); defer { c.finalizeExit() }
        try stageGeometry(.crop, width: 200, c)
        try applyGeometry(.crop, c)
        await c.settleForTesting()
        c.selectTool(.resize)
        await c.settleForTesting()
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        XCTAssertEqual(panel.sourcePixelSize, CGSize(width: 200, height: 150))
        XCTAssertNil(panel.pendingSpec)
        func labels(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? []
                + view.subviews.flatMap { labels(in: $0) }
        }
        XCTAssertTrue(labels(in: panel).contains("Same size as the current photo."),
                      "An accepted crop is the current image; Resize must not claim original-file dimensions")
    }

    func testAppliedGeometryThenNewDraftKeepDiscardCancelPreservesAcceptedTimeline() async throws {
        for tool in [EditTool.crop, .resize] {
            for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
                let c = controller(.color); defer { c.finalizeExit() }
                try color(0.5, c); await c.settleForTesting()
                EditToolTransitionModal.responderForTesting = { _ in .keep }
                c.selectTool(tool); await c.settleForTesting()
                try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
                await c.settleForTesting()
                let session = try XCTUnwrap(c.recipe), accepted = await session.checkpoint()
                let undoTitle = c.undoMenuTitle, redoTitle = c.redoMenuTitle
                try stageGeometry(tool, width: 100, c)
                let crop = c.pendingCropRect(), resize = (c._installedToolForTesting as? ResizePanel)?.draft
                var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
                EditToolTransitionModal.presenterForTesting = { _, completion in answer = completion }
                c.selectTool(.levels); try await until { answer != nil }
                let held = await session.checkpoint()
                XCTAssertEqual(held, accepted, "The sheet must not accept a pending geometry draft")
                answer?(choice); await c.settleForTesting()
                EditToolTransitionModal.presenterForTesting = nil
                if choice == .keep {
                    let operations = await session.snapshot()
                    XCTAssertEqual(operations.count, 3, "Earlier Color + Apply + one kept draft")
                    XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
                    c.performUndo(); await c.settleForTesting()
                    XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
                } else {
                    let retained = await session.checkpoint()
                    XCTAssertEqual(retained, accepted)
                    XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
                    XCTAssertEqual(c.undoMenuTitle, undoTitle); XCTAssertEqual(c.redoMenuTitle, redoTitle)
                    if choice == .cancel {
                        XCTAssertEqual(c.currentTool, tool); XCTAssertEqual(c.pendingCropRect(), crop)
                        let draft = (c._installedToolForTesting as? ResizePanel)?.draft
                        XCTAssertEqual(draft?.width, resize?.width)
                        XCTAssertEqual(draft?.height, resize?.height)
                        XCTAssertEqual(draft?.percent, resize?.percent)
                    } else {
                        XCTAssertEqual(c.currentTool, .levels); XCTAssertNil(c.pendingCropRect())
                        c.selectTool(tool); await c.settleForTesting()
                        XCTAssertNil(c.pendingCropRect())
                        if let panel = c._installedToolForTesting as? ResizePanel {
                            XCTAssertEqual(panel.sourcePixelSize, CGSize(width: 200, height: 150))
                            XCTAssertNil(panel.pendingSpec)
                        }
                    }
                }
                XCTAssertEqual(c.effectiveColor.exposure, 0.5)
                XCTAssertTrue(c.chromeState.hasEdits)
            }
        }
    }

    func testTwoAppliedOffsetCropsAndEarlierColorSurviveDiscardWithExactProvenance() async throws {
        let c = controller(.color); defer { c.finalizeExit() }
        try color(0.5, c); await c.settleForTesting()
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        c.selectTool(.crop); await c.settleForTesting()
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 40, y: 30, width: 300, height: 240))
        try applyGeometry(.crop, c); await c.settleForTesting()
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 30, y: 24, width: 200, height: 160))
        try applyGeometry(.crop, c); await c.settleForTesting()
        let session = try XCTUnwrap(c.recipe), accepted = await session.checkpoint()
        let operations = await session.snapshot(), undoTitle = c.undoMenuTitle
        XCTAssertEqual(operations.count, 3)
        guard case .crop(let first) = operations[1], case .crop(let second) = operations[2] else {
            return XCTFail("Both accepted crops keep their original provenance")
        }
        XCTAssertEqual(first.originX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(first.originY, 0.1, accuracy: 0.0001)
        XCTAssertEqual(second.originX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(second.originY, 0.1, accuracy: 0.0001)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 10, y: 8, width: 100, height: 80))
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        c.selectTool(.resize); await c.settleForTesting()
        let retained = await session.checkpoint()
        XCTAssertEqual(retained, accepted)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 160))
        XCTAssertEqual(c.undoMenuTitle, undoTitle); XCTAssertFalse(c.chromeState.canRedo)
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 300, height: 240))
        c.performUndo(); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(c.effectiveColor.exposure, 0.5)
    }

    func testGeometryDraftDiscardPreservesCurrentUndoRedoAndGlobalResetState() async throws {
        for tool in [EditTool.crop, .resize] {
            for state in ["undo", "redo", "reset"] {
                let c = controller(tool); defer { c.finalizeExit() }
                try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
                await c.settleForTesting()
                c.performUndo(); await c.settleForTesting()
                if state == "redo" { c.performRedo(); await c.settleForTesting() }
                if state == "reset" { c.revertPendingEdits(); await c.settleForTesting() }
                let session = try XCTUnwrap(c.recipe), current = await session.checkpoint()
                let size = c.currentPixelSize, undoTitle = c.undoMenuTitle, redoTitle = c.redoMenuTitle
                let canUndo = c.chromeState.canUndo, canRedo = c.chromeState.canRedo
                try stageGeometry(tool, width: 100, c)
                EditToolTransitionModal.responderForTesting = { _ in .discard }
                c.selectTool(.color); await c.settleForTesting()
                let retained = await session.checkpoint()
                XCTAssertEqual(retained, current, "Draft Discard must preserve intentional \(state)")
                XCTAssertEqual(c.currentPixelSize, size)
                XCTAssertEqual(c.undoMenuTitle, undoTitle); XCTAssertEqual(c.redoMenuTitle, redoTitle)
                XCTAssertEqual(c.chromeState.canUndo, canUndo); XCTAssertEqual(c.chromeState.canRedo, canRedo)
                if state == "undo" {
                    XCTAssertFalse(c.chromeState.hasEdits)
                    XCTAssertTrue(c.chromeState.canRedo)
                    c.performRedo(); await c.settleForTesting()
                    XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
                    let operations = await session.snapshot(); XCTAssertEqual(operations.count, 1)
                } else if state == "reset" {
                    XCTAssertFalse(c.chromeState.hasEdits)
                    let operations = await session.snapshot(); XCTAssertTrue(operations.isEmpty)
                    XCTAssertFalse(c.chromeState.canRedo)
                } else {
                    XCTAssertTrue(c.chromeState.hasEdits)
                    let operations = await session.snapshot(); XCTAssertEqual(operations.count, 1)
                }
            }
        }
    }

    func testCropResetAndIdentityOrInvalidResizeApplyDoNotInventAcceptedHistory() async throws {
        for tool in [EditTool.crop, .resize] {
            let c = controller(tool); defer { c.finalizeExit() }
            try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
            await c.settleForTesting()
            let session = try XCTUnwrap(c.recipe), accepted = await session.checkpoint()
            if tool == .crop {
                try stageGeometry(tool, width: 100, c)
                let panel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
                panel._resetButton.performClick(nil)
                XCTAssertNil(c.pendingCropRect())
                panel._applyButton.performClick(nil)
            } else {
                let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
                try width("200", c); panel._applyButton.performClick(nil) // Identity.
                try width("600", c); panel._applyButton.performClick(nil) // Prevent upscale.
                try width("invalid", c); panel._applyButton.performClick(nil)
                XCTAssertNil(panel.pendingSpec)
            }
            var asks = 0
            EditToolTransitionModal.responderForTesting = { _ in asks += 1; return .cancel }
            c.selectTool(.color); await c.settleForTesting()
            XCTAssertEqual(asks, 0); XCTAssertEqual(c.currentTool, .color)
            let retained = await session.checkpoint()
            XCTAssertEqual(retained, accepted)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        }
    }

    private func editingViewer(highPrecision: Bool = false, failingBackup: Bool = false) async throws -> (ViewerWindow, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-transitions-\(UUID())")
        ownedRoots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<3).map { root.appendingPathComponent("photo-\($0).png") }
        for (index, url) in urls.enumerated() {
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            let image: CGImage
            if highPrecision && index == 0 {
                let values = (0..<(400 * 300)).map { UInt16($0 % 65536) }
                let data = values.withUnsafeBytes { Data($0) }
                let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                image = try XCTUnwrap(CGImage(width: 400, height: 300, bitsPerComponent: 16, bitsPerPixel: 16,
                    bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little,
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            } else { image = SaveFlowTests.image(width: 400, height: 300, red: CGFloat(index + 1) / 3) }
            CGImageDestinationAddImage(dest, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        var services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        services.backupStore = failingBackup
            ? BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 }, maxBytes: { 1 << 30 },
                          now: { Date() }, copier: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
            : BackupStore(root: root.appendingPathComponent("Backups"))
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.alphaValue = 0; viewer.ignoresMouseEvents = true
        viewer.makeKeyAndOrderFront(nil); viewer.setContentSize(NSSize(width: 1000, height: 700))
        do {
            try await until { viewer.canPerform(.editImage) && viewer.displayedItem?.group.primary == urls[0] }
            viewer.enterEditMode(landOn: .crop); await viewer.waitForEditLoad()
            XCTAssertTrue(viewer.contentRootForTesting.editModeController.isActive)
            return (viewer, urls)
        } catch { viewer.close(); throw error }
    }

    func testPhotoSaveRetainsAppliedGeometryAndWritesOnlyTheChosenDraft() async throws {
        for tool in [EditTool.crop, .resize] {
            for discardDraft in [false, true] {
                let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
                let c = viewer.contentRootForTesting.editModeController
                if tool == .resize { c.selectTool(.resize); await c.settleForTesting() }
                let originalBytes = try urls.map { try Data(contentsOf: $0) }
                try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
                await c.settleForTesting()
                try stageGeometry(tool, width: 100, c)
                if discardDraft {
                    EditToolTransitionModal.responderForTesting = { _ in .discard }
                    c.selectTool(.color); await c.settleForTesting()
                }
                XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes,
                               "Apply and a tool decision do not save a file")
                var toolAsks = 0
                EditToolTransitionModal.responderForTesting = { _ in toolAsks += 1; return .cancel }
                var answer: (@MainActor (EditExitModal.Choice) -> Void)?
                EditExitModal.presenterForTesting = { content, completion in
                    XCTAssertEqual(content.primary, .save)
                    answer = completion
                }
                viewer.dispatch(.nextImage); try await until { answer != nil }
                let operations = await c.recipe!.snapshot()
                XCTAssertEqual(operations.count, discardDraft ? 1 : 2,
                               "Photo preparation accepts the pending draft exactly once")
                answer?(.save); await viewer.waitForEditExit()
                EditExitModal.presenterForTesting = nil
                try await until { viewer.displayedItem?.group.primary == urls[1] && viewer.navCoalescer.isIdle }
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, discardDraft ? 200 : 100)
                XCTAssertEqual(image.height, discardDraft ? 150 : 75)
                XCTAssertEqual(toolAsks, 0, "Photo departure has its own single decision")
                XCTAssertEqual(try Data(contentsOf: urls[1]), originalBytes[1])
                XCTAssertEqual(try Data(contentsOf: urls[2]), originalBytes[2])
                _ = viewer.cancelEditLoad()
            }
        }
    }

    func testCancelledOrFailedPhotoSaveRestoresAppliedHistoryAndExactNewDraft() async throws {
        for tool in [EditTool.crop, .resize] {
            for outcome in ["cancel", "copyCancel", "failure"] {
                let (viewer, urls) = try await editingViewer(highPrecision: outcome == "copyCancel",
                                                           failingBackup: outcome == "failure")
                defer { viewer.close() }
                let c = viewer.contentRootForTesting.editModeController
                if outcome == "copyCancel", tool == .crop {
                    // Pure Crop preserves 16-bit PNG precision and permits Save.
                    // Add a real accepted adjustment to exercise conversion's
                    // Save Copy cancellation without changing the save policy.
                    c.selectTool(.color); try color(0.5, c); await c.settleForTesting()
                    EditToolTransitionModal.responderForTesting = { _ in .keep }
                    c.selectTool(.crop); await c.settleForTesting()
                }
                if tool == .resize { c.selectTool(.resize); await c.settleForTesting() }
                try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
                await c.settleForTesting()
                let session = try XCTUnwrap(c.recipe), accepted = await session.checkpoint()
                let undoTitle = c.undoMenuTitle
                try stageGeometry(tool, width: 100, c)
                let crop = c.pendingCropRect(), resize = (c._installedToolForTesting as? ResizePanel)?.draft
                let bytes = try urls.map { try Data(contentsOf: $0) }
                var asks = 0
                EditExitModal.responderForTesting = { content in
                    asks += 1
                    if outcome == "copyCancel" {
                        XCTAssertEqual(content.primary, .saveAs)
                        XCTAssertTrue(content.information.contains("16-bit"))
                        return .saveAs
                    }
                    return outcome == "failure" ? .save : .cancel
                }
                viewer.savePanelResponderForTesting = { _, _ in nil }
                viewer.alertResponderForTesting = { _ in 1 }
                viewer.dispatch(.nextImage); await viewer.waitForEditExit(); await c.settleForTesting()
                XCTAssertEqual(asks, 1)
                XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0])
                XCTAssertTrue(c.isActive); XCTAssertFalse(c.isSaving); XCTAssertFalse(c.isTransitioning)
                XCTAssertEqual(c.currentTool, tool)
                XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
                let restored = await session.checkpoint()
                XCTAssertEqual(restored, accepted, "Cancelled/failed save retains accepted Apply without duplicating its draft")
                XCTAssertEqual(c.undoMenuTitle, undoTitle)
                XCTAssertEqual(c.pendingCropRect(), crop)
                let currentDraft = (c._installedToolForTesting as? ResizePanel)?.draft
                XCTAssertEqual(currentDraft?.width, resize?.width)
                XCTAssertEqual(currentDraft?.height, resize?.height)
                XCTAssertEqual(currentDraft?.percent, resize?.percent)
                XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
                EditToolTransitionModal.responderForTesting = { _ in .discard }
                c.selectTool(.color); await c.settleForTesting()
                let retained = await session.checkpoint()
                XCTAssertEqual(retained, accepted, "A later tool Discard still removes only the restored draft")
                XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
            }
        }
    }

    func testPureSixteenBitCropKeepsSaveInPlaceAndPreservesDecodedSampleBytes() async throws {
        let (viewer, urls) = try await editingViewer(highPrecision: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
        XCTAssertEqual(original.bitsPerComponent, 16)
        XCTAssertEqual(original.bitsPerPixel, 16)
        try stageGeometry(.crop, width: 200, c); try applyGeometry(.crop, c)
        await c.settleForTesting()
        try stageGeometry(.crop, width: 100, c)
        var asks = 0, copyPanels = 0
        EditExitModal.responderForTesting = { content in
            asks += 1
            XCTAssertEqual(content.primary, .save, "Pure Crop preserves PNG precision; it does not require conversion")
            XCTAssertEqual(content.buttons[0], "Save")
            XCTAssertFalse(content.information.contains("convert"))
            return .save
        }
        viewer.savePanelResponderForTesting = { _, _ in copyPanels += 1; return nil }
        viewer.dispatch(.nextImage); await viewer.waitForEditExit()
        try await until { viewer.displayedItem?.group.primary == urls[1] && viewer.navCoalescer.isIdle }
        XCTAssertEqual(asks, 1); XCTAssertEqual(copyPanels, 0)
        let savedSource = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(savedSource, 0, nil) as? [CFString: Any])
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(savedSource, 0, nil))
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(saved.bitsPerComponent, 16); XCTAssertEqual(saved.bitsPerPixel, 16)
        XCTAssertEqual(saved.width, 100); XCTAssertEqual(saved.height, 75)
        XCTAssertNotEqual(try Data(contentsOf: urls[0]), originalBytes[0], "Save really replaces the source with its cropped pixels")
        let sourcePixels = try XCTUnwrap(original.dataProvider?.data) as Data
        let savedPixels = try XCTUnwrap(saved.dataProvider?.data) as Data
        // Compare every decoded grayscale sample byte, excluding row padding.
        // Both images use the same PNG decoder and 16-bit gray representation.
        guard original.bitsPerPixel == 16, saved.bitsPerPixel == 16,
              original.width >= 100, original.height >= 75, saved.width == 100, saved.height == 75,
              sourcePixels.count >= original.bytesPerRow * original.height,
              savedPixels.count >= saved.bytesPerRow * saved.height else {
            return XCTFail("Expected addressable 16-bit gray source and saved pixels")
        }
        var expected = Data(), actual = Data()
        for row in 0..<75 {
            let sourceOffset = row * original.bytesPerRow, savedOffset = row * saved.bytesPerRow
            expected.append(sourcePixels[sourceOffset..<(sourceOffset + 200)])
            actual.append(savedPixels[savedOffset..<(savedOffset + 200)])
        }
        XCTAssertEqual(actual, expected, "Apply plus pending Crop preserves every selected 16-bit sample")
        XCTAssertEqual(try Data(contentsOf: urls[1]), originalBytes[1])
        XCTAssertEqual(try Data(contentsOf: urls[2]), originalBytes[2])
        _ = viewer.cancelEditLoad()
    }

    func testPhotoDiscardDropsAllUnsavedAppliedAndDraftGeometryWithoutWriting() async throws {
        for tool in [EditTool.crop, .resize] {
            let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
            let c = viewer.contentRootForTesting.editModeController
            if tool == .resize { c.selectTool(.resize); await c.settleForTesting() }
            let bytes = try urls.map { try Data(contentsOf: $0) }
            try stageGeometry(tool, width: 200, c); try applyGeometry(tool, c)
            await c.settleForTesting()
            let departedRecipe = try XCTUnwrap(c.recipe)
            try stageGeometry(tool, width: 100, c)
            var asks = 0, toolAsks = 0
            EditToolTransitionModal.responderForTesting = { _ in toolAsks += 1; return .cancel }
            EditExitModal.responderForTesting = { content in
                asks += 1
                XCTAssertTrue(content.information.contains("all unsaved edits to this photo"))
                return .discard
            }
            viewer.dispatch(.nextImage); await viewer.waitForEditExit()
            try await until { viewer.displayedItem?.group.primary == urls[1] && viewer.navCoalescer.isIdle }
            // Windowed editing resumes on the target after navigation. Observe
            // that final state rather than the transient gap between sessions.
            await viewer.waitForEditReentryForTesting()
            await c.settleForTesting()
            XCTAssertEqual(asks, 1); XCTAssertEqual(toolAsks, 0)
            XCTAssertTrue(c.isActive)
            XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
            let targetRecipe = try XCTUnwrap(c.recipe)
            XCTAssertFalse(targetRecipe === departedRecipe, "The target owns a fresh recipe; the discarded source session is released")
            XCTAssertEqual(c.sourceURL, urls[1])
            XCTAssertNil(c.currentTool)
            let operations = await targetRecipe.snapshot()
            let undoDepth = await targetRecipe.undoDepth, redoDepth = await targetRecipe.redoDepth
            XCTAssertTrue(operations.isEmpty)
            XCTAssertEqual(undoDepth, 0); XCTAssertEqual(redoDepth, 0)
            XCTAssertFalse(c.chromeState.canUndo); XCTAssertFalse(c.chromeState.canRedo)
            XCTAssertFalse(c.chromeState.hasEdits); XCTAssertFalse(c.chromeState.hasPendingToolEdits)
            XCTAssertFalse(c.hasPendingEdits); XCTAssertFalse(c.isTransitioning)
            XCTAssertNil(c.pendingCropRect())
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
            let target = try XCTUnwrap(c.originalImage)
            XCTAssertEqual(target.width, 400); XCTAssertEqual(target.height, 300)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(urls[1] as CFURL, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            func rgbaPixels(_ image: CGImage) throws -> Data {
                let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
            }
            XCTAssertEqual(try rgbaPixels(target), try rgbaPixels(expected),
                           "The new editor displays the target's original pixels without discarded source geometry")
            XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
            _ = viewer.cancelEditLoad()
        }
    }

    func testFocusedResizeCancelRestoresFieldFocusAndTypedDraft() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.selectTool(.resize)
        let field = try XCTUnwrap((c._installedToolForTesting as? ResizePanel)?._widthField)
        XCTAssertTrue(viewer.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("200", replacementRange: editor.selectedRange())
        let bytes = try Data(contentsOf: urls[0])
        EditToolTransitionModal.responderForTesting = { _ in .cancel }
        c.selectTool(.color); await c.settleForTesting()
        XCTAssertEqual(c.currentTool, .resize)
        XCTAssertEqual(field.stringValue, "200")
        XCTAssertTrue((viewer.firstResponder as? NSTextView)?.delegate === field)
        XCTAssertEqual(try Data(contentsOf: urls[0]), bytes)
        let operations = await c.recipe!.snapshot()
        XCTAssertTrue(operations.isEmpty)
    }

    func testPhotoCancelRestoresDraftAndBlocksUnderlyingCommands() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        let crop = try XCTUnwrap(c.pendingCropRect()), session = try XCTUnwrap(c.recipe)
        let bytes = try urls.map { try Data(contentsOf: $0) }
        var answer: (@MainActor (EditExitModal.Choice) -> Void)?
        var asks = 0, toolAsks = 0
        EditToolTransitionModal.responderForTesting = { _ in toolAsks += 1; return .keep }
        EditExitModal.presenterForTesting = { content, completion in
            asks += 1; XCTAssertEqual(content.buttons, ["Save", "Cancel", "Don't Save"])
            answer = completion
        }
        viewer.dispatch(.nextImage)
        try await until { answer != nil }
        let prepared = await session.checkpoint()
        c.performUndo(); c.performRedo(); c.revertPendingEdits(); c.applyLevelsAuto(.color); c.selectTool(.resize)
        viewer.dispatch(.lastImage)
        let held = await session.checkpoint()
        XCTAssertEqual(held, prepared)
        answer?(.cancel); await viewer.waitForEditExit(); await c.settleForTesting()
        XCTAssertEqual(asks, 1); XCTAssertEqual(toolAsks, 0)
        XCTAssertTrue(c.isActive); XCTAssertFalse(c.isTransitioning)
        XCTAssertEqual(c.currentTool, .crop); XCTAssertEqual(c.pendingCropRect(), crop)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        let operations = await session.snapshot()
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
        // The original tool checkpoint remains valid after a cancelled photo exit.
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        c.selectTool(.color); await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
    }

    func testPhotoSavePersistsCurrentSourceThenGoesToFirstRequestedTarget() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        let neighborBytes = try Data(contentsOf: urls[1])
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        var answer: (@MainActor (EditExitModal.Choice) -> Void)?
        EditExitModal.presenterForTesting = { _, completion in answer = completion }
        viewer.dispatch(.nextImage)
        try await until { answer != nil }
        viewer.dispatch(.lastImage)
        answer?(.save); await viewer.waitForEditExit()
        try await until { viewer.displayedItem?.group.primary == urls[1] && viewer.navCoalescer.isIdle }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 150)
        XCTAssertEqual(try Data(contentsOf: urls[1]), neighborBytes)
        _ = viewer.cancelEditLoad()
    }

    func testPhotoCopyCancelRestoresResizeDraftWithoutWriting() async throws {
        let (viewer, urls) = try await editingViewer(highPrecision: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.selectTool(.resize); try width("200", c)
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        let before = try Data(contentsOf: urls[0])
        var asked = 0
        EditExitModal.responderForTesting = { content in
            asked += 1; XCTAssertEqual(content.primary, .saveAs)
            XCTAssertEqual(content.buttons[0], "Save Copy…")
            XCTAssertTrue(content.information.contains("16-bit"))
            return .saveAs
        }
        viewer.savePanelResponderForTesting = { _, _ in nil }
        viewer.dispatch(.nextImage); await viewer.waitForEditExit(); await c.settleForTesting()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0]); XCTAssertTrue(c.isActive)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(panel._widthField.stringValue, "200"); XCTAssertNotNil(panel.pendingSpec)
        XCTAssertEqual(try Data(contentsOf: urls[0]), before)
        let operations = await c.recipe!.snapshot(); XCTAssertTrue(operations.isEmpty)
    }

    func testZeroRotateThenToolAndNextDoNotPromptOrWriteFiles() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        let before = try urls.map { try Data(contentsOf: $0) }
        c.selectTool(.rotate)
        let panel = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
        panel.onAngleChanged?(10); panel.onAngleChanged?(0); panel.onAngleCommitted?(0)
        await c.settleForTesting()
        var toolAsks = 0, photoAsks = 0
        EditToolTransitionModal.responderForTesting = { _ in toolAsks += 1; return .cancel }
        EditExitModal.responderForTesting = { _ in photoAsks += 1; return .cancel }
        c.selectTool(.color); await c.waitForToolTransitionForTesting()
        XCTAssertEqual(c.currentTool, .color)
        viewer.dispatch(.nextImage); await viewer.waitForEditExit()
        try await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == urls[1] }
        XCTAssertEqual(toolAsks, 0); XCTAssertEqual(photoAsks, 0)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        _ = viewer.cancelEditLoad()
    }

    func testPhotoSaveRefusalKeepsDraftAndAllOriginalBytes() async throws {
        for invalidIdentity in [false, true] {
            let (viewer, urls) = try await editingViewer(failingBackup: !invalidIdentity)
            defer { viewer.close() }
            let c = viewer.contentRootForTesting.editModeController
            c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
            let crop = try XCTUnwrap(c.pendingCropRect()), before = try urls.map { try Data(contentsOf: $0) }
            var answer: (@MainActor (EditExitModal.Choice) -> Void)?
            EditExitModal.presenterForTesting = { _, completion in answer = completion }
            viewer.alertResponderForTesting = { _ in 1 }
            viewer.dispatch(.nextImage); try await until { answer != nil }
            if invalidIdentity { viewer.markDisplayedForTesting(1) }
            answer?(.save); await viewer.waitForEditExit(); await c.settleForTesting()
            XCTAssertTrue(c.isActive); XCTAssertEqual(c.currentTool, .crop)
            XCTAssertEqual(c.pendingCropRect(), crop)
            XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
            XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
            let operations = await c.recipe!.snapshot(); XCTAssertTrue(operations.isEmpty)
            if invalidIdentity { viewer.markDisplayedForTesting(0) }
            else { XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0]) }
        }
    }

    func testPhotoFailureNeverPublishesUnlockedControlsBeforeDraftRestoration() async throws {
        let (viewer, urls) = try await editingViewer(failingBackup: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        let crop = try XCTUnwrap(c.pendingCropRect()), before = try urls.map { try Data(contentsOf: $0) }
        let previous = c.onChromeStateChanged
        var didSave = false, observed: EditChromeState?, geometryAccepted: Bool?
        var toolAsks = 0
        EditToolTransitionModal.responderForTesting = { _ in toolAsks += 1; return .cancel }
        c.onChromeStateChanged = { [weak c] state in
            previous?(state)
            if state.isSaving { didSave = true }
            else if didSave && observed == nil {
                observed = state
                geometryAccepted = c?.cropOverlay.acceptsGeometryInput
                c?.performUndo(); c?.revertPendingEdits(); c?.selectTool(.color)
            }
        }
        defer { c.onChromeStateChanged = previous }
        EditExitModal.responderForTesting = { _ in .save }
        viewer.alertResponderForTesting = { _ in 1 }
        viewer.dispatch(.nextImage); await viewer.waitForEditExit(); await c.settleForTesting()
        XCTAssertTrue(try XCTUnwrap(observed).isTransitioning, "Saving(false) must retain the departure lock")
        XCTAssertFalse(try XCTUnwrap(observed).acceptsInput)
        XCTAssertEqual(geometryAccepted, false)
        XCTAssertEqual(toolAsks, 0)
        XCTAssertEqual(c.currentTool, .crop); XCTAssertEqual(c.pendingCropRect(), crop)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        let operations = await c.recipe!.snapshot(); XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        XCTAssertTrue(c.chromeState.acceptsInput); XCTAssertTrue(c.cropOverlay.acceptsGeometryInput)
    }

    func testOldCopyCancellationCannotRestoreOrUnlockNewSessionDeparture() async throws {
        let (viewer, urls) = try await editingViewer(highPrecision: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.selectTool(.resize); try width("200", c)
        EditExitModal.responderForTesting = { _ in .saveAs }
        var panelAnswer: CheckedContinuation<URL?, Never>?
        viewer.savePanelAsyncResponderForTesting = { _, _ in await withCheckedContinuation { panelAnswer = $0 } }
        defer { panelAnswer?.resume(returning: nil) }
        viewer.dispatch(.nextImage); try await until { panelAnswer != nil }
        let oldDeparture = viewer.editExitTask
        c.finalizeExit()
        await viewer.navigate(to: 1)
        try await until { viewer.canPerform(.editImage) && viewer.displayedItem?.group.primary == urls[1] }
        viewer.enterEditMode(landOn: nil); await viewer.waitForEditLoad()
        let newSession = try XCTUnwrap(c.recipe)
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        var answer: (@MainActor (EditExitModal.Choice) -> Void)?
        EditExitModal.presenterForTesting = { _, completion in answer = completion }
        c.attemptExit(reason: .navigation); try await until { answer != nil }
        let prepared = await newSession.checkpoint()
        panelAnswer?.resume(returning: nil); panelAnswer = nil
        await oldDeparture?.value
        XCTAssertTrue(c.recipe === newSession)
        XCTAssertTrue(c.isTransitioning, "Old Save Copy cancellation cannot unlock the new photo decision")
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 300, height: 400))
        let unchanged = await newSession.checkpoint()
        XCTAssertEqual(unchanged, prepared)
        answer?(.cancel)
        try await until { !c.isTransitioning }
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 300, height: 400))
        XCTAssertTrue(c.hasPendingEdits)
        XCTAssertTrue(c.chromeState.canUndo)
    }

    func testOldSaveCompletionCannotClearNewSessionsSavingState() async throws {
        let (viewer, urls) = try await editingViewer(highPrecision: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.selectTool(.resize); try width("200", c)
        EditExitModal.responderForTesting = { _ in .saveAs }
        var answers: [CheckedContinuation<URL?, Never>?] = []
        viewer.savePanelAsyncResponderForTesting = { _, _ in
            await withCheckedContinuation { answers.append($0) }
        }
        defer { for answer in answers { answer?.resume(returning: nil) } }
        viewer.dispatch(.nextImage); try await until { answers.count == 1 }
        let oldDeparture = viewer.editExitTask
        c.finalizeExit()
        await viewer.navigate(to: 1)
        try await until { viewer.canPerform(.editImage) && viewer.displayedItem?.group.primary == urls[1] }
        viewer.enterEditMode(landOn: nil); await viewer.waitForEditLoad()
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        let newSession = try XCTUnwrap(c.recipe)
        c.attemptExit(reason: .navigation)
        try await until { answers.count == 2 && c.isSaving }
        let history = await newSession.checkpoint()
        answers[0]?.resume(returning: nil); answers[0] = nil
        await oldDeparture?.value
        XCTAssertTrue(c.recipe === newSession)
        XCTAssertTrue(c.isSaving, "Old exporter cleanup must not clear another session’s Saving state")
        XCTAssertFalse(c.chromeState.acceptsInput)
        let unchanged = await newSession.checkpoint(); XCTAssertEqual(unchanged, history)
        answers[1]?.resume(returning: nil); answers[1] = nil
        try await until { !c.isSaving && !c.isTransitioning }
        await c.settleForTesting()
        XCTAssertTrue(c.isActive); XCTAssertEqual(c.currentPixelSize, CGSize(width: 300, height: 400))
        XCTAssertTrue(c.chromeState.acceptsInput)
    }

    func testHeldPhotoPreparationReplacementAndCloseResolvesOriginalRequestAndReleasesWindow() throws {
        try runWithoutXCTestEventPump { try await self.heldPhotoPreparationReplacementAndCloseResolvesOriginalRequestAndReleasesWindow() }
    }
    private func heldPhotoPreparationReplacementAndCloseResolvesOriginalRequestAndReleasesWindow() async throws {
        for replaceSession in [false, true] {
            var viewer: ViewerWindow?
            var urls: [URL] = []
            do { let opened = try await editingViewer(); viewer = opened.0; urls = opened.1 }
            let c = try XCTUnwrap(viewer).contentRootForTesting.editModeController
            let before = try urls.map { try Data(contentsOf: $0) }
            var release: CheckedContinuation<Void, Never>?
            defer { release?.resume(); viewer?.close() }
            c.renderOverrideForTesting = { _, image, _ in
                await withCheckedContinuation { release = $0 }
                return image
            }
            c.appendSnapped90(quarters: 1)
            try await until { release != nil }
            viewer?.dispatch(.nextImage)
            try await until { c.isTransitioning }
            let task = try XCTUnwrap(viewer?.editExitTask)
            var finished = false
            let observer = Task { await task.value; finished = true }
            if replaceSession {
                c.finalizeExit()
                await viewer?.navigate(to: 1)
                viewer?.enterEditMode(landOn: nil); await viewer?.waitForEditLoad()
                XCTAssertTrue(c.isActive)
            }
            weak let closedWindow = viewer
            viewer?.close(); viewer = nil
            let deadline = Date().addingTimeInterval(3)
            while (!finished || closedWindow != nil), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(finished, "The original request completes even before its old renderer returns")
            if let closedWindow { LifetimeDiagnostics.dump(name, alive: [("ViewerWindow", closedWindow)]) }
            XCTAssertNil(closedWindow, "A suspended original exit must not retain a closed viewer")
            release?.resume(); release = nil
            await observer.value
            await c.settleForTesting()
            XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        }
    }

    func testPhotoRequestCompletesOnceWithoutReplacingNextSessionHandler() async throws {
        let (viewer, _) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        let image = try XCTUnwrap(c.originalImage)
        let url = c.sourceURL
        for choice in [EditExitModal.Choice.cancel, .discard, .save, .saveAs] {
            if !c.isActive { c.enter(image: image, url: url, landOn: .crop) }
            c.appendSnapped90(quarters: 1); await c.settleForTesting()
            EditExitModal.responderForTesting = { _ in choice }
            var outcomes: [EditExitOutcome] = []
            c.attemptExit(reason: .navigation) { outcomes.append($0) }
            try await until { !outcomes.isEmpty }
            let expected: EditExitOutcome = switch choice {
            case .cancel: .cancelled
            case .discard: .exited
            case .save: .needsSave
            case .saveAs: .needsSaveAs
            }
            XCTAssertEqual(outcomes, [expected])
            c.finalizeExit(); await c.settleForTesting()
            XCTAssertEqual(outcomes, [expected], "Teardown cannot complete an answered request twice")
        }
        c.enter(image: image, url: url, landOn: nil)
        var clean: [EditExitOutcome] = []
        c.attemptExit(reason: .navigation) { clean.append($0) }
        try await until { !clean.isEmpty }
        XCTAssertEqual(clean, [.exited])
        c.enter(image: image, url: url, landOn: nil)
        var nextHandlerCalls = 0
        c.onExitOutcome = { _ in nextHandlerCalls += 1 }
        XCTAssertEqual(clean, [.exited]); XCTAssertEqual(nextHandlerCalls, 0)
    }

    private actor ExportGate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func open() { released = true; continuation?.resume(); continuation = nil }
    }

    func testCompletedOldExportWritesItsOriginalButCannotFinalizeOrNavigateNewPhoto() async throws {
        for copy in [false, true] {
            let (viewer, urls) = try await editingViewer(highPrecision: copy); defer { viewer.close() }
            let c = viewer.contentRootForTesting.editModeController
            c.selectTool(.resize); try width("200", c)
            let before = try urls.map { try Data(contentsOf: $0) }
            let destination = urls[0].deletingLastPathComponent().appendingPathComponent("completed-copy.png")
            let gate = ExportGate()
            viewer.exportCheckpointForTesting = { point in if point == .beforeCommit { await gate.hold() } }
            EditExitModal.responderForTesting = { _ in copy ? .saveAs : .save }
            viewer.savePanelResponderForTesting = { _, _ in destination }
            viewer.dispatch(.nextImage)
            let oldDeparture = viewer.editExitTask
            do {
                let deadline = Date().addingTimeInterval(3)
                while !(await gate.entered), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
                let entered = await gate.entered
                XCTAssertTrue(entered, "The actual exporter reached its pre-commit checkpoint")
                c.finalizeExit()
                await viewer.navigate(to: 2)
                try await until { viewer.canPerform(.editImage) && viewer.displayedItem?.group.primary == urls[2] }
                viewer.enterEditMode(landOn: nil); await viewer.waitForEditLoad()
                c.appendSnapped90(quarters: 1); await c.settleForTesting()
                let newSession = try XCTUnwrap(c.recipe), history = await newSession.checkpoint()
                let undoName = viewer.undoManagerForTesting.undoActionName
                let toast = viewer.contentRootForTesting.toastHost.content?.message
                await gate.open(); await oldDeparture?.value
                try await until { viewer.navCoalescer.isIdle }
                XCTAssertTrue(c.recipe === newSession, "An old completed export cannot finalize the new edit")
                XCTAssertTrue(c.isActive)
                XCTAssertEqual(viewer.displayedItem?.group.primary, urls[2], "The old departure cannot navigate the new photo")
                let unchanged = await newSession.checkpoint(); XCTAssertEqual(unchanged, history)
                XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, undoName)
                XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, toast)
                XCTAssertEqual(try Data(contentsOf: urls[2]), before[2])
                XCTAssertEqual(try Data(contentsOf: urls[1]), before[1])
                let written = copy ? destination : urls[0]
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 150)
                if copy { XCTAssertEqual(try Data(contentsOf: urls[0]), before[0]) }
                else { XCTAssertNotEqual(try Data(contentsOf: urls[0]), before[0]) }
            } catch {
                await gate.open(); await oldDeparture?.value
                throw error
            }
        }
    }

    func testRemovedAdjacentFolderIsNotOpenedFromPreDecisionSnapshot() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        let target = urls[0].deletingLastPathComponent().appendingPathComponent("Next", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: urls[1], to: target.appendingPathComponent("next.png"))
        var answer: (@MainActor (EditExitModal.Choice) -> Void)?
        EditExitModal.presenterForTesting = { _, completion in answer = completion }
        let bytes = try Data(contentsOf: urls[0])
        viewer.goToAdjacentFolder(.next, knownTarget: target); try await until { answer != nil }
        try FileManager.default.removeItem(at: target)
        answer?(.discard); await viewer.waitForEditExit()
        XCTAssertEqual(viewer.groups.map(\.primary), urls)
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0])
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, "That photo is no longer available.")
        XCTAssertEqual(try Data(contentsOf: urls[0]), bytes)
    }

    func testPhotoCopySaveInsertsCopyWithoutRetargetingRequestedNeighbor() async throws {
        let (viewer, urls) = try await editingViewer(highPrecision: true); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.selectTool(.resize); try width("200", c)
        let before = try urls.map { try Data(contentsOf: $0) }
        let copy = urls[0].deletingLastPathComponent().appendingPathComponent("new-copy.png")
        EditExitModal.responderForTesting = { content in XCTAssertEqual(content.primary, .saveAs); return .saveAs }
        viewer.savePanelResponderForTesting = { _, _ in copy }
        viewer.dispatch(.nextImage); await viewer.waitForEditExit()
        try await until { viewer.displayedItem?.group.primary == urls[1] && viewer.navCoalescer.isIdle }
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 150)
        XCTAssertTrue(viewer.groups.contains { $0.primary == copy })
        _ = viewer.cancelEditLoad()
    }

    func testEarlierKeptCropAndLevelsSurviveDiscardedReplacement() async throws {
        let c = controller(.crop); defer { c.finalizeExit() }
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        c.selectTool(.levels); await c.settleForTesting()
        var panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        var field = try XCTUnwrap(panel._field(.inBlack))
        field.stringValue = "20"; _ = field.sendAction(field.action, to: field.target)
        await c.settleForTesting()
        c.selectTool(.rotate); await c.settleForTesting()
        c.selectTool(.levels); await c.settleForTesting()
        let session = try XCTUnwrap(c.recipe), checkpoint = await session.checkpoint()
        let undoTitle = c.undoMenuTitle
        panel = try XCTUnwrap(c._installedToolForTesting as? LevelsPanel)
        field = try XCTUnwrap(panel._field(.inBlack))
        field.stringValue = "40"; _ = field.sendAction(field.action, to: field.target)
        await c.settleForTesting()
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        c.selectTool(.resize); await c.settleForTesting()
        let result = await session.checkpoint()
        XCTAssertEqual(result, checkpoint)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(c.effectiveLevels.master.inBlack, 20)
        XCTAssertEqual(c.undoMenuTitle, undoTitle)
    }

    func testFreeRotateLogicalExtentIsAvailableBeforeHeldRenderAndMatchesOutput() async throws {
        for angle in [-10.0, 10.0, 45.0] {
            let c = controller(.rotate); defer { c.finalizeExit() }
            let renderer = EditRenderer()
            var release: CheckedContinuation<Void, Never>?
            var output: CGImage?
            c.onPresentImage = { output = $0 }
            c.renderOverrideForTesting = { recipe, original, hint in
                let operations = await recipe.snapshot()
                await withCheckedContinuation { release = $0 }
                return await renderer.render(recipe: EditRecipe(operations: operations), from: original, qualityHint: hint)
            }
            let rotate = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
            rotate.onAngleCommitted?(angle)
            try await until { release != nil }
            EditToolTransitionModal.responderForTesting = { _ in .keep }
            c.selectTool(.resize); await c.waitForToolTransitionForTesting()
            let logical = c.currentPixelSize
            XCTAssertNotEqual(logical, CGSize(width: 400, height: 300))
            XCTAssertEqual((c._installedToolForTesting as? ResizePanel)?.sourcePixelSize, logical)
            release?.resume(); release = nil
            await c.settleForTesting()
            XCTAssertEqual(output.map { CGSize(width: $0.width, height: $0.height) }, logical)
        }
    }

    func testActualPickerStaysOnOutgoingToolDuringDecisionAndCancel() async throws {
        let (viewer, _) = try await editingViewer(); defer { viewer.close() }
        let content = viewer.contentRootForTesting, c = content.editModeController
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
        EditToolTransitionModal.presenterForTesting = { _, completion in answer = completion }
        let picker = content.editToolbarController.toolPicker
        let segment = try XCTUnwrap(picker.segmentViewsForTesting[3] as? EditToolPicker.SegmentView)
        XCTAssertTrue(segment.accessibilityPerformPress())
        try await until { answer != nil }
        XCTAssertEqual(picker.selectedSegment, 0)
        XCTAssertEqual(c.currentTool, .crop)
        XCTAssertFalse(picker.isEnabled)
        answer?(.cancel); await c.waitForToolTransitionForTesting()
        XCTAssertEqual(picker.selectedSegment, 0); XCTAssertTrue(picker.isEnabled)
        XCTAssertNotNil(c.pendingCropRect())
    }

    func testSamePhotoAndEndWithoutDestinationDoNotPromptOrDiscardDraft() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        var asks = 0
        EditExitModal.responderForTesting = { _ in asks += 1; return .discard }
        viewer.dispatch(.firstImage)
        viewer.contentRootForTesting.onFilmstripJump?(0)
        viewer.dispatch(.prevImage)
        XCTAssertEqual(asks, 0); XCTAssertTrue(c.isActive); XCTAssertNotNil(c.pendingCropRect())
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0])
    }

    func testRemovedDestinationDoesNotRetargetItsOldIndex() async throws {
        let (viewer, urls) = try await editingViewer(); defer { viewer.close() }
        let c = viewer.contentRootForTesting.editModeController
        c.appendSnapped90(quarters: 1); await c.settleForTesting()
        var answer: (@MainActor (EditExitModal.Choice) -> Void)?
        EditExitModal.presenterForTesting = { _, completion in answer = completion }
        let before = try urls.map { try Data(contentsOf: $0) }
        viewer.dispatch(.nextImage); try await until { answer != nil }
        viewer.list.remove(primaries: [urls[1]])
        answer?(.discard); await viewer.waitForEditExit()
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[0])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, "That photo is no longer available.")
    }

    func testOldToolDecisionCannotAffectNewSession() async throws {
        let c = controller(.resize); defer { c.finalizeExit() }
        try width("200", c)
        var answer: (@MainActor (EditToolTransitionModal.Choice) -> Void)?
        EditToolTransitionModal.presenterForTesting = { _, completion in answer = completion }
        c.selectTool(.color); try await until { answer != nil }
        c.finalizeExit()
        c.enter(image: SaveFlowTests.image(width: 640, height: 480), url: nil, landOn: .rotate)
        let current = try XCTUnwrap(c.recipe)
        answer?(.keep); await c.settleForTesting()
        XCTAssertTrue(c.recipe === current); XCTAssertEqual(c.currentTool, .rotate)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 640, height: 480))
        let operations = await current.snapshot(); XCTAssertTrue(operations.isEmpty)
    }

    func testNativeToolAlertHasExplicitKeyboardRolesAndScope() {
        let content = EditToolTransitionModal.Content(outgoing: .crop, destination: .color)
        let alert = EditToolTransitionModal.makeAlert(content)
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep Changes", "Cancel", "Discard Changes"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}", "d"])
        XCTAssertEqual(alert.buttons[2].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(content.message, "Keep pending Crop changes before switching to Color?")
        XCTAssertTrue(content.information.contains("removes only the pending Crop changes"))
        XCTAssertTrue(content.information.contains("Applied changes and earlier edits stay"))
        XCTAssertFalse(content.information.contains("since you opened"))
        let preview = EditToolTransitionModal.Content(outgoing: .levels, destination: .crop)
        XCTAssertTrue(preview.information.contains("since you opened Levels"), "Live-preview scope remains a whole visit")
    }
}
