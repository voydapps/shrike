import AppKit
import XCTest
@testable import ShrikeUI

/// Crop and Resize number fields line up (same x, same width), and the
/// primary button says "Saving…" only while a file is being written.
@MainActor
final class EditFieldAlignmentAndSaveTitleTests: XCTestCase {

    private func laidOut(_ panel: NSView) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.widthAnchor.constraint(equalToConstant: 280),
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func frame(_ field: NSTextField, in host: NSView) -> NSRect {
        field.convert(field.bounds, to: host)
    }

    func testCropAndResizeFieldsShareOneColumn() {
        let crop = CropPanel()
        crop.setDimensions(width: 4172, height: 2773)
        let cropHost = laidOut(crop)
        let resize = ResizePanel()
        resize.sourcePixelSize = CGSize(width: 4172, height: 2773)
        let resizeHost = laidOut(resize)

        let rects = [frame(crop._widthField, in: cropHost), frame(crop._heightField, in: cropHost),
                     frame(resize._widthField, in: resizeHost), frame(resize._heightField, in: resizeHost),
                     frame(resize._percentField, in: resizeHost)]
        for r in rects {
            XCTAssertEqual(r.minX, rects[0].minX, accuracy: 0.5, "all fields start at one x")
            XCTAssertEqual(r.width, rects[0].width, accuracy: 0.5, "all fields have one width")
        }
        XCTAssertEqual(rects[0].width, EditLayout.numericFieldWidth, accuracy: 0.5)
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] } + view.subviews.flatMap { allTextFields(in: $0) }
    }

    func testLabelsAreRightAlignedInTheSharedColumn() {
        let crop = CropPanel()
        let host = laidOut(crop)
        let labels = allTextFields(in: host).filter { ["W", "H"].contains($0.stringValue) }
        XCTAssertEqual(labels.count, 2)
        for l in labels {
            XCTAssertEqual(l.alignment, NSTextAlignment.right)
            XCTAssertEqual(l.alignmentRect(forFrame: l.frame).width, EditLayout.fieldLabelColumnWidth, accuracy: 0.5)
        }
    }

    func testPrimaryTitleWhileTheSavePanelIsOpen() {
        var s = EditChromeState()
        s.hasEdits = true; s.requiresCopy = true; s.isSaving = true
        XCTAssertEqual(s.primaryTitle, "Saving…")
        s.isAwaitingDestination = true
        XCTAssertEqual(s.primaryTitle, "Save Copy…", "nothing is written while the panel waits")
        s.isAwaitingDestination = false
        XCTAssertEqual(s.primaryTitle, "Saving…", "the write has started")
        s.isSaving = false
        XCTAssertEqual(s.primaryTitle, "Save Copy…", "a cancelled panel restores the title")
    }
}

