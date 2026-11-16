//
//  ShortcutsButtonNamesTests.swift
//  ShrikeUITests
//
//  28a round 5: Settings ▸ Shortcuts `Show All Shortcuts…` and the
//  `Settings…` link of the Keyboard Shortcuts window had no accessible
//  name. Both are AppKit buttons now that name themselves.
//

import XCTest
import SwiftUI
@testable import ShrikeUI

@MainActor
final class ShortcutsButtonNamesTests: XCTestCase {

    private func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, [NSButton]) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, buttons(in: window.contentView!))
    }

    private func assertNamed(_ title: String, in all: [NSButton], file: StaticString = #filePath, line: UInt = #line) {
        let button = all.first { $0.title == title }
        XCTAssertNotNil(button, "an AppKit button titled \(title)", file: file, line: line)
        XCTAssertEqual(button?.accessibilityLabel(), title, file: file, line: line)
        XCTAssertEqual(button?.accessibilityTitle(), title, file: file, line: line)
        XCTAssertEqual(button?.cell?.accessibilityLabel(), title, file: file, line: line)
    }

    func testShowAllShortcutsIsNamed() {
        let (window, all) = host(ShortcutsTab(), size: NSSize(width: 560, height: 500))
        defer { window.close() }
        assertNamed(ShortcutsTab.showAllTitle, in: all)
    }

    func testSettingsLinkIsNamedAndLooksLikeALink() {
        let view = ShortcutsWindowView(model: ShortcutsWindowModel(), onSettings: {}, onClose: {})
        let (window, all) = host(view, size: NSSize(width: 440, height: 600))
        defer { window.close() }
        assertNamed(ShortcutsWindowController.settingsLinkTitle, in: all)
        let link = all.first { $0.title == ShortcutsWindowController.settingsLinkTitle }
        XCTAssertEqual(link?.isBordered, false)
        XCTAssertEqual(link?.contentTintColor, .linkColor)
    }
}
