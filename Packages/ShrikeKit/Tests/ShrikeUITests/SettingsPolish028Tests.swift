//
//  SettingsPolish028Tests.swift
//  ShrikeUITests
//
//  Spec 27 V4, P3-6, P3-7, T1.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class SettingsPolish028Tests: XCTestCase {

    private var preferencesSources: [URL] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI/Preferences")
        let all = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        return all.filter { $0.pathExtension == "swift" }
    }

    // MARK: V4

    func testExternalEditorsLayoutEmptyThreeAndFull() {
        XCTAssertEqual(ExternalEditorsTab.layout(editorCount: 0),
                       .init(editorRows: 0, showsEmptyState: true, addEnabled: true))
        XCTAssertEqual(ExternalEditorsTab.layout(editorCount: 3),
                       .init(editorRows: 3, showsEmptyState: false, addEnabled: true))
        XCTAssertFalse(ExternalEditorsTab.layout(editorCount: 9).addEnabled)
        XCTAssertEqual(ExternalEditorsTab.addDisabledHelp, "Up to 9 editors.")
    }

    func testExternalEditorsEmptyStateAndLabels() {
        let key = ShortcutTable.displayString(for: ShrikeCommand.externalEditorCommands[0],
                                              context: .viewer, preset: ShortcutTable.livePreset)
        XCTAssertEqual(ExternalEditorsTab.emptyStateText(firstKey: key),
                       "No editors yet. Add an app to open photos in it with \(key).")
        XCTAssertEqual(ExternalEditorsTab.sendRAWLabel("Pixelmator Pro"), "Send RAW to Pixelmator Pro")
        XCTAssertEqual(ExternalEditorsTab.removeLabel("Pixelmator Pro"), "Remove Pixelmator Pro")
        XCTAssertEqual(ExternalEditorsTab.rowHeight, 36)
    }

    func testExternalEditorsTabIsAGroupedFormWithNoPlaceholderRows() throws {
        let url = preferencesSources.first { $0.lastPathComponent == "ExternalEditorsTab.swift" }
        let text = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
        XCTAssertTrue(text.contains(".formStyle(.grouped)"))
        XCTAssertFalse(text.contains("Choose App…\") {"), "no placeholder 'Choose App…' rows")
        XCTAssertFalse(text.contains("alternatesRowBackgrounds"))
    }

    // MARK: P3-6

    func testNoRowLabelEndsWithAColon() throws {
        let pattern = try NSRegularExpression(pattern: #"(Picker|Toggle|LabeledContent|Stepper|TextField)\("[^"]*:""#)
        for url in preferencesSources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pattern.firstMatch(in: text, range: range), "\(url.lastPathComponent) has a label ending in a colon")
        }
    }

    func testThumbnailsHintReadsTheLiveDefault() {
        XCTAssertEqual(ThumbnailsTab.cellSizeHint,
                       "Longest edge of a grid cell, in points. The default is \(Prefs.defaultThumbnailSizePt) pt.")
        XCTAssertFalse(ThumbnailsTab.cellSizeHint.contains("FastStone"))
        XCTAssertTrue(ThumbnailsTab.sizeOptions.contains(Prefs.defaultThumbnailSizePt))
    }

    // MARK: P3-7

    func testAdvancedRowsAllHaveALeadingLabel() {
        for row in AdvancedTab.rowLabelsForTesting {
            XCTAssertFalse(row.label.isEmpty)
        }
        XCTAssertTrue(AdvancedTab.rowLabelsForTesting.contains { $0.hasControl })
        XCTAssertEqual(AdvancedTab.configurationLabel, "Settings")
    }

    // MARK: T1

    func testWheelTextIsExact() {
        XCTAssertEqual(GeneralTab.wheelHelp,
                       "On a trackpad, a short two-finger scroll moves to the next photo when the photo fits the window and the wheel is set to Changes image.")
    }

    func testExternalEditorsFooterOnlyPointsAtVisibleControls() {
        XCTAssertFalse(ExternalEditorsTab.footer(editorCount: 0).contains("Send RAW files"))
        XCTAssertTrue(ExternalEditorsTab.footer(editorCount: 0).contains("Each added editor gets a switch"))
        XCTAssertTrue(ExternalEditorsTab.footer(editorCount: 2).contains("The switch on a row"))
    }

    func testMoreTrackpadControlsDoesNotRepeatTheLineAbove() {
        XCTAssertFalse(GeneralTab.wheelHelp.contains("Hold ⌘"))
    }
}
