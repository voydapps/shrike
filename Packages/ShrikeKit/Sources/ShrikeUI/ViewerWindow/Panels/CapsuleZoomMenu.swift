//
//  CapsuleZoomMenu.swift
//  ShrikeUI
//
//  The View menu the full-screen capsule's zoom button opens (spec 24
//  §1.3): the same rows as the window toolbar's Zoom pull-down, built
//  from the window (`ViewerToolbarHost`) each time it opens, so the
//  current value, the enabled state and the Show / Hide Histogram title
//  are always right.
//

import AppKit
import ShrikeCore

@MainActor
final class CapsuleZoomMenuSource: NSObject, NSMenuItemValidation {

    weak var host: (any ViewerToolbarHost)?

    /// A fresh menu, or nil without a window to ask.
    func makeMenu() -> NSMenu? {
        guard let host else { return nil }
        let menu = NSMenu(title: "Zoom")
        menu.autoenablesItems = false
        let current = NSMenuItem(title: host.toolbarZoomLine, action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        for row in ViewerWindowToolbar.zoomRows {
            guard let command = row else { menu.addItem(.separator()); continue }
            let title = command == .toggleHistogram
                ? (host.toolbarToggleIsOn(.toggleHistogram) ? "Hide Histogram" : "Show Histogram")
                : command.title
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.isEnabled = host.canPerform(command)
            if let key = ViewerWindowToolbar.keyText(for: command) {
                let style = NSMutableParagraphStyle()
                style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
                item.attributedTitle = NSAttributedString(string: "\(title)\t\(key)", attributes: [
                    .paragraphStyle: style, .font: NSFont.menuFont(ofSize: 0),
                ])
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = ShrikeCommand(rawValue: raw) else { return }
        host?.perform(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let command = ShrikeCommand(rawValue: raw), let host else { return menuItem.isEnabled }
        return host.canPerform(command)
    }
}
