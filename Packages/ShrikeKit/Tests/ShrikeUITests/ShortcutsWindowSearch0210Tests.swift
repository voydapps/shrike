//
//  ShortcutsWindowSearch0210Tests.swift
//  ShrikeUITests
//
//  0.2.10, audit 2026-10-13 items 1 and 2: the Shortcuts window keeps the
//  Command symbol while filtered, and its search field takes typing on open.
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ShortcutsWindowSearch0210Tests: XCTestCase {

    /// Item 1: "Zoom In" lives in Viewer, Edit Mode and Compare. Rows keyed by
    /// the action alone were mixed up when the filter changed.
    func testRowIdsAreUniqueAcrossTheWholeWindow() {
        let model = ShortcutsWindowModel()
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            model.preset = preset
            model.query = ""
            let ids = model.listSections.flatMap { $0.rows.map(\.id) }
            XCTAssertEqual(ids.count, Set(ids).count, "every row id is unique (\(preset))")
        }
    }

    func testFilteredRowsKeepTheirKeysIncludingTheCommandSymbol() {
        let model = ShortcutsWindowModel()
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            model.preset = preset
            model.query = ""
            let all = model.listSections
            var checked = 0
            for section in all {
                for row in section.rows {
                    model.query = row.action
                    let hit = model.listSections.first { $0.title == section.title }?
                        .rows.first { $0.action == row.action }
                    XCTAssertEqual(hit?.keys, row.keys, "\(section.title)/\(row.action) filtered by its title")
                    XCTAssertEqual(hit?.id, row.id)
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 50)
            model.query = "zoom"
            let zoomIn = model.listSections.first { $0.title == "Viewer" }?.rows.first { $0.action == "Zoom In" }
            let zoomOut = model.listSections.first { $0.title == "Viewer" }?.rows.first { $0.action == "Zoom Out" }
            if preset == .macNative {
                XCTAssertEqual(zoomIn?.keys, "⌘+, ⌘=, ⇧⌘+")
                XCTAssertEqual(zoomOut?.keys, "⌘-")
                // Edit Mode keeps its own keys, Compare has bare ones, side by side.
                let edit = model.listSections.first { $0.title == "Edit Mode" }?.rows.first { $0.action == "Zoom In" }
                let compare = model.listSections.first { $0.title == "Compare" }?.rows.first { $0.action == "Zoom In" }
                XCTAssertEqual(edit?.keys, "⌘+, ⌘=")
                XCTAssertEqual(compare?.keys, "+, =, ⇧+")
            }
            model.query = ""
        }
    }

    /// Item 9: Esc also closes a viewer that has no Browser, and the list says so.
    func testEscapeLabelCoversClosingALoneViewer() {
        let viewer = ShortcutsTab.sections(for: .macNative).first { $0.title == "Viewer" }
        let esc = viewer?.rows.first { $0.keys == "Esc" }
        XCTAssertEqual(esc?.action, "Exit Full Screen, Return to Browser, or Close")
    }

    /// Item 2: the search field is the first responder when the window opens,
    /// typing lands, and the same holds on a re-open.
    func testSearchFieldTakesTypingOnOpenAndReopen() throws {
        let controller = ShortcutsWindowController.shared
        for round in 1...2 {
            controller.modelForTesting.query = ""
            controller.show()
            let window = try XCTUnwrap(controller.window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "round \(round): a field editor is first responder")
            let field = try XCTUnwrap(editor.delegate as? NSTextField, "round \(round): it belongs to the search field")
            XCTAssertTrue(field.isEditable)
            editor.insertText("zoom", replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(controller.modelForTesting.query, "zoom", "round \(round): typing reached the model")
            window.close()
        }
    }

    func testLiveTypographyPreservesSearchEditingAndScrollableResults() throws {
        let savedLarge = Prefs.largerChrome
        let savedPreset = Prefs.shortcutPreset
        let controller = ShortcutsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        let savedFrame = window.frame
        defer {
            window.close()
            window.setFrame(savedFrame, display: false)
            Prefs.largerChrome = savedLarge
            Prefs.shortcutPreset = savedPreset
            controller.modelForTesting.refresh()
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        }
        XCTAssertFalse(window.isVisible, "the native test begins with the Shortcuts window closed")
        Prefs.largerChrome = false
        Prefs.shortcutPreset = .macNative
        controller.modelForTesting.query = ""
        controller.show()
        window.setContentSize(NSSize(width: 400, height: 360))
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)

        func settle(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !predicate(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        func scrollRegions(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollRegions)
        }
        let content = try XCTUnwrap(window.contentView)
        func overflowingResults() -> NSScrollView? {
            scrollRegions(content).first {
                ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100
            }
        }
        settle { overflowingResults() != nil }
        let scroll = try XCTUnwrap(overflowingResults(), "results overflow vertically at minimum window size")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "native scrolling reaches later sections")

        // Walk the public window accessibility tree, including native view and
        // unignored children. Starting at the hosting view alone omits its AX bridge.
        struct KeyPair {
            let zoomIn: NSRect
            let zoomOut: NSRect
            let bothVisible: Bool
            let visibleKeys: Int
            var separation: CGFloat { abs(zoomIn.minY - zoomOut.minY) }
        }
        func compareKeys() -> KeyPair? {
            func property(_ object: NSObject, _ key: String) -> Any? {
                guard object.responds(to: NSSelectorFromString(key)) else { return nil }
                return object.value(forKey: key)
            }
            let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            var queue: [(NSObject, Int, Bool)] = [(window, 0, false)]
            var seen: Set<ObjectIdentifier> = []
            var cells: [(String, NSRect, Bool)] = []
            while !queue.isEmpty, seen.count < 600 {
                let (object, depth, parentInResults) = queue.removeFirst()
                guard depth < 20, seen.insert(ObjectIdentifier(object)).inserted else { continue }
                let identifier = property(object, "accessibilityIdentifier") as? String ?? ""
                let value = property(object, "accessibilityValue") as? String ?? ""
                let inResults = parentInResults || identifier == "shortcuts.results" || object === scroll || object === document
                var frame = (property(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                var hidden = false
                if let view = object as? NSView, let nativeWindow = view.window {
                    frame = nativeWindow.convertToScreen(view.convert(view.bounds, to: nil))
                    hidden = view.isHiddenOrHasHiddenAncestor
                }
                if inResults, !value.isEmpty {
                    cells.append((value, frame, !hidden && !frame.isEmpty && frame.intersects(viewport)))
                }
                var children = property(object, "accessibilityChildren") as? [Any] ?? []
                children += property(object, "accessibilityContents") as? [Any] ?? []
                if children.isEmpty, let view = object as? NSView { children = view.subviews }
                if object === window { children.append(content) }
                children += NSAccessibility.unignoredChildren(from: children)
                queue += children.compactMap { ($0 as? NSObject).map { ($0, depth + 1, inResults) } }
            }
            guard let zoomIn = cells.first(where: { $0.0 == "+, =, ⇧+" }),
                  let zoomOut = cells.first(where: { $0.0 == "-" }) else { return nil }
            let matchingKeys = Set(controller.modelForTesting.listSections.flatMap { $0.rows.map(\.keys) })
            return KeyPair(zoomIn: zoomIn.1, zoomOut: zoomOut.1,
                           bothVisible: zoomIn.2 && zoomOut.2,
                           visibleKeys: cells.filter { $0.2 && matchingKeys.contains($0.0) }.count)
        }
        controller.focusSearchField()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("zoom", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle { (compareKeys()?.visibleKeys ?? 0) > 0 }
        XCTAssertEqual(controller.modelForTesting.query, "zoom")
        let filtered = try XCTUnwrap(compareKeys(), "the actual Compare key pair exists after filtering from the end")
        XCTAssertGreaterThan(filtered.visibleKeys, 0,
                             "actual keys belonging to matching rows intersect the filtered viewport")
        // Choosing the Compare rows for measurement is a native scrolling
        // action, separate from checking that filtering left visible matches.
        if !filtered.bothVisible {
            let windowRect = window.convertFromScreen(filtered.zoomIn.union(filtered.zoomOut))
            document.scrollToVisible(document.convert(windowRect, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        settle { compareKeys()?.bothVisible == true }
        let standard = try XCTUnwrap(compareKeys())
        XCTAssertTrue(standard.bothVisible, "native scrolling brings the chosen Compare pair into view")
        XCTAssertGreaterThan(standard.visibleKeys, 0)
        print("SHORTCUT_FILTER_VISIBLE_MATCHES \(filtered.visibleKeys) compareInitiallyVisible=\(filtered.bothVisible)")
        XCTAssertEqual(standard.separation, 28, accuracy: 0.5)
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        let selection = editor.selectedRange()

        func checkEditing() {
            XCTAssertTrue(window.firstResponder === editor, "live typography preserves the native editor")
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.string, "zoom")
            XCTAssertEqual(controller.modelForTesting.query, "zoom")
        }
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        settle {
            guard let keys = compareKeys() else { return false }
            return keys.bothVisible && abs(keys.separation - 32) < 0.5 && keys.zoomIn.width > standard.zoomIn.width
        }
        let large = try XCTUnwrap(compareKeys())
        checkEditing()
        XCTAssertTrue(large.bothVisible)
        XCTAssertGreaterThan(large.visibleKeys, 0)
        XCTAssertEqual(large.separation, 32, accuracy: 0.5, "the same visible rows grow to the Large minimum")
        XCTAssertGreaterThan(large.zoomIn.width, standard.zoomIn.width, "the actual native key text grows")

        Prefs.largerChrome = false
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        settle {
            guard let keys = compareKeys() else { return false }
            return keys.bothVisible && abs(keys.separation - 28) < 0.5 && abs(keys.zoomIn.width - standard.zoomIn.width) < 0.5
        }
        let restored = try XCTUnwrap(compareKeys())
        checkEditing()
        XCTAssertTrue(restored.bothVisible)
        XCTAssertEqual(restored.separation, 28, accuracy: 0.5)
        XCTAssertEqual(restored.zoomIn.width, standard.zoomIn.width, accuracy: 0.5)
        XCTAssertLessThan(restored.zoomIn.width, large.zoomIn.width, "native text returns to Standard width")
        print("SHORTCUT_RENDERED_GEOMETRY Standard=\(standard.separation)/\(standard.zoomIn.width) Large=\(large.separation)/\(large.zoomIn.width) Restored=\(restored.separation)/\(restored.zoomIn.width) visible=\(standard.visibleKeys),\(large.visibleKeys),\(restored.visibleKeys)")
    }

}
