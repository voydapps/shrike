//
//  EditDraftEstimateTests.swift
//  ShrikeUITests
//
//  Audit MP-07: a draft render reserves memory for the draft-size copy it
//  works on, not for the full-resolution photo.
//

import CoreGraphics
import XCTest
@testable import ShrikeUI
@testable import ShrikeEdit
@testable import ShrikeCore

@MainActor
final class EditDraftEstimateTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testDraftEstimateUsesTheDraftSize() throws {
        let photo = image(6000, 4000)   // 24 MP
        let size = CGSize(width: 6000, height: 4000)
        let draft = try XCTUnwrap(EditModeController.workingSetEstimate(for: photo, hint: .draft, draftLongEdge: 1280, outputSize: size))
        let full = try XCTUnwrap(EditModeController.workingSetEstimate(for: photo, hint: .full, draftLongEdge: 1280, outputSize: size))
        XCTAssertLessThan(draft.totalBytes, 32 << 20, "a draft is a few MB, not ~480 MB")
        XCTAssertGreaterThan(full.totalBytes, 200 << 20)
    }

    func testSmallPhotoDraftIsUnchanged() throws {
        let photo = image(800, 600)
        let size = CGSize(width: 800, height: 600)
        let draft = try XCTUnwrap(EditModeController.workingSetEstimate(for: photo, hint: .draft, draftLongEdge: 1280, outputSize: size))
        let full = try XCTUnwrap(EditModeController.workingSetEstimate(for: photo, hint: .full, draftLongEdge: 1280, outputSize: size))
        XCTAssertEqual(draft.totalBytes, full.totalBytes)
    }
}
