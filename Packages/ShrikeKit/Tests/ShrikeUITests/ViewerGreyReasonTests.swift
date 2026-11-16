//
//  ViewerGreyReasonTests.swift
//  ShrikeUITests
//
//  Spec 28 §2 / §17.7: why a viewer command is grey. Window-free.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class ViewerGreyReasonTests: XCTestCase {

    func testTextsMatchTheSpecTable() {
        XCTAssertEqual(ViewerGreyReason.raw.tooltipLine, "RAW files are not changed. Switch to the JPEG to edit.")
        XCTAssertEqual(ViewerGreyReason.broken.tooltipLine, "This photo can\u{2019}t be opened, so there is nothing to edit.")
        XCTAssertEqual(ViewerGreyReason.loading.tooltipLine, "The photo is still loading.")
        XCTAssertNil(ViewerGreyReason.noPhoto.tooltipLine, "no tooltip needed")
        XCTAssertEqual(ViewerGreyReason.loading.toastText, "Wait for the photo to finish loading, then try again.")
        XCTAssertEqual(ViewerGreyReason.noPhoto.toastText, "No photo to edit")
        XCTAssertEqual(ViewerGreyReason.raw.toastText, ViewerGreyReason.raw.tooltipLine)
        XCTAssertEqual(ViewerGreyReason.broken.toastText, ViewerGreyReason.broken.tooltipLine)
    }

    func testOrderRawBrokenLoading() {
        XCTAssertEqual(ViewerGreyReason.of(rawShown: true, broken: true, hasPhoto: true, ready: false), .raw)
        XCTAssertEqual(ViewerGreyReason.of(rawShown: false, broken: true, hasPhoto: true, ready: false), .broken)
        XCTAssertEqual(ViewerGreyReason.of(rawShown: false, broken: false, hasPhoto: true, ready: false), .loading)
        XCTAssertEqual(ViewerGreyReason.of(rawShown: false, broken: false, hasPhoto: false, ready: false), .noPhoto)
        XCTAssertEqual(ViewerGreyReason.of(rawShown: false, broken: true, hasPhoto: false, ready: true), .broken)
        XCTAssertNil(ViewerGreyReason.of(rawShown: false, broken: false, hasPhoto: true, ready: true))
    }

    func testZoomKeysAreTheZoomFamily() {
        for action: ViewerAction in [.zoomIn, .zoomOut, .zoom100, .zoomActualSize, .zoomBestFit, .fitToWindow,
                                     .zoom200, .zoom300, .zoom1000, .fitWidth, .fitHeight] {
            XCTAssertTrue(ViewerWindow.isZoom(action), "\(action)")
        }
        for action: ViewerAction in [.nextImage, .rotateLeft, .openEditMode] { XCTAssertFalse(ViewerWindow.isZoom(action)) }
    }
}
