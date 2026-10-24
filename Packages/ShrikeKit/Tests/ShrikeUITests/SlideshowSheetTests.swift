//
//  SlideshowSheetTests.swift
//  ShrikeUITests
//
//  Return in "Each image" presses
//  Start with the typed value; the field refuses letters while typing;
//  the range is 1–60 with a stepper.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class SlideshowSheetTests: XCTestCase {

    private let scope = SlideshowScope(allCount: 10, folderName: "Italy", selectedCount: 0)

    func testFieldRefusesLettersAndAThirdDigit() {
        let f = SlideshowIntervalFormatter()
        XCTAssertFalse(f.isPartialStringValid("a", newEditingString: nil, errorDescription: nil))
        XCTAssertFalse(f.isPartialStringValid("1x", newEditingString: nil, errorDescription: nil))
        XCTAssertFalse(f.isPartialStringValid("100", newEditingString: nil, errorDescription: nil))
        XCTAssertTrue(f.isPartialStringValid("12", newEditingString: nil, errorDescription: nil))
        XCTAssertTrue(f.isPartialStringValid("", newEditingString: nil, errorDescription: nil))
    }

    func testValuesAreClampedToOneToSixty() {
        XCTAssertEqual(SlideshowIntervalFormatter.clamp("0"), 1)
        XCTAssertEqual(SlideshowIntervalFormatter.clamp(""), 1)
        XCTAssertEqual(SlideshowIntervalFormatter.clamp("75"), 60)
        XCTAssertEqual(SlideshowIntervalFormatter.clamp("7"), 7)
    }

    // Spec 25 §9.
    func testDefaultRadioFollowsTheSelectionCount() {
        let settings = SlideshowSettings.fromPrefs()
        for (selected, selectedOn, title) in [(0, false, "0 selected photos"),
                                            (1, false, "1 selected photo"),
                                            (2, true, "2 selected photos"),
                                            (12, true, "12 selected photos")] {
            let scope = SlideshowScope(allCount: 25, folderName: "F", selectedCount: selected)
            let sheet = SlideshowSheet.makeForTesting(scope: scope, settings: settings) { _ in }
            XCTAssertEqual(sheet.selectedRadioForTesting.state == .on, selectedOn, "\(selected) selected")
            XCTAssertEqual(sheet.allRadioForTesting.state == .on, !selectedOn, "\(selected) selected")
            XCTAssertEqual(sheet.selectedRadioForTesting.title, title)
            XCTAssertEqual(sheet.allRadioForTesting.title, "All 25 visible photos in “F”")
        }
        for (count, title) in [(0, "All 0 visible photos in “F”"),
                               (1, "All 1 visible photo in “F”"),
                               (2, "All 2 visible photos in “F”")] {
            let scope = SlideshowScope(allCount: count, folderName: "F", selectedCount: 0)
            let sheet = SlideshowSheet.makeForTesting(scope: scope, settings: settings) { _ in }
            XCTAssertEqual(sheet.allRadioForTesting.title, title)
            XCTAssertEqual(sheet.selectedRadioForTesting.title, "0 selected photos")
            XCTAssertEqual(sheet.allRadioForTesting.state, .on)
            XCTAssertEqual(sheet.selectedRadioForTesting.state, .off)
        }
    }

    func testStepperRangeIsOneToSixty() {
        var settings = SlideshowSettings.fromPrefs()
        settings.intervalSec = 4
        let sheet = SlideshowSheet.makeForTesting(scope: scope, settings: settings) { _ in }
        XCTAssertEqual(sheet.stepperForTesting.minValue, 1)
        XCTAssertEqual(sheet.stepperForTesting.maxValue, 60)
        XCTAssertFalse(sheet.stepperForTesting.valueWraps)
        XCTAssertEqual(sheet.intervalFieldForTesting.integerValue, 4)
        XCTAssertEqual(sheet.panelForTesting?.defaultButtonCell?.title, "Start", "Start is the default button")
    }

    func testReturnInEachImagePressesStartWithTheTypedValue() {
        let savedInterval = Prefs.slideshowIntervalSec
        defer { Prefs.slideshowIntervalSec = savedInterval }
        var settings = SlideshowSettings.fromPrefs()
        settings.intervalSec = 4
        var result: SlideshowRequest??
        let sheet = SlideshowSheet.makeForTesting(scope: scope, settings: settings) { result = .some($0) }
        let editor = NSTextView()
        editor.string = "9"
        let handled = sheet.control(sheet.intervalFieldForTesting, textView: editor,
                                    doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(handled)
        let request = try? XCTUnwrap(result ?? nil, "Return pressed Start")
        XCTAssertEqual(request?.settings.intervalSec, 9)
        // Other commands (Tab) are left to the field.
        let other = SlideshowSheet.makeForTesting(scope: scope, settings: settings) { _ in }
        XCTAssertFalse(other.control(other.intervalFieldForTesting, textView: editor,
                                     doCommandBy: #selector(NSResponder.insertTab(_:))))
    }
}
