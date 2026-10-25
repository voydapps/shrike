import AppKit
import ImageIO
import XCTest
@testable import ShrikeUI
@testable import ShrikeEdit
import ShrikeCore
import ShrikeIO

@MainActor
final class FineRotationWorkflowTests: XCTestCase {
    private var root: URL!
    private var savedAutoCrop = false
    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-fine-rotate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedAutoCrop = Prefs.editAutoCropOnFreeRotate
    }
    override func tearDown() async throws {
        Prefs.editAutoCropOnFreeRotate = savedAutoCrop
        EditToolTransitionModal.responderForTesting = nil
        EditExitModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func controller(autoCrop: Bool) async throws -> (EditModeController, RotatePanel, CGImage, URL) {
        Prefs.editAutoCropOnFreeRotate = autoCrop
        let image = SaveFlowTests.image(width: 2400, height: 1600)
        let url = root.appendingPathComponent("input-\(UUID()).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let controller = EditModeController()
        controller.enter(image: image, url: url, landOn: .rotate)
        await controller.settleForTesting()
        return (controller, try XCTUnwrap(controller._installedToolForTesting as? RotatePanel), image, url)
    }
    private func move(_ degrees: Double, panel: RotatePanel) {
        panel._angleSlider.doubleValue = degrees
        XCTAssertTrue(panel._angleSlider.sendAction(panel._angleSlider.action, to: panel._angleSlider.target))
    }
    private func finishIdle(_ panel: RotatePanel, _ controller: EditModeController) async {
        await panel.pendingCommitForTesting?.value
        await controller.settleForTesting()
    }
    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[(y * image.width + x) * 4 + 3]
    }

    func testRealSliderHeldIdleCommitAfterControllerExpiryRefinesOneStep() async throws {
        let (controller, panel, _, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        let originalCommit = try XCTUnwrap(panel.onAngleCommitted)
        var held: Double?
        panel.onAngleCommitted = { held = $0 }
        move(12.5, panel: panel)
        // Hold the actual panel callback until the actual controller expiry.
        // No arbitrary sleep or second synthetic slider input determines order.
        await controller.coalesceIdleForTesting?.value
        await panel.pendingCommitForTesting?.value
        XCTAssertEqual(held, 12.5)
        originalCommit(try XCTUnwrap(held))
        await controller.settleForTesting()
        let session = try XCTUnwrap(controller.recipe)
        let operations = await session.snapshot()
        XCTAssertEqual(operations.count, 1, "full idle commitment refines its existing preview step")
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083))
        controller.performUndo(); await controller.settleForTesting()
        let undone = await session.snapshot()
        XCTAssertTrue(undone.isEmpty)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2400, height: 1600))
        controller.performRedo(); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083))
        panel._resetButton.performClick(nil); await controller.settleForTesting()
        let reset = await session.snapshot()
        XCTAssertTrue(reset.isEmpty, "Reset must not reveal a duplicate preceding angle")
        XCTAssertEqual(panel.angle, 0)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2400, height: 1600))
    }

    func testAutoCropFrozenRecipePreviewFullExportAndLegacyReplayAgree() async throws {
        for autoCrop in [false, true] {
            let (controller, panel, image, url) = try await controller(autoCrop: autoCrop)
            defer { controller.finalizeExit() }
            let original = try Data(contentsOf: url)
            move(12.5, panel: panel); await finishIdle(panel, controller)
            let session = try XCTUnwrap(controller.recipe), operations = await session.snapshot()
            XCTAssertEqual(operations.count, 1)
            let expected = autoCrop ? CGSize(width: 2203, height: 1150) : CGSize(width: 2690, height: 2083)
            XCTAssertEqual(controller.currentPixelSize, expected)
            XCTAssertEqual(EditRenderer.outputPixelSize(from: CGSize(width: 2400, height: 1600), operations: operations), expected)
            let encoded = try JSONEncoder().encode(operations)
            let decoded = try JSONDecoder().decode([EditOperation].self, from: encoded)
            XCTAssertEqual(decoded, operations)
            // Changing the preference cannot reinterpret a frozen operation.
            Prefs.editAutoCropOnFreeRotate = !autoCrop
            let replay = EditRecipe(operations: decoded)
            let renderer = EditRenderer(draftLongEdge: 4096)
            for quality in [RenderQualityHint.draft, .full] {
                let result = await renderer.render(recipe: replay, from: image, qualityHint: quality)
                let rendered = try XCTUnwrap(result)
                XCTAssertEqual(CGSize(width: rendered.width, height: rendered.height), expected)
                let inset = autoCrop ? 3 : 0
                let samples = [(inset, inset), (rendered.width - 1 - inset, inset),
                               (inset, rendered.height - 1 - inset), (rendered.width - 1 - inset, rendered.height - 1 - inset)]
                for (x, y) in samples {
                    let value = try alpha(rendered, x: x, y: y)
                    if autoCrop { XCTAssertGreaterThan(value, 0, "cropped corners remain inside the source") }
                    else { XCTAssertEqual(value, 0, "expanded rotation preserves transparent corners") }
                }
            }
            let output = root.appendingPathComponent("output-\(autoCrop).png")
            let exporter = ImageExporter(backupStore: BackupStore(root: root.appendingPathComponent("backups")))
            try await exporter.export(recipe: replay, from: url, to: output, format: .png, quality: 1)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(CGSize(width: saved.width, height: saved.height), expected)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        let legacy = try JSONDecoder().decode([EditOperation].self, from: Data("[{\"rotate\":{\"degrees\":12.5}}]".utf8))
        XCTAssertEqual(legacy, [.rotate(degrees: 12.5)])
        XCTAssertEqual(EditRenderer.outputPixelSize(from: CGSize(width: 2400, height: 1600), operations: legacy),
                       CGSize(width: 2690, height: 2083), "legacy degrees-only recipes retain expanded semantics")
    }

    func testToggleUpdatesOnlyOwnedFineRotationAndUndoRedoRestoresItsSetting() async throws {
        let (controller, panel, _, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        let session = try XCTUnwrap(controller.recipe), initial = await session.checkpoint()
        panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        let preferenceOnly = await session.checkpoint()
        XCTAssertEqual(preferenceOnly, initial, "identity checkbox changes only the future default")
        panel._autoCropCheckbox.performClick(nil)
        move(12.5, panel: panel); await finishIdle(panel, controller)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083))
        panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        let active = await session.snapshot()
        XCTAssertEqual(active.count, 1, "crop choice belongs to the one owned rotation operation")
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2203, height: 1150))
        controller.performUndo(); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083), "Undo the separate checkbox action")
        XCTAssertEqual(panel._autoCropCheckbox.state, .off)
        controller.performUndo(); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2400, height: 1600))
        controller.performRedo(); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083))
        controller.performRedo(); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2203, height: 1150))
        XCTAssertEqual(panel._autoCropCheckbox.state, .on)
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        controller.selectTool(.color); await controller.settleForTesting()
        controller.selectTool(.rotate); await controller.settleForTesting()
        let next = try XCTUnwrap(controller._installedToolForTesting as? RotatePanel)
        XCTAssertEqual(next.angle, 0, "a new visit shows its new segment baseline, not accepted history")
        next._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        let kept = await session.snapshot()
        XCTAssertEqual(kept, active, "a new tool visit's preference cannot reinterpret accepted history")
        move(5, panel: next); await finishIdle(next, controller)
        let later = await session.snapshot()
        XCTAssertEqual(later.count, 2, "a separate accepted interval remains a separate geometry step")
        controller.performUndo(); await controller.settleForTesting()
        let previous = await session.snapshot()
        XCTAssertEqual(previous, active)
    }

    func testRotationToggleKeepDiscardCancelPreservesExactToolCheckpoint() async throws {
        for choice in [EditToolTransitionModal.Choice.keep, .discard, .cancel] {
            let (controller, panel, _, _) = try await controller(autoCrop: false)
            defer { controller.finalizeExit() }
            let session = try XCTUnwrap(controller.recipe), entry = await session.checkpoint()
            move(12.5, panel: panel); await finishIdle(panel, controller)
            panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
            let changed = await session.checkpoint()
            var asks = 0
            EditToolTransitionModal.responderForTesting = { _ in asks += 1; return choice }
            controller.selectTool(.color); await controller.settleForTesting()
            XCTAssertEqual(asks, 1)
            let result = await session.checkpoint()
            XCTAssertEqual(result, choice == .discard ? entry : changed)
            XCTAssertEqual(controller.currentTool, choice == .cancel ? .rotate : .color)
            XCTAssertEqual(controller.currentPixelSize, choice == .discard ? CGSize(width: 2400, height: 1600) : CGSize(width: 2203, height: 1150))
        }
    }
    func testCancelledToolAndPhotoDepartureRetainCurrentRotationOwnership() async throws {
        let (controller, panel, _, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        controller.hostWindow = window
        let session = try XCTUnwrap(controller.recipe)
        move(12.5, panel: panel); await finishIdle(panel, controller)
        let before = await session.checkpoint()
        EditToolTransitionModal.responderForTesting = { _ in .cancel }
        controller.selectTool(.color); await controller.settleForTesting()
        let afterToolCancel = await session.checkpoint()
        XCTAssertEqual(afterToolCancel, before)
        panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2203, height: 1150))
        let cropped = await session.checkpoint()
        var departures = 0
        EditExitModal.responderForTesting = { _ in departures += 1; return .cancel }
        controller.attemptExit(reason: .navigation)
        let deadline = Date().addingTimeInterval(3)
        while (departures == 0 || controller.isTransitioning), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(departures, 1)
        XCTAssertFalse(controller.isTransitioning)
        await controller.settleForTesting()
        XCTAssertTrue(controller.isActive)
        let afterPhotoCancel = await session.checkpoint()
        XCTAssertEqual(afterPhotoCancel, cropped)
        panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        let operations = await session.snapshot()
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083))
    }

    func testQueuedAutoCropTogglePrecedesImmediateToolKeep() async throws {
        let (controller, panel, _, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        move(12.5, panel: panel); await finishIdle(panel, controller)
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        panel._autoCropCheckbox.performClick(nil)
        controller.selectTool(.color)
        await controller.settleForTesting()
        let operations = await controller.recipe?.snapshot()
        XCTAssertEqual(operations?.count, 1)
        XCTAssertEqual(controller.currentTool, .color)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2203, height: 1150),
                       "the admitted checkbox write precedes the transition boundary")
    }

    func testSamePanelPausedGesturesRefineAbsoluteAngleAndKeepUndoOwnership() async throws {
        for autoCrop in [false, true] {
            let (controller, panel, baseline, url) = try await controller(autoCrop: autoCrop)
            defer { controller.finalizeExit() }
            var presented: CGImage?
            controller.onPresentImage = { presented = $0 }
            let session = try XCTUnwrap(controller.recipe)
            move(12.5, panel: panel); await finishIdle(panel, controller)
            let first = await session.snapshot()
            move(13, panel: panel); await finishIdle(panel, controller)
            let expected = RotateTool.apply(degrees: 13, to: baseline, autocrop: autoCrop)
            let current = await session.snapshot()
            XCTAssertEqual(current.count, 1, "one current segment transform, with parameter history kept separately")
            XCTAssertEqual(controller.operationCount, 2, "both completed gestures are available to Undo")
            XCTAssertTrue(controller.chromeState.canUndo)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: expected.width, height: expected.height))
            let shown = try XCTUnwrap(presented)
            XCTAssertEqual(shown.width, expected.width)
            XCTAssertEqual(shown.height, expected.height)
            let expectedBytes = try XCTUnwrap(expected.dataProvider?.data) as Data
            let shownBytes = try XCTUnwrap(shown.dataProvider?.data) as Data
            XCTAssertFalse(expectedBytes.isEmpty)
            XCTAssertEqual(shownBytes, expectedBytes,
                           "13 degrees is rendered once from the unchanged segment baseline")
            XCTAssertEqual(panel.angle, 13)
            let replay = await EditRenderer().renderFinal(recipe: EditRecipe(operations: current), from: baseline)
            let replayBytes = try XCTUnwrap(replay.dataProvider?.data) as Data
            XCTAssertEqual(replayBytes, expectedBytes)
            let output = root.appendingPathComponent("same-panel-13-\(autoCrop).png")
            try await ImageExporter(backupStore: nil).export(recipe: EditRecipe(operations: current),
                                                             from: url, to: output, format: .png)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(exported.width, expected.width)
            XCTAssertEqual(exported.height, expected.height)
            controller.performUndo(); await controller.settleForTesting()
            let undone = await session.snapshot()
            XCTAssertEqual(undone, first)
            XCTAssertEqual(panel.angle, 12.5)
            XCTAssertEqual(controller.operationCount, 1)
            XCTAssertEqual(controller.undoneCount, 1)
            controller.performRedo(); await controller.settleForTesting()
            XCTAssertEqual(panel.angle, 13)
            let redone = await session.snapshot()
            XCTAssertEqual(redone, current)
            panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
            let toggled = RotateTool.apply(degrees: 13, to: baseline, autocrop: !autoCrop)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: toggled.width, height: toggled.height),
                           "Redo restores editable segment ownership for the next checkbox action")
            controller.performUndo(); await controller.settleForTesting()
            let beforeToggle = await session.snapshot()
            XCTAssertEqual(beforeToggle, current, "a separate checkbox action has its own Undo boundary")
            controller.performRedo(); await controller.settleForTesting()
            move(0, panel: panel); await finishIdle(panel, controller)
            XCTAssertEqual(panel.angle, 0)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: baseline.width, height: baseline.height))
            let zero = await session.snapshot()
            XCTAssertTrue(zero.isEmpty)
            XCTAssertTrue(controller.chromeState.canUndo, "identity removal still has an Undo action")
            XCTAssertEqual(controller.operationCount, 4)
            controller.performUndo(); await controller.settleForTesting()
            XCTAssertEqual(panel.angle, 13)
            panel._resetButton.performClick(nil); await controller.settleForTesting()
            let reset = await session.snapshot()
            XCTAssertTrue(reset.isEmpty)
            XCTAssertEqual(panel.angle, 0)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: baseline.width, height: baseline.height))
        }
    }

    func testQuickQuarterTurnEndsFineSegmentAndUndoRestoresOnlyCurrentVisitOwnership() async throws {
        let (controller, panel, baseline, _) = try await controller(autoCrop: true)
        defer { controller.finalizeExit() }
        let session = try XCTUnwrap(controller.recipe)
        move(12.5, panel: panel); await finishIdle(panel, controller)
        let fine = await session.snapshot()
        panel._quickCW.performClick(nil); await controller.settleForTesting()
        let turned = await session.snapshot()
        XCTAssertEqual(turned.count, 2)
        XCTAssertEqual(panel.angle, 0)
        controller.performUndo(); await controller.settleForTesting()
        let undone = await session.snapshot()
        XCTAssertEqual(undone, fine)
        XCTAssertEqual(panel.angle, 12.5)
        panel._autoCropCheckbox.performClick(nil); await controller.settleForTesting()
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 2690, height: 2083),
                       "Undo quarter-turn restores the same visit's editable segment")
        controller.performUndo(); await controller.settleForTesting()
        controller.performRedo(); await controller.settleForTesting()
        panel._quickCW.performClick(nil); await controller.settleForTesting()
        XCTAssertEqual(panel.angle, 0)
        move(5, panel: panel); await finishIdle(panel, controller)
        let direct = RotateTool.apply(degrees: 5,
            to: RotateTool.apply90(quarters: 1, to: RotateTool.apply(degrees: 12.5, to: baseline, autocrop: false)),
            autocrop: false)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: direct.width, height: direct.height))
        let later = await session.snapshot()
        XCTAssertEqual(later.count, 3, "quarter-turn is an explicit ordered geometry boundary")
        panel._resetButton.performClick(nil); await controller.settleForTesting()
        let reset = await session.snapshot()
        XCTAssertEqual(Array(later.dropLast()), reset)
        controller.performUndo(); await controller.settleForTesting()
        let undoReset = await session.snapshot()
        XCTAssertEqual(undoReset, later)
        XCTAssertEqual(panel.angle, 5)
        controller.performRedo(); await controller.settleForTesting()
        let redoReset = await session.snapshot()
        XCTAssertEqual(redoReset, reset)
        XCTAssertEqual(panel.angle, 0)
    }

    func testContinuousReturnToZeroPreservesAcceptedHistoryNameAndDepth() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<32 {
            let value = 0.2 + Double(x) * 0.5 / 31
            context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 8))
        }
        let controller = EditModeController()
        defer { controller.finalizeExit() }
        controller.enter(image: try XCTUnwrap(context.makeImage()), url: nil, landOn: .levels)
        controller.applyLevelsAuto(.contrast); await controller.settleForTesting()
        XCTAssertEqual(controller.undoMenuTitle, "Undo Auto Contrast")
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        controller.selectTool(.rotate); await controller.settleForTesting()
        let panel = try XCTUnwrap(controller._installedToolForTesting as? RotatePanel)
        let before = await controller.recipe?.snapshot()
        move(10, panel: panel); move(0, panel: panel)
        await finishIdle(panel, controller)
        let after = await controller.recipe?.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(controller.operationCount, 1)
        XCTAssertEqual(controller.undoMenuTitle, "Undo Auto Contrast", "a cancelled rotation gesture cannot rename the accepted prefix")
        panel._resetButton.performClick(nil); await controller.settleForTesting()
        XCTAssertEqual(controller.undoMenuTitle, "Undo Auto Contrast", "Reset at identity is not a history action")
        controller.performUndo(); await controller.settleForTesting()
        let empty = await controller.recipe?.snapshot()
        XCTAssertEqual(empty, [])
        XCTAssertEqual(controller.redoMenuTitle, "Redo Auto Contrast")
    }

    func testImmediateQueuedUndoThenSliderResolvesEntryAndPriorSegmentOwnership() async throws {
        for undoToPrior in [false, true] {
            let (controller, panel, baseline, _) = try await controller(autoCrop: undoToPrior)
            defer { controller.finalizeExit() }
            var presented: CGImage?
            controller.onPresentImage = { presented = $0 }
            let session = try XCTUnwrap(controller.recipe)
            move(12.5, panel: panel); await finishIdle(panel, controller)
            let first = await session.snapshot()
            if undoToPrior { move(13, panel: panel); await finishIdle(panel, controller) }
            // Real control input is admitted before the queued Undo can run.
            controller.performUndo()
            move(14, panel: panel)
            await finishIdle(panel, controller)
            let current = await session.snapshot()
            let expected = RotateTool.apply(degrees: 14, to: baseline, autocrop: undoToPrior)
            XCTAssertEqual(current.count, 1)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: expected.width, height: expected.height))
            let shown = try XCTUnwrap(presented), shownBytes = try XCTUnwrap(shown.dataProvider?.data) as Data
            let expectedBytes = try XCTUnwrap(expected.dataProvider?.data) as Data
            XCTAssertFalse(expectedBytes.isEmpty)
            XCTAssertEqual(shownBytes, expectedBytes, "queued refinement is a single absolute14 from the segment baseline")
            XCTAssertEqual(panel.angle, 14)
            XCTAssertEqual(controller.operationCount, undoToPrior ? 2 : 1)
            XCTAssertEqual(controller.undoneCount, 0, "the new angle forks the old13 or12.5 future")
            controller.performUndo(); await controller.settleForTesting()
            let undone = await session.snapshot()
            XCTAssertEqual(undone, undoToPrior ? first : [])
            XCTAssertEqual(panel.angle, undoToPrior ? 12.5 : 0)
            controller.performRedo(); await controller.settleForTesting()
            let redone = await session.snapshot()
            XCTAssertEqual(redone, current)
            XCTAssertEqual(panel.angle, 14)
            controller.performRedo(); await controller.settleForTesting()
            let noOldFuture = await session.snapshot()
            XCTAssertEqual(noOldFuture, current, "discarded13 must not return after the14 fork")
            XCTAssertEqual(controller.undoneCount, 0)
        }
    }

    func testImmediateQueuedRedoThenSliderAndCheckboxUseRestoredSegment() async throws {
        for refineAngle in [false, true] {
            let (controller, panel, baseline, _) = try await controller(autoCrop: true)
            defer { controller.finalizeExit() }
            let session = try XCTUnwrap(controller.recipe)
            move(12.5, panel: panel); await finishIdle(panel, controller)
            if refineAngle { move(13, panel: panel); await finishIdle(panel, controller) }
            controller.performUndo(); await controller.settleForTesting()
            // Entry case has no live owner; the other case restores12.5.
            controller.performRedo()
            if refineAngle { move(14, panel: panel) }
            panel._autoCropCheckbox.performClick(nil)
            await controller.settleForTesting()
            let angle = refineAngle ? 14.0 : 12.5
            let expected = RotateTool.apply(degrees: angle, to: baseline, autocrop: false)
            let current = await session.snapshot()
            XCTAssertEqual(current.count, 1)
            XCTAssertEqual(controller.currentPixelSize, CGSize(width: expected.width, height: expected.height))
            XCTAssertEqual(panel.angle, angle)
            XCTAssertEqual(panel._autoCropCheckbox.state, .off)
            XCTAssertEqual(controller.operationCount, refineAngle ? 4 : 2)
            XCTAssertEqual(controller.undoneCount, 0)
            controller.performUndo(); await controller.settleForTesting()
            XCTAssertEqual(panel.angle, angle)
            XCTAssertEqual(panel._autoCropCheckbox.state, .on, "Undo restores the captured checkbox action independently")
            if refineAngle {
                controller.performUndo(); await controller.settleForTesting()
                XCTAssertEqual(panel.angle, 13, "Undo refinement returns the actual Redo state, not an appended transform")
                controller.performRedo(); await controller.settleForTesting()
            }
            controller.performRedo(); await controller.settleForTesting()
            let redone = await session.snapshot()
            XCTAssertEqual(redone, current)
            XCTAssertEqual(panel._autoCropCheckbox.state, .off)
        }
    }

    private func assertContentPresentation(_ controller: EditModeController, edited: Bool,
                                           resetEnabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let state = controller.chromeState
        XCTAssertEqual(state.hasEdits, edited, file: file, line: line)
        XCTAssertEqual(state.primaryTitle, edited ? "Save Changes" : "Done", file: file, line: line)
        XCTAssertEqual(state.subtitle, edited ? "Editing · Unsaved changes" : "Editing", file: file, line: line)
        let toolbar = EditToolbarController(), capsule = EditCapsuleView()
        toolbar.apply(state); capsule.apply(state)
        XCTAssertEqual(toolbar.doneButton.accessibilityLabel(), state.primaryTitle, file: file, line: line)
        XCTAssertEqual(capsule.doneButton.accessibilityLabel(), state.primaryTitle, file: file, line: line)
        XCTAssertEqual(capsule.label.stringValue, state.subtitle, file: file, line: line)
        XCTAssertFalse(toolbar.saveCopyButton.isHidden, file: file, line: line)
        XCTAssertFalse(capsule.saveCopyButton.isHidden, file: file, line: line)
        XCTAssertEqual(toolbar.saveCopyButton.isEnabled, edited, file: file, line: line)
        XCTAssertEqual(capsule.saveCopyButton.isEnabled, edited, file: file, line: line)
        XCTAssertEqual(toolbar.resetButton.isEnabled, resetEnabled, file: file, line: line)
        XCTAssertEqual(capsule.resetButton.isEnabled, resetEnabled, file: file, line: line)
        let reset = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.reset,
                                    willBeInsertedIntoToolbar: true)
        XCTAssertEqual(reset?.menuFormRepresentation?.isEnabled, resetEnabled, file: file, line: line)
    }

    func testResetToIdentityUsesContentCaptionWhilePreservingUndoAndResetAll() async throws {
        let (controller, panel, baseline, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        let session = try XCTUnwrap(controller.recipe), initial = await session.checkpoint()
        move(12.5, panel: panel); await finishIdle(panel, controller)
        move(13, panel: panel); await finishIdle(panel, controller)
        panel._resetButton.performClick(nil); await controller.settleForTesting()
        let reset = await session.snapshot(), changed = await session.hasContentChanges(since: initial)
        XCTAssertTrue(reset.isEmpty); XCTAssertFalse(changed)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: baseline.width, height: baseline.height))
        XCTAssertEqual(panel.angle, 0)
        XCTAssertTrue(controller.chromeState.canUndo)
        XCTAssertEqual(controller.operationCount, 3)
        let resetHistory = await session.checkpoint()
        assertContentPresentation(controller, edited: false, resetEnabled: true)

        controller.performUndo(); await controller.settleForTesting()
        XCTAssertEqual(panel.angle, 13)
        XCTAssertEqual(controller.operationCount, 2); XCTAssertEqual(controller.undoneCount, 1)
        assertContentPresentation(controller, edited: true, resetEnabled: true)
        controller.performRedo(); await controller.settleForTesting()
        let restored = await session.checkpoint()
        XCTAssertEqual(restored, resetHistory, "caption assessment cannot rewrite history or its editable owner")
        assertContentPresentation(controller, edited: false, resetEnabled: true)

        controller.performUndo(); controller.performUndo(); controller.performUndo()
        await controller.settleForTesting()
        XCTAssertFalse(controller.chromeState.canUndo); XCTAssertTrue(controller.chromeState.canRedo)
        assertContentPresentation(controller, edited: false, resetEnabled: false)
        controller.performRedo(); controller.performRedo(); controller.performRedo()
        await controller.settleForTesting()
        assertContentPresentation(controller, edited: false, resetEnabled: true)
        // Reset All still clears the retained history even when no current transform remains.
        let toolbar = EditToolbarController()
        toolbar.onAction = { controller.perform($0) }
        toolbar.apply(controller.chromeState); toolbar.resetButton.performClick(nil)
        await controller.settleForTesting()
        XCTAssertFalse(controller.chromeState.canUndo); XCTAssertFalse(controller.chromeState.canRedo)
        assertContentPresentation(controller, edited: false, resetEnabled: false)
    }

    func testResetRotationKeepsAcceptedCropUnsaved() async throws {
        let (controller, _, _, _) = try await controller(autoCrop: false)
        defer { controller.finalizeExit() }
        let session = try XCTUnwrap(controller.recipe), initial = await session.checkpoint()
        controller.selectTool(.crop); await controller.settleForTesting()
        controller.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 2400, height: 1600)
        controller.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let crop = try XCTUnwrap(controller._installedToolForTesting as? CropPanel)
        crop._applyButton.performClick(nil); await controller.settleForTesting()
        let accepted = await session.snapshot()
        XCTAssertEqual(accepted.count, 1)
        guard case .crop? = accepted.first else { return XCTFail("The real Crop Apply must be the accepted prefix") }
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        controller.selectTool(.rotate); await controller.settleForTesting()
        let panel = try XCTUnwrap(controller._installedToolForTesting as? RotatePanel)
        move(13, panel: panel); await finishIdle(panel, controller)
        panel._resetButton.performClick(nil); await controller.settleForTesting()
        let reset = await session.snapshot(), changed = await session.hasContentChanges(since: initial)
        XCTAssertEqual(reset, accepted); XCTAssertTrue(changed)
        XCTAssertEqual(controller.currentPixelSize, CGSize(width: 1200, height: 800))
        assertContentPresentation(controller, edited: true, resetEnabled: true)
    }

    private actor ExportCounter {
        private(set) var calls = 0
        func record() { calls += 1 }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    func testResetIdentityViewerDoneAndDirectSaveExitWithoutExportOrBackup() async throws {
        Prefs.editAutoCropOnFreeRotate = false
        for directSave in [false, true] {
            let url = root.appendingPathComponent("reset-exit-\(directSave).png")
            let original = try SaveFlowTests.writeImage(url, type: .png)
            let store = BackupStore(root: root.appendingPathComponent("backups-\(directSave)"))
            var services = ShrikeServices.makeDefault(); services.backupStore = store
            let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
            defer { viewer.close() }
            let ready = await until { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
            XCTAssertTrue(ready)
            guard ready else { return }
            let counter = ExportCounter()
            viewer.exportCheckpointForTesting = { _ in await counter.record() }
            let content = viewer.contentRootForTesting
            content.enterEditMode(image: SaveFlowTests.image(), url: url, landOn: .rotate)
            let controller = content.editModeController
            await controller.settleForTesting()
            let panel = try XCTUnwrap(controller._installedToolForTesting as? RotatePanel)
            move(13, panel: panel); await finishIdle(panel, controller)
            panel._resetButton.performClick(nil); await controller.settleForTesting()
            XCTAssertEqual(content.editToolbarController.doneButton.accessibilityLabel(), "Done")
            XCTAssertEqual(viewer.subtitle, "Editing"); XCTAssertFalse(viewer.isDocumentEdited)
            XCTAssertFalse(content.editToolbarController.saveCopyButton.isEnabled)
            if directSave {
                let saved = await viewer.saveEditedFile(asPanel: false)
                XCTAssertTrue(saved)
            } else {
                content.editToolbarController.doneButton.performClick(nil)
            }
            let exited = await until { !controller.isActive }
            XCTAssertTrue(exited)
            let exports = await counter.calls, records = await store.records(for: url)
            XCTAssertEqual(exports, 0)
            XCTAssertTrue(records.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertNil(viewer.attachedSheet)
        }
    }

}
