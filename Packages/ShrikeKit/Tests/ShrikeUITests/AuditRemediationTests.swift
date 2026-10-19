import AppKit
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class AuditRemediationTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-remediation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Prefs.resetAll(); CompareWindow.presentsWindows = false
    }
    override func tearDown() async throws {
        ContactSheetSheet.previewRendererForTesting = nil
        CullingUndo.beforeWriteForTesting = nil
        await CullingUndo.waitForPendingWrites()
        CompareWindow.current?.close(); CompareWindow.presentsWindows = true
        Prefs.resetAll(); try? FileManager.default.removeItem(at: root)
    }
    private func services() throws -> ShrikeServices {
        ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("meta.sqlite"), writeFileAttributes: { false }))
    }
    private func photos(_ count: Int) throws -> [ImageGroup] {
        try (0..<count).map { i in
            let url = root.appendingPathComponent("photo\(i).png")
            let out = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(out, SaveFlowTests.image(), nil)
            XCTAssertTrue(CGImageDestinationFinalize(out)); return ImageGroup(primary: url)
        }
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected asynchronous workflow did not settle")
    }
    func testFilterRemovalPreservesEveryOtherPredicateAndSearch() {
        var value = BrowserFilter(minimumRating: 4, flaggedOnly: true, formats: [.jpeg],
            modifiedFrom: Date(timeIntervalSince1970: 1), searchTerm: "Italy", tags: ["Red"])
        value.excludedKinds = [.raw]
        XCTAssertEqual(value.conditions.count, 7)
        let removed = value.removing(.rating)
        XCTAssertEqual(removed.minimumRating, 0); XCTAssertTrue(removed.flaggedOnly)
        XCTAssertEqual(removed.searchTerm, "Italy"); XCTAssertEqual(removed.excludedKinds, [.raw])
        XCTAssertEqual(removed.tags, ["Red"]); XCTAssertEqual(removed.formats, [.jpeg])
        XCTAssertEqual(value.removing(.search).minimumRating, 4)
        XCTAssertEqual(value.removing(.kinds).excludedKinds, [])
    }
    func testKnownCurrentFolderSelectionDoesNotListItsAncestors() async throws {
        let tree = FolderTreeDataSource()
        let target = root.appendingPathComponent("deep/path/photos")
        var walked: [URL] = []; tree.didListFolder = { walked.append($0) }
        tree.setCurrentFolder(target)
        let node = await tree.node(for: target)
        XCTAssertEqual(node?.url, target); XCTAssertTrue(walked.isEmpty)
        XCTAssertEqual(tree.roots.first?.section, .currentFolder)
        tree.rebuildRoots(favorites: [.init(url: target, isMissing: false)], volumes: [])
        XCTAssertNil(tree.roots.first { $0.section == .currentFolder })
        let favorite = await tree.node(for: target)
        XCTAssertEqual(favorite?.kind, .favorite)
    }
    func testLargeChromeChangesOpenTextAndResetOwnsMovedControls() {
        let label = NSTextField(labelWithString: "Action text"); label.font = ChromeTypography.font(12)
        let root = NSView(); root.addSubview(label)
        let observation = ChromeTextObservation(root: root)
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        XCTAssertEqual(label.font?.pointSize, 14)
        Prefs.viewerToolbarAutoHide = false; Prefs.reviewControlsVisible = true; Prefs.advanceAfterRating = true
        Prefs.maxDisplayLongEdge = 8192
        PreferencesTab.general.resetToDefaults()
        XCTAssertFalse(Prefs.largerChrome); XCTAssertFalse(Prefs.reviewControlsVisible); XCTAssertFalse(Prefs.advanceAfterRating)
        XCTAssertEqual(label.font?.pointSize, 12); XCTAssertEqual(Prefs.maxDisplayLongEdge, 8192)
        PreferencesTab.advanced.resetToDefaults(); XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        Prefs.selectedPreferencesTabRaw = "performance"; XCTAssertEqual(PreferencesTab.loadSelected(), .advanced)
        withExtendedLifetime(observation) {}
    }
    func testCompareReferenceSurvivesCandidateNavigationAndIsIndependentOfSync() async throws {
        let groups = try photos(5)
        let request = try XCTUnwrap(CompareSources.fromBrowser(list: groups, selected: [0, 1]))
        let window = CompareWindow.open(request, services: try services(), origin: nil, frame: nil)
        defer { window.close() }
        let reference = window.panes[0]
        window.toggleReference(reference); window.setLocked(false)
        window.step(1, allPanes: true)
        XCTAssertEqual(reference.index, 0); XCTAssertEqual(window.panes[1].index, 2)
        window.focus(0); window.step(1, allPanes: false)
        XCTAssertEqual(reference.index, 0); XCTAssertFalse(window.isLocked)
        window.toggleReference(window.panes[1]); XCTAssertTrue(window.referencePane === window.panes[1])
        window.step(1, allPanes: true)
        XCTAssertEqual(reference.index, 1); XCTAssertEqual(window.panes[1].index, 2)
    }
    func testRatingAdvancesOnceAfterCommitUndoReturnsAndRedoDoesNotNavigate() async throws {
        let groups = try photos(3); let services = try services()
        Prefs.reviewControlsVisible = true; Prefs.advanceAfterRating = true
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
        defer { viewer.close() }
        try await settle { viewer.displayedItem?.listIndex == 0 }
        viewer.windowUndoManager.groupsByEvent = false; viewer.windowUndoManager.beginUndoGrouping()
        viewer.rateDisplayed(4); viewer.windowUndoManager.endUndoGrouping()
        await CullingUndo.waitForPendingWrites()
        try await settle { viewer.displayedItem?.listIndex == 1 }
        viewer.windowUndoManager.undo(); await CullingUndo.waitForPendingWrites()
        try await settle { viewer.displayedItem?.listIndex == 0 }
        viewer.windowUndoManager.redo(); await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)
        let committedRating = try await services.metadataStore.rating(for: groups[0].primary)
        XCTAssertEqual(committedRating, 4)
    }
    func testRatingFailureAndNoOpDoNotAdvance() async throws {
        let groups = try photos(2); let services = try services()
        Prefs.reviewControlsVisible = true; Prefs.advanceAfterRating = true
        try await services.metadataStore.setRating(3, for: groups[0].primary)
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
        defer { viewer.close() }
        try await settle { viewer.displayedItem?.listIndex == 0 }
        viewer.rateDisplayed(3); await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)
        CullingUndo.beforeWriteForTesting = { throw CocoaError(.fileWriteNoPermission) }
        viewer.rateDisplayed(5); await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)
    }
    func testViewRetainsCPUAccountingAfterCallerLeaseDropsAndCloseReleases() {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 1 << 20))
        let owner = ImageResourceOwner(); let image = SaveFlowTests.image()
        let view = MetalImageView(frame: .zero); view.resources = budget; view.resourceOwner = owner
        var lease: ImageResourceLease? = budget.retain(image: image, owner: owner, category: .displayCache)
        view.setImage(image, sourceID: "photo", prepared: nil, resourceLease: lease)
        lease = nil
        XCTAssertGreaterThan(budget.snapshot().uniqueRetainedBytes, 0)
        view.releaseResources()
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
    }
    /// Drain the same common-mode queue used by the production redraw coalescer.
    private func finishQueuedRedraws() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let loop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { continuation.resume() }
            CFRunLoopWakeUp(loop)
        }
    }

    func testReleasedDrawableStaysReleasedThroughLateGeometryAndQueuedRedraw() async {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Queue an ordinary empty-canvas clear BEFORE close. It must not acquire
        // another drawable when that already-enqueued block eventually runs.
        view.needsDisplay = true
        let framesBeforeRelease = view.framesDrawnForTesting
        view.releaseResources()
        await finishQueuedRedraws()
        XCTAssertEqual(view.framesDrawnForTesting, framesBeforeRelease,
                       "A redraw queued before release must not request a GPU frame after release")
        XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1))

        for size in [CGSize(width: 2560, height: 1440), CGSize(width: 1000, height: 700)] {
            view.setFrameSize(size)
            XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1),
                           "A late frame callback must not restore a released drawable")
            view.layout()
            XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1),
                           "A late layout callback must not restore a released drawable")
            view.viewDidChangeBackingProperties()
            XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1),
                           "A late backing callback must not restore a released drawable")
            view.needsDisplay = true
            await finishQueuedRedraws()
            XCTAssertEqual(view.framesDrawnForTesting, framesBeforeRelease,
                           "Released geometry and invalidation must not request GPU frames")
        }
        view.releaseResources()
        await finishQueuedRedraws()
        XCTAssertEqual(view.framesDrawnForTesting, framesBeforeRelease,
                       "Repeated release must remain quiescent")
        XCTAssertFalse(view.hasTextureForTesting)
    }

    func testOnlyPhotoAssignmentReactivatesReleasedDrawableAndInitialEmptyCanvasStillClears() async {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { view.releaseResources() }
        view.layout() // The initial AppKit layout establishes the drawable size.
        let initialFrames = view.framesDrawnForTesting
        view.needsDisplay = true
        await finishQueuedRedraws()
        XCTAssertGreaterThan(view.framesDrawnForTesting, initialFrames,
                             "An initial empty canvas must still draw its clear frame")
        for cycle in 0..<2 {
            view.releaseResources()
            view.image = nil
            await finishQueuedRedraws()
            XCTAssertEqual(view.drawableSizeForTesting, CGSize(width: 1, height: 1),
                           "Assigning nil must not reactivate a released drawable")
            let closedFrames = view.framesDrawnForTesting
            view.setImage(SaveFlowTests.image(), sourceID: "reopened-\(cycle)")
            XCTAssertTrue(view.hasTextureForTesting, "A genuine photo must upload after release")
            XCTAssertEqual(view.drawableSizeForTesting.width,
                           view.bounds.width * view.metalLayerContentsScaleForTesting, accuracy: 0.5)
            XCTAssertEqual(view.drawableSizeForTesting.height,
                           view.bounds.height * view.metalLayerContentsScaleForTesting, accuracy: 0.5)
            await finishQueuedRedraws()
            XCTAssertGreaterThan(view.framesDrawnForTesting, closedFrames,
                                 "A genuine photo must resume frame production after release")
        }
    }

    func testSavingDisablesMutationAndFailureKeepsRecipeUsable() async throws {
        let controller = EditModeController(); let image = SaveFlowTests.image()
        controller.enter(image: image, url: root.appendingPathComponent("source.png"), landOn: .resize)
        controller.appendSnapped90(quarters: 1)
        await controller.settleForTesting()
        let before = await controller.recipe?.snapshot()
        controller.setSaving(true); controller.selectTool(.color); controller.appendSnapped90(quarters: 1)
        controller.revertPendingEdits(); controller.done()
        await controller.settleForTesting()
        let after = await controller.recipe?.snapshot()
        XCTAssertEqual(after, before); XCTAssertTrue(controller.isActive)
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        defer { EditToolTransitionModal.responderForTesting = nil }
        controller.setSaving(false); controller.selectTool(.color)
        await controller.settleForTesting()
        XCTAssertEqual(controller.currentTool, .color)
        controller.releaseAfterClose()
    }
    func testBatchPartialRetryDoesNotRepeatCompletedRotation() async throws {
        let url = root.appendingPathComponent("rotate.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let checkpoint = RetryCheckpoint()
        let backups = BackupStore(root: root.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
            phaseCheckpoint: { phase, _ in try await checkpoint.hit(phase) })
        let model = BatchModel(runner: runner)
        var form = BatchForm(); form.convertOn = false; form.resizeOn = false
        form.rotateOn = true; form.renameOn = true; form.template = "renamed_{counter}"
        model.form = form; model.add([ImageGroup(primary: url)])
        XCTAssertTrue(model.consequenceSummary.hasPrefix("Rotate and rename 1 original file."))
        await model.waitForPreview(); model.run(); await model.waitForRun()
        XCTAssertEqual(model.result?.items.first?.isPartial, true)
        XCTAssertTrue(model.summary.contains("partially changed")); XCTAssertTrue(model.canReviewRemaining)
        await checkpoint.allowRename()
        model.reviewRemaining(); await model.waitForPreview()
        XCTAssertEqual(model.queue.count, 1); XCTAssertTrue(model.reviewingRemaining)
        XCTAssertTrue(model.consequenceSummary.hasPrefix("Resume unfinished steps for 1 photo."))
        XCTAssertTrue(model.consequenceSummary.contains("Completed steps will not run again."))
        XCTAssertTrue(model.consequenceSummary.contains("Remaining work may change the original file."))
        XCTAssertTrue(model.consequenceSummary.contains("while their recovery data is available"))
        XCTAssertFalse(model.consequenceSummary.lowercased().contains("rotate"), "completed rotation is not promised as pending work")
        let protectedForm = model.form
        model.apply(BatchPresetStore.builtIns[0]); XCTAssertEqual(model.form, protectedForm)
        model.selection = [url]; model.removeSelected()
        model.add(try photos(1)); model.move(from: IndexSet(integer: 0), to: 1)
        XCTAssertEqual(model.queue.map(\.id), [url], "Protected retry cannot silently change or discard its phase ledger")
        model.run(); await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        let rotations = await checkpoint.rotations
        XCTAssertEqual(rotations, 1, "Retry must never repeat the committed rotation")
        let destination = try XCTUnwrap(model.doneURLs.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 16); XCTAssertEqual(image.height, 8)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int, 6)
        model.runAnother(); XCTAssertTrue(model.queue.isEmpty); XCTAssertFalse(model.reviewingRemaining)
    }
    func testContactPreviewAcceptsOnlyLatestSettingsAndDropsImageOnDismiss() async throws {
        let gate = PreviewGate()
        ContactSheetSheet.previewRendererForTesting = { _, _ in await gate.request() }
        let scope = ContactSheetScope(allCount: 50, folderName: "Photos", selectedCount: 2)
        let options = ContactSheetOptions(title: "Photos", columns: 3)
        let sheet = ContactSheetSheet.makeForTesting(scope: scope, initial: options) { _ in }
        for _ in 0..<200 { if await gate.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let firstRequests = await gate.count; XCTAssertEqual(firstRequests, 1)
        let oldTask = sheet.previewTaskForTesting
        sheet.stepperForTesting.integerValue = 8; sheet.stepForTesting()
        sheet.updatePreviewForTesting()
        for _ in 0..<200 { if await gate.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await gate.finish(1, image: SaveFlowTests.image(width: 8, height: 8))
        await sheet.waitForPreviewForTesting()
        XCTAssertEqual(sheet.previewForTesting?.size.width, 8)
        await gate.finish(0, image: SaveFlowTests.image(width: 16, height: 8))
        await oldTask?.value
        XCTAssertEqual(sheet.previewForTesting?.size.width, 8)
        sheet.cancelForTesting(); XCTAssertNil(sheet.previewForTesting)
    }

    func testConcurrentSaveAfterHeldRenderOpensOnlyOneCopyPanel() async throws {
        let groups = try photos(1)
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: try services())
        defer { viewer.close() }
        try await settle { viewer.displayedItem != nil }
        let controller = viewer.contentRoot.editModeController
        viewer.contentRoot.enterEditMode(image: SaveFlowTests.image(), url: groups[0].primary, landOn: .rotate)
        let gate = PreviewGate()
        controller.renderOverrideForTesting = { _, _, _ in await gate.request() }
        controller.appendSnapped90(quarters: 1)
        for _ in 0..<200 { if await gate.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        var panels = 0
        viewer.savePanelResponderForTesting = { _, _ in panels += 1; return nil }
        let first = Task { await viewer.saveEditedFile(asPanel: true) }
        let second = Task { await viewer.saveEditedFile(asPanel: true) }
        await Task.yield()
        await gate.finish(0, image: SaveFlowTests.image())
        let firstResult = await first.value; let secondResult = await second.value
        XCTAssertFalse(firstResult); XCTAssertFalse(secondResult)
        XCTAssertEqual(panels, 1)
        XCTAssertTrue(controller.isActive); XCTAssertFalse(controller.isSaving)
    }

    func testVisibleThumbnailRemainsChargedAfterCacheEvictionUntilReuse() {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 1 << 20))
        let cache = ThumbnailMemoryLRU(byteLimit: 1 << 20, countLimit: 10, resources: budget)
        let image = SaveFlowTests.image()
        cache.set(image, for: "photo")
        let item = ThumbnailItem(); _ = item.view
        item.imageResources = budget; item.showThumbnail(image, animated: false)
        let charged = budget.snapshot().uniqueRetainedBytes
        cache.removeAll()
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, charged)
        item.prepareForReuse()
        XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
    }
    func testEditRenderOutputIsLeasedBeforePresentationAndReleasedOnClose() async {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 1 << 20))
        let controller = EditModeController(); controller.resources = budget
        let original = SaveFlowTests.image(); let output = SaveFlowTests.image(width: 8, height: 8)
        controller.enter(image: original, url: nil, landOn: .rotate)
        controller.renderOverrideForTesting = { _, _, _ in output }
        var bytesAtPresentation = 0
        controller.onPresentImage = { _ in bytesAtPresentation = budget.snapshot().uniqueRetainedBytes }
        controller.appendSnapped90(quarters: 1); await controller.settleForTesting()
        XCTAssertGreaterThanOrEqual(bytesAtPresentation, original.bytesPerRow * original.height + output.bytesPerRow * output.height)
        controller.releaseAfterClose(); XCTAssertEqual(budget.snapshot().uniqueRetainedBytes, 0)
    }

    func testBatchRecoveryOnlyReceiptRegistersWindowUndoAndRestoresVictim() async throws {
        let source = root.appendingPathComponent("source.jpg")
        let original = try SaveFlowTests.writeImage(source, type: .jpeg)
        let victim = root.appendingPathComponent("victim.jpg"); let victimBytes = Data("old victim".utf8)
        try victimBytes.write(to: victim)
        let backups = BackupStore(root: root.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
            renameCheckpoint: { point, _ in
                switch point {
                case .beforeMove: throw CocoaError(.fileWriteNoPermission)
                case .beforeRollback: throw CocoaError(.fileWriteVolumeReadOnly)
                }
            })
        let model = BatchModel(runner: runner)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: source)], startIndex: 0, services: try services())
        let batch = BatchWindowController(model: model, launcher: viewer)
        defer { batch.close(); viewer.close() }
        viewer.windowUndoManager.groupsByEvent = false; viewer.windowUndoManager.beginUndoGrouping()
        var form = BatchForm(); form.convertOn = false; form.resizeOn = false; form.renameOn = true
        form.template = "victim"; form.onConflict = .replace; model.form = form
        model.add([ImageGroup(primary: source)]); await model.waitForPreview(); model.run(); await model.waitForRun()
        viewer.windowUndoManager.endUndoGrouping()
        XCTAssertEqual(model.result?.doneCount, 0); XCTAssertEqual(model.undoActionName, "Batch Changes")
        XCTAssertEqual(model.result?.replacedOriginals.count, 1); XCTAssertTrue(viewer.windowUndoManager.canUndo)
        XCTAssertEqual(viewer.windowUndoManager.undoActionName, "Batch Changes")
        viewer.windowUndoManager.undo(); await BatchUndo.lastTask?.value
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes); XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testBatchFolderReplaceRegistersUndoForActualOutputVictim() async throws {
        let source = root.appendingPathComponent("source.jpg")
        let original = try SaveFlowTests.writeImage(source, type: .jpeg)
        let output = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let victim = output.appendingPathComponent("source.jpg"); let victimBytes = Data("original output victim".utf8)
        try victimBytes.write(to: victim)
        let backups = BackupStore(root: root.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let model = BatchModel(runner: runner)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: source)], startIndex: 0, services: try services())
        let batch = BatchWindowController(model: model, launcher: viewer)
        defer { batch.close(); viewer.close() }
        viewer.windowUndoManager.groupsByEvent = false; viewer.windowUndoManager.beginUndoGrouping()
        var form = BatchForm(); form.resizeOn = false; form.outputFolder = output; form.onConflict = .replace
        model.form = form; model.add([ImageGroup(primary: source)])
        await model.waitForPreview(); model.run(); await model.waitForRun(); viewer.windowUndoManager.endUndoGrouping()
        XCTAssertEqual(model.result?.doneCount, 1); XCTAssertEqual(model.undoActionName, "Batch Changes")
        XCTAssertTrue(viewer.windowUndoManager.canUndo); XCTAssertNotEqual(try Data(contentsOf: victim), victimBytes)
        viewer.windowUndoManager.undo(); await BatchUndo.lastTask?.value
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes); XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testEditPrimaryCombinesUnsupportedContainerAndActualPrecisionPolicy() async throws {
        let gif = root.appendingPathComponent("animated.gif")
        try SaveFlowTests.writeImage(gif, type: .gif)
        let controller = EditModeController()
        controller.enter(image: SaveFlowTests.image(), url: gif, landOn: .rotate)
        await controller.settleForTesting(); XCTAssertEqual(controller.chromeState.primaryTitle, "Done")
        controller.appendSnapped90(quarters: 1); await controller.settleForTesting()
        XCTAssertTrue(controller.chromeState.requiresCopy); XCTAssertEqual(controller.chromeState.primaryTitle, "Save Copy…")
        controller.releaseAfterClose()
        let high = root.appendingPathComponent("gradient.tiff")
        let pixels = (0..<32).map { UInt16($0 * 2000) }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 4, bitsPerComponent: 16, bitsPerPixel: 16,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(high as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        controller.enter(image: image, url: high, landOn: .rotate); await controller.settleForTesting()
        XCTAssertEqual(controller.chromeState.primaryTitle, "Done")
        controller.appendSnapped90(quarters: 1); await controller.settleForTesting()
        XCTAssertEqual(controller.chromeState.primaryTitle, "Save Copy…"); XCTAssertTrue(controller.chromeState.savePolicy.contains("16-bit"))
        controller.releaseAfterClose()
    }

    func testBrowserNoticesFitWithoutConsumingPhotoViewportAndCollapseAfterRecovery() async throws {
        let groups = try photos(3)
        let items = try groups.map { try BrowserItem.make(from: $0.primary) }
        let issue = FolderScanIssue(url: root.appendingPathComponent("unreadable.jpg"), reason: "The photo could not be read.")
        let responses = NoticeListing(items: items, issue: issue)
        let services = try services()
        let normal = BrowserWindowController(services: services, initialFolder: root,
            folderDiagnosticEnumerator: { _, _ in await responses.scan() })
        defer { normal.close() }
        await normal.listingTask?.value
        normal.window?.setContentSize(NSSize(width: 1000, height: 700))
        normal.window?.contentView?.layoutSubtreeIfNeeded()
        let healthy = normal.contentController.gridScrollViewForTesting.contentView.bounds.height
        XCTAssertGreaterThan(healthy, 400, "No notice should consume the photo workspace")
        await responses.setPartial(true); normal.reloadCurrentFolder(); await normal.listingTask?.value
        normal.window?.contentView?.layoutSubtreeIfNeeded()
        let partial = normal.contentController.gridScrollViewForTesting.contentView.bounds.height
        XCTAssertGreaterThan(partial, 300); XCTAssertLessThan(partial, healthy)
        await responses.setPartial(false); normal.reloadCurrentFolder(); await normal.listingTask?.value
        normal.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(normal.contentController.gridScrollViewForTesting.contentView.bounds.height, healthy, accuracy: 1)
        normal.close()

        let blocked = root.appendingPathComponent("blocked"); try Data([1]).write(to: blocked)
        let primary = blocked.appendingPathComponent("metadata.sqlite")
        let fallback = MetadataStore.openWithFallback(primary: primary, fallback: root.appendingPathComponent("fallback.sqlite"))
        let degradedServices = ShrikeServices(thumbnailCache: services.thumbnailCache, metadataStore: fallback)
        let degraded = BrowserWindowController(services: degradedServices, initialFolder: root,
            folderDiagnosticEnumerator: { _, _ in await responses.scan() })
        defer { degraded.close() }
        await degraded.listingTask?.value
        degraded.window?.setContentSize(NSSize(width: 1000, height: 700))
        degraded.window?.contentView?.layoutSubtreeIfNeeded()
        let storageOnly = degraded.contentController.gridScrollViewForTesting.contentView.bounds.height
        XCTAssertGreaterThan(storageOnly, 300); XCTAssertLessThan(storageOnly, healthy)
        let noticeStack = try XCTUnwrap(degraded.noticeStackForTesting)
        let visible = noticeStack.arrangedSubviews.filter { !$0.isHidden }
        let storageNoticeHeight = visible.reduce(CGFloat.zero) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, visible.count - 1)) * noticeStack.spacing
        XCTAssertEqual(degraded.contentController.view.additionalSafeAreaInsets.top, storageNoticeHeight, accuracy: 1)

        await responses.setPartial(true); degraded.reloadCurrentFolder(); await degraded.listingTask?.value
        degraded.window?.contentView?.layoutSubtreeIfNeeded()
        let both = degraded.contentController.gridScrollViewForTesting.contentView.bounds.height
        XCTAssertGreaterThan(both, 300); XCTAssertLessThan(both, storageOnly)

        // The Browser uses fullSizeContentView, so the root view extends
        // behind the unified toolbar. Verify every visible notice control is
        // in the root safe area rather than merely present in accessibility.
        let rootView = try XCTUnwrap(degraded.window?.contentViewController?.view)
        rootView.layoutSubtreeIfNeeded()
        noticeStack.layoutSubtreeIfNeeded()
        let safeInsets = rootView.safeAreaInsets
        let visibleFrame = NSRect(x: rootView.bounds.minX + safeInsets.left,
            y: rootView.bounds.minY + safeInsets.bottom,
            width: rootView.bounds.width - safeInsets.left - safeInsets.right,
            height: rootView.bounds.height - safeInsets.top - safeInsets.bottom)
        func frameInRoot(_ view: NSView) -> NSRect {
            view.convert(view.bounds, to: rootView)
        }
        XCTAssertLessThanOrEqual(frameInRoot(noticeStack).maxY, visibleFrame.maxY + 1,
            "Notice stack must sit below the unified toolbar")
        let listingNotice = try XCTUnwrap(noticeStack.arrangedSubviews.compactMap { $0 as? NSStackView }.last)
        for control in listingNotice.arrangedSubviews where !control.isHidden {
            let controlFrame = frameInRoot(control)
            XCTAssertGreaterThan(controlFrame.width, 0)
            XCTAssertGreaterThan(controlFrame.height, 0)
            XCTAssertLessThanOrEqual(controlFrame.maxY, visibleFrame.maxY + 1,
                "Listing message and actions must be visible below the toolbar")
        }
        XCTAssertTrue(listingNotice.arrangedSubviews.contains { ($0 as? NSButton)?.title == "Details…" })
        XCTAssertTrue(listingNotice.arrangedSubviews.contains { ($0 as? NSButton)?.title == "Retry" })

        try FileManager.default.removeItem(at: blocked); try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        _ = try await fallback.retryPersistentStore()
        NotificationCenter.default.post(name: Notification.Name("shrike.metadataPersistenceChanged"), object: nil)
        await responses.setPartial(false); degraded.reloadCurrentFolder(); await degraded.listingTask?.value
        degraded.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(degraded.contentController.gridScrollViewForTesting.contentView.bounds.height, healthy, accuracy: 1)
    }

}

private actor RetryCheckpoint {
    var rotations = 0
    var failsRename = true
    func hit(_ phase: BatchPhase) throws {
        if phase == .rotate { rotations += 1 }
        if phase == .rename && failsRename { throw CocoaError(.fileWriteNoPermission) }
    }
    func allowRename() { failsRename = false }
}
private actor PreviewGate {
    var count = 0
    var pending: [Int: CheckedContinuation<CGImage, Never>] = [:]
    func request() async -> CGImage {
        let index = count; count += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, image: CGImage) { pending.removeValue(forKey: index)?.resume(returning: image) }
}

private actor NoticeListing {
    let items: [BrowserItem]
    let issue: FolderScanIssue
    private var partial = false
    init(items: [BrowserItem], issue: FolderScanIssue) { self.items = items; self.issue = issue }
    func setPartial(_ value: Bool) { partial = value }
    func scan() -> ([BrowserItem], [FolderScanIssue]) { (items, partial ? [issue] : []) }
}
