//
//  NoTrashDeleteCopyTests.swift
//  ShrikeUITests
//
//  Spec 21b §4: the permanent-delete alert for a volume without a Trash.
//

import XCTest
import AppKit
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class NoTrashDeleteCopyTests: XCTestCase {

    private func group(_ name: String, raw: Bool = false) -> ImageGroup {
        let url = URL(fileURLWithPath: "/Volumes/USB/\(name)")
        return ImageGroup(primary: url, companions: raw
            ? [ImageGroup.Companion(url: URL(fileURLWithPath: "/Volumes/USB/x.CR2"), kind: .raw)] : [])
    }

    func testOnePhoto() {
        let copy = FileActionCopy.noTrashDelete([group("DSC_0042.jpg")])
        XCTAssertEqual(copy.message, "Delete “DSC_0042.jpg” now?")
        XCTAssertEqual(copy.deleteTitle, "Delete")
        XCTAssertTrue(copy.information.hasPrefix("This disk has no Trash, so the photo can't be moved there."))
        XCTAssertFalse(copy.information.contains("sidecar"))
        XCTAssertFalse(copy.information.contains("volume"), "never 'volume' then 'it'")
    }

    func testManyPhotosAndCompanions() {
        let copy = FileActionCopy.noTrashDelete([group("a.jpg"), group("b.jpg", raw: true), group("c.jpg")])
        XCTAssertEqual(copy.message, "Delete 3 photos now?")
        XCTAssertEqual(copy.deleteTitle, "Delete 3 Photos")
        XCTAssertTrue(copy.information.contains("these photos can't be moved there"))
        XCTAssertTrue(copy.information.contains("RAW and sidecar files are deleted too"))
    }

    func testCancelIsTheDefaultForReturnAndEsc() {
        let copy = FileActionCopy.noTrashDelete([group("a.jpg")])
        let alert = ShrikeAlert.make(message: copy.message, information: copy.information, buttons: copy.buttons)
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete"], "NSAlert order: rightmost first")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "", "Delete has no key equivalent")
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
    }

    func testDeleteAllBackupsAlertDefaultsToCancelAndSaysWhatItDoes() {
        let copy = EditingTab.DeleteAllCopy(bytes: 3_500_000)
        XCTAssertEqual(copy.message, "Delete all backups?")
        XCTAssertTrue(copy.information.contains("Your photos are not changed"))
        XCTAssertTrue(copy.information.contains("frees"))
        let alert = ShrikeAlert.make(message: copy.message, information: copy.information,
                                     buttons: [ShrikeAlert.Button(copy.deleteTitle, role: .destructive), .safeCancel()])
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete All Backups"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
    }
}
