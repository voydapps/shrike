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
}
