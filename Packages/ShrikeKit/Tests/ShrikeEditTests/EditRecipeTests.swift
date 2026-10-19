//
//  EditRecipeTests.swift
//  ShrikeEditTests
//
//  Covers identity round-trip, order sensitivity, coalescing and
//  undo/redo symmetry.
//

import XCTest
import CoreGraphics
@testable import ShrikeEdit

final class EditRecipeTests: XCTestCase {

    // MARK: Empty recipe preserves pixels.

    func test_emptyRecipe_preservesPixels() async {
        let source = EditFixture.solidRGB(width: 32, height: 32, red: 0.5, green: 0.25, blue: 0.75)
        let recipe = EditRecipe()
        let renderer = EditRenderer()
        let result = await renderer.renderFinal(recipe: recipe, from: source)

        // Identity fast path should return the same CGImage (pointer
        // equality is too strict for Swift-bridged CF objects, so hash
        // the bytes instead).
        let before = ImageHash.bytes(of: source)
        let after  = ImageHash.bytes(of: result)
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after, "empty recipe must not mutate pixels")
    }

    // MARK: Crop-then-rotate ≠ rotate-then-crop.

    func test_orderSensitivity_cropThenRotateDiffersFromRotateThenCrop() async {
        // 64×64 image with a coloured wedge in the top-left quadrant so
        // the two orderings produce visibly different output.
        let source = makeWedge(width: 64, height: 64)
        let cropTL = CropRect(originX: 0, originY: 0, width: 0.5, height: 0.5)

        let cropFirst = EditRecipe(operations: [
            .crop(cropTL),
            .rotate90(quarters: 1),
        ])
        let rotateFirst = EditRecipe(operations: [
            .rotate90(quarters: 1),
            .crop(cropTL),
        ])

        let renderer = EditRenderer()
        let cropFirstResult = await renderer.renderFinal(recipe: cropFirst, from: source)
        let rotateFirstResult = await renderer.renderFinal(recipe: rotateFirst, from: source)

        let a = ImageHash.bytes(of: cropFirstResult)
        let b = ImageHash.bytes(of: rotateFirstResult)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "crop-then-rotate should differ from rotate-then-crop on an asymmetric source")
    }

    // MARK: Coalescing preserves one undoable step.

    func test_replaceLast_coalescesHundredFramesIntoOneOp() async {
        let recipe = EditRecipe()
        // Simulate a drag: 100 distinct slider frames, each replacing
        // the last op.
        for i in 0..<100 {
            let params = ColorAdjustParams(brightness: Double(i) / 100.0)
            await recipe.replaceLast(.colorAdjust(params))
        }

        let opsCount = await recipe.operations.count
        XCTAssertEqual(opsCount, 1, "100 replaceLast calls must collapse to one op")

        // undo pops the single op and leaves the recipe empty.
        let popped = await recipe.undo()
        XCTAssertNotNil(popped)
        let emptyNow = await recipe.operations.count
        XCTAssertEqual(emptyNow, 0)
    }

    func test_replaceLast_onEmptyRecipe_behavesLikeAppend() async {
        let recipe = EditRecipe()
        await recipe.replaceLast(.colorAdjust(ColorAdjustParams(brightness: 0.2)))
        let opsCount = await recipe.operations.count
        XCTAssertEqual(opsCount, 1)
    }

    // MARK: Undo / redo symmetry.

    func test_undoRedo_symmetry() async {
        let recipe = EditRecipe()
        let a: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.1))
        let b: EditOperation = .rotate90(quarters: 1)

        await recipe.append(a)
        await recipe.append(b)

        // Undo once: operations = [a], undone = [b].
        _ = await recipe.undo()
        var ops = await recipe.operations
        var undone = await recipe.undoneOperations
        XCTAssertEqual(ops, [a])
        XCTAssertEqual(undone, [b])

        // Redo: operations = [a, b], undone = [].
        _ = await recipe.redo()
        ops = await recipe.operations
        undone = await recipe.undoneOperations
        XCTAssertEqual(ops, [a, b])
        XCTAssertTrue(undone.isEmpty)
    }

    func test_appendAfterUndo_clearsRedoStack() async {
        let recipe = EditRecipe()
        let a: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.1))
        let b: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.2))
        let c: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.3))

        await recipe.append(a)
        await recipe.append(b)
        _ = await recipe.undo()
        // Redo stack has [b]. Appending C should clear it — redo would
        // otherwise resurrect an orphaned timeline.
        await recipe.append(c)
        let undone = await recipe.undoneOperations
        XCTAssertTrue(undone.isEmpty,
                      "appending after undo must clear the redo stack")
        let ops = await recipe.operations
        XCTAssertEqual(ops, [a, c])
    }

    func test_isDirty_reflectsEitherStack() async {
        let recipe = EditRecipe()
        var dirty = await recipe.isDirty
        XCTAssertFalse(dirty, "fresh recipe is clean")

        await recipe.append(.rotate90(quarters: 1))
        dirty = await recipe.isDirty
        XCTAssertTrue(dirty)

        _ = await recipe.undo()
        dirty = await recipe.isDirty
        XCTAssertTrue(dirty, "an item on the redo stack still counts as dirty")

        await recipe.reset()
        dirty = await recipe.isDirty
        XCTAssertFalse(dirty, "reset clears both stacks")
    }

    // MARK: Tool-entry checkpoints.

    func test_checkpointRestoresAppliedEditsAndExactRedoOrderAfterFork() async {
        let kept: EditOperation = .crop(CropRect(originX: 0, originY: 0, width: 0.5, height: 1))
        let next: EditOperation = .rotate90(quarters: 1)
        let last: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.2))
        let recipe = EditRecipe(operations: [kept, next, last])
        await recipe.undo()
        await recipe.undo()
        let entry = await recipe.checkpoint()

        // A new tool forks the timeline and clears redo. Discard must bring
        // back that old future, rather than merely undoing the newest step.
        await recipe.append(.resize(ResizeSpec(width: 12, height: 10,
                                               interpolation: .lanczos, preventUpscale: true)))
        await recipe.append(.rotate(degrees: 5))
        await recipe.restore(entry)
        let restored = await recipe.checkpoint()
        XCTAssertEqual(restored, entry)
        let firstRedo = await recipe.redo()
        let secondRedo = await recipe.redo()
        let exhaustedRedo = await recipe.redo()
        let operations = await recipe.snapshot()
        XCTAssertEqual(firstRedo, next)
        XCTAssertEqual(secondRedo, last)
        XCTAssertNil(exhaustedRedo)
        XCTAssertEqual(operations, [kept, next, last])
    }

    func test_checkpointRestoresTailBeforeCoalescedReplacementAndReset() async {
        let kept: EditOperation = .colorAdjust(ColorAdjustParams(brightness: 0.15))
        let recipe = EditRecipe(operations: [.rotate90(quarters: 1), kept])
        let entry = await recipe.checkpoint()
        for frame in 1...20 {
            await recipe.replaceLast(.colorAdjust(ColorAdjustParams(brightness: Double(frame) / 50)))
        }
        await recipe.restore(entry)
        let afterCoalescing = await recipe.checkpoint()
        XCTAssertEqual(afterCoalescing, entry, "a checkpoint must not share mutable array contents")
        await recipe.reset()
        await recipe.restore(entry)
        let restored = await recipe.snapshot()
        let lastUndo = await recipe.undo()
        XCTAssertEqual(restored, [.rotate90(quarters: 1), kept])
        XCTAssertEqual(lastUndo, kept, "restoring must preserve the earlier undo boundary")
    }

    func test_discardCurrentGeometryRestoresKeptCropPixelsAndDimensions() async {
        let source = makeWedge(width: 64, height: 64)
        let recipe = EditRecipe(operations: [
            .crop(CropRect(originX: 0, originY: 0, width: 0.5, height: 1)),
        ])
        let renderer = EditRenderer()
        let entry = await recipe.checkpoint()
        let keptImage = await renderer.renderFinal(recipe: recipe, from: source)
        await recipe.append(.rotate90(quarters: 1))
        await recipe.append(.crop(CropRect(originX: 0, originY: 0, width: 1, height: 0.5)))
        let changedImage = await renderer.renderFinal(recipe: recipe, from: source)
        XCTAssertNotEqual(ImageHash.bytes(of: changedImage), ImageHash.bytes(of: keptImage))

        await recipe.restore(entry)
        let restoredImage = await renderer.renderFinal(recipe: recipe, from: source)
        XCTAssertEqual(restoredImage.width, 32)
        XCTAssertEqual(restoredImage.height, 64)
        XCTAssertEqual(ImageHash.bytes(of: restoredImage), ImageHash.bytes(of: keptImage))
        let undone = await recipe.undo()
        XCTAssertNotNil(undone, "the previously kept crop must remain undoable")
        let empty = await recipe.isEmpty
        XCTAssertTrue(empty)
    }

    func test_contentChangesIgnoreRedoOnlyButDetectUndoOfKeptEdit() async {
        let recipe = EditRecipe(operations: [.rotate90(quarters: 1)])
        let entry = await recipe.checkpoint()
        await recipe.append(.rotate90(quarters: 2))
        await recipe.undo()
        var changed = await recipe.hasContentChanges(since: entry)
        XCTAssertFalse(changed, "adding a redo-only future does not change the photo")
        let differentHistory = await recipe.checkpoint()
        XCTAssertNotEqual(differentHistory, entry, "a restore still needs the exact history")

        await recipe.undo()
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed, "undoing a kept step changes the photo")
        await recipe.restore(entry)
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertFalse(changed)
    }

    func test_contentChangesCompareEffectiveWholeStateAndKeepPriorGeometry() async {
        let keptColor = ColorAdjustParams(brightness: 0.15)
        let recipe = EditRecipe(operations: [
            .colorAdjust(keptColor),
            .crop(CropRect(originX: 0, originY: 0, width: 0.5, height: 1)),
        ])
        let entry = await recipe.checkpoint()
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.3)))
        var changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed)
        await recipe.append(.colorAdjust(keptColor))
        await recipe.append(.levels(.identity))
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertFalse(changed, "returning the controls to the entry output needs no prompt")
        await recipe.append(.crop(CropRect(originX: 0, originY: 0, width: 1, height: 0.5)))
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed, "a further crop differs even with earlier kept edits")
    }

    func test_emptyCheckpointRestoresCleanRecipeWithoutRedo() async {
        let recipe = EditRecipe()
        let entry = await recipe.checkpoint()
        await recipe.append(.rotate90(quarters: 1))
        await recipe.undo()
        await recipe.restore(entry)
        let dirty = await recipe.isDirty
        let redo = await recipe.redo()
        XCTAssertFalse(dirty)
        XCTAssertNil(redo)
    }

    func test_contentChangesIgnoreRotateDragReturningToZeroAndRestorePriorRedo() async {
        let kept: EditOperation = .crop(CropRect(originX: 0, originY: 0, width: 0.5, height: 1))
        let priorFuture: EditOperation = .rotate90(quarters: 1)
        let recipe = EditRecipe(operations: [kept, priorFuture])
        await recipe.undo()
        let entry = await recipe.checkpoint()
        await recipe.append(.rotate(degrees: 10))
        var changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed)
        await recipe.replaceLast(.rotate(degrees: 0))
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertFalse(changed, "returning a drag to its origin must not prompt")
        let rawOperations = await recipe.snapshot()
        XCTAssertEqual(rawOperations, [kept, .rotate(degrees: 0)], "comparison must not mutate history")
        await recipe.restore(entry)
        let restored = await recipe.checkpoint()
        let redo = await recipe.redo()
        let noDiscardedFuture = await recipe.redo()
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(redo, priorFuture)
        XCTAssertNil(noDiscardedFuture)
    }

    func test_contentChangesIgnoreOnlyKnownRendererIdentityGeometry() async {
        let recipe = EditRecipe()
        let entry = await recipe.checkpoint()
        let identities: [EditOperation] = [
            .rotate(degrees: 360), .rotate(degrees: -720), .rotate(degrees: 0.00000001),
            .rotate90(quarters: 4), .rotate90(quarters: -8), .crop(.full),
        ]
        for operation in identities { await recipe.append(operation) }
        let changed = await recipe.hasContentChanges(since: entry)
        let rawOperations = await recipe.snapshot()
        XCTAssertFalse(changed)
        XCTAssertEqual(rawOperations, identities)
        XCTAssertEqual(EditRecipe.effectiveOperations(rawOperations), identities,
                       "identity filtering belongs to checkpoint comparison only")
    }

    func test_contentChangesStillDetectRealAnglesAndDoNotNormalizeInverseGeometry() async {
        let recipe = EditRecipe()
        let entry = await recipe.checkpoint()
        await recipe.append(.rotate(degrees: 0.00001))
        var changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed, "an angle beyond the renderer's identity threshold still changes output")
        await recipe.restore(entry)
        await recipe.append(.rotate90(quarters: 1))
        await recipe.append(.rotate90(quarters: -1))
        changed = await recipe.hasContentChanges(since: entry)
        XCTAssertTrue(changed, "do not add general composite or inverse geometry normalization")
    }

    // MARK: - Helpers

    /// A 64×64 image with a distinct "TL quadrant is red, rest is
    /// blue" so crop-then-rotate produces observably different pixels
    /// from rotate-then-crop.
    private func makeWedge(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // Top-left quadrant in bitmap coords (y grows up in CGContext).
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }
    func testOwnedRotationRevisionsKeepOneReplayAndCompleteReplacementRemovalHistory() async {
        let recipe = EditRecipe(operations: [.rotate90(quarters: 1)])
        let prefix = await recipe.snapshot()
        let owner = EditRecipe.GeometryOwner()
        _ = await recipe.setOwnedFreeRotation(.rotateAutoCrop(degrees: 12.5), owner: owner, beginsUndoStep: true)
        _ = await recipe.setOwnedFreeRotation(.rotateAutoCrop(degrees: 13), owner: owner, beginsUndoStep: true)
        let revised = await recipe.snapshot(), depth = await recipe.undoDepth
        XCTAssertEqual(revised, prefix + [.rotateAutoCrop(degrees: 13)])
        XCTAssertEqual(depth, 3, "replacement gestures are history actions without cumulative replay geometry")
        let accepted = await recipe.checkpoint()
        _ = await recipe.undo()
        let first = await recipe.snapshot(), firstOwner = await recipe.ownedFreeRotation()
        XCTAssertEqual(first, prefix + [.rotateAutoCrop(degrees: 12.5)])
        XCTAssertEqual(firstOwner?.owner, owner)
        let withRedo = await recipe.checkpoint()
        _ = await recipe.setOwnedFreeRotation(.rotateAutoCrop(degrees: 12.5), owner: owner, beginsUndoStep: true)
        let noOp = await recipe.checkpoint()
        XCTAssertEqual(noOp, withRedo, "unchanged parameters preserve real Redo and metadata")
        _ = await recipe.redo()
        let redone = await recipe.checkpoint()
        XCTAssertEqual(redone, accepted)
        _ = await recipe.setOwnedFreeRotation(nil, owner: owner, beginsUndoStep: true)
        let identity = await recipe.snapshot(), identityOwner = await recipe.ownedFreeRotation()
        XCTAssertEqual(identity, prefix)
        XCTAssertEqual(identityOwner?.owner, owner)
        XCTAssertNil(identityOwner?.operation)
        _ = await recipe.undo()
        let undoZero = await recipe.snapshot()
        XCTAssertEqual(undoZero, revised)
        _ = await recipe.redo()
        let redoZero = await recipe.snapshot()
        XCTAssertEqual(redoZero, prefix)
        await recipe.restore(withRedo)
        let restored = await recipe.checkpoint()
        XCTAssertEqual(restored, withRedo, "checkpoint restores owners, replacement history and exact Redo")
        _ = await recipe.redo()
        let afterRestoreRedo = await recipe.snapshot()
        XCTAssertEqual(afterRestoreRedo, revised)
    }

    func testOwnedRotationCannotRewriteEarlierBoundaryOrMergeAfterContinuousIdentity() async {
        let recipe = EditRecipe(operations: [.rotate90(quarters: 1)])
        let owner = EditRecipe.GeometryOwner()
        _ = await recipe.setOwnedFreeRotation(.rotate(degrees: 10), owner: owner, beginsUndoStep: true)
        _ = await recipe.setOwnedFreeRotation(nil, owner: owner, beginsUndoStep: false)
        _ = await recipe.setOwnedFreeRotation(.rotate(degrees: 13), owner: owner, beginsUndoStep: false)
        let depth = await recipe.undoDepth
        XCTAssertEqual(depth, 2, "passing through zero cannot merge this gesture into the accepted prefix")
        _ = await recipe.undo()
        let prefix = await recipe.snapshot()
        XCTAssertEqual(prefix, [.rotate90(quarters: 1)])
        _ = await recipe.redo()
        await recipe.append(.rotate90(quarters: -1))
        let boundary = await recipe.checkpoint()
        let rejected = await recipe.setOwnedFreeRotation(.rotate(degrees: 45), owner: owner, beginsUndoStep: true)
        XCTAssertFalse(rejected)
        let unchanged = await recipe.checkpoint()
        XCTAssertEqual(unchanged, boundary)
        _ = await recipe.undo()
        let restoredOwner = await recipe.ownedFreeRotation()
        XCTAssertEqual(restoredOwner?.owner, owner)
        let refined = await recipe.setOwnedFreeRotation(.rotate(degrees: 14), owner: owner, beginsUndoStep: true)
        XCTAssertTrue(refined)
        let forkedRedoDepth = await recipe.redoDepth
        XCTAssertEqual(forkedRedoDepth, 0)
    }

    func testLegacyAppendAndCoalescedReplacementStillUseOneHistoryStepEach() async {
        let recipe = EditRecipe(operations: [.rotate90(quarters: 1)])
        await recipe.append(.colorAdjust(.init(brightness: 0.1)))
        await recipe.replaceLast(.colorAdjust(.init(brightness: 0.2)))
        let before = await recipe.checkpoint()
        let depth = await recipe.undoDepth
        XCTAssertEqual(depth, 2)
        let undo = await recipe.undo()
        XCTAssertEqual(undo, .colorAdjust(.init(brightness: 0.2)))
        let remaining = await recipe.snapshot()
        XCTAssertEqual(remaining, [.rotate90(quarters: 1)])
        let redo = await recipe.redo()
        XCTAssertEqual(redo, undo)
        let after = await recipe.checkpoint()
        XCTAssertEqual(after, before)
    }

}
