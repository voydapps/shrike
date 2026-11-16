//
//  GridContextMenuModel.swift
//  ShrikeUI
//
//  The grid's right-click menu as plain data. One pure
//  function turns the selection state into the rows (title, enabled, submenu,
//  separator, command); the NSMenu is built from, and kept in step with, that
//  model. `Edit Photo`'s rule lives here too, so the menu row, the Photo menu
//  and the key path ask the same question.
//

import Foundation
import ShrikeCore

/// What the menu needs to know about the selection. Read from what the grid
/// already holds in memory: no disk access.
struct GridMenuState: Equatable {
    /// Photos selected.
    var selectedCount: Int
    /// Photos in the listing (Slideshow and Batch work on the folder).
    var visibleCount: Int
    /// One photo selected and its primary file is a RAW (nothing to edit: RAW is never written).
    var rawOnly = false
    /// One photo selected and the listing could not read the file (placeholder size or date).
    var unreadable = false
    /// One photo selected, Shrike kept its original, and a backup store exists.
    var hasKeptOriginal = false

    static let nothing = GridMenuState(selectedCount: 0, visibleCount: 0)

    /// Edit Photo: one readable photo that is not RAW-only.
    var canEditPhoto: Bool { selectedCount == 1 && !rawOnly && !unreadable }
}

/// One row of the model.
struct GridMenuRow: Equatable {
    enum ID: String, Equatable {
        case separator, open, openWith, externalEditor, reveal, share, slideshow, batch, compare
        case rotateLeft, rotateRight, editPhoto
        case rating, flag, tags
        case copyToFolder, moveToFolder, rename, revert
        case copy, copyPath
        case trash
    }

    var id: ID
    var title: String
    var enabled = true
    var hasSubmenu = false
    /// The command the row sends up the responder chain; nil for rows the menu's owner handles.
    var command: ShrikeCommand?

    var isSeparator: Bool { id == .separator }
}

enum GridContextMenuModel {

    /// The rows to show for `state`, in their menu order.
    /// `Revert to Original` is left out when no kept original exists.
    static func rows(for state: GridMenuState) -> [GridMenuRow] {
        let some = state.selectedCount > 0
        let one = state.selectedCount == 1
        func row(_ id: GridMenuRow.ID, _ title: String, enabled: Bool, submenu: Bool = false,
                 command: ShrikeCommand? = nil) -> GridMenuRow {
            GridMenuRow(id: id, title: title, enabled: enabled, hasSubmenu: submenu, command: command)
        }
        let line = GridMenuRow(id: .separator, title: "", enabled: false)
        var rows: [GridMenuRow] = [
            row(.open, "Open", enabled: some),
            row(.openWith, "Open With", enabled: some, submenu: true),
            row(.externalEditor, "Open in External Editor", enabled: some, submenu: true),
            row(.reveal, ShrikeCommand.revealInFinder.title, enabled: some, command: .revealInFinder),
            row(.share, ShrikeCommand.share.title, enabled: some, submenu: true, command: .share),
            row(.slideshow, ShrikeCommand.slideshow.title, enabled: state.visibleCount > 0, command: .slideshow),
            row(.batch, ShrikeCommand.batch.title, enabled: state.visibleCount > 0, command: .batch),
            row(.compare, ShrikeCommand.compare.title, enabled: some && state.visibleCount >= 2, command: .compare),
            line,
            row(.rotateLeft, ShrikeCommand.rotateLeft.title, enabled: some, command: .rotateLeft),
            row(.rotateRight, ShrikeCommand.rotateRight.title, enabled: some, command: .rotateRight),
            row(.editPhoto, ShrikeCommand.editImage.title, enabled: state.canEditPhoto, command: .editImage),
            line,
            row(.rating, "Rating", enabled: some, submenu: true),
            row(.flag, ShrikeCommand.toggleFlag.title, enabled: some, command: .toggleFlag),
            row(.tags, ShrikeCommand.tags.title, enabled: some, command: .tags),
            line,
            row(.copyToFolder, ShrikeCommand.copyToFolder.title, enabled: some, submenu: true, command: .copyToFolder),
            row(.moveToFolder, ShrikeCommand.moveToFolder.title, enabled: some, submenu: true, command: .moveToFolder),
            row(.rename, ShrikeCommand.rename.title, enabled: one, command: .rename),
        ]
        if state.hasKeptOriginal && one {
            rows.append(row(.revert, ShrikeCommand.revertToOriginal.title, enabled: true, command: .revertToOriginal))
        }
        rows += [
            line,
            row(.copy, ShrikeCommand.copy.title, enabled: some, command: .copy),
            row(.copyPath, ShrikeCommand.copyPath.title, enabled: some, command: .copyPath),
            line,
            row(.trash, ShrikeCommand.moveToTrash.title, enabled: some, command: .moveToTrash),
        ]
        return rows
    }

    /// Whether the row `id` is enabled for `state` (the rows' own rule, for menu validation).
    static func isEnabled(_ id: GridMenuRow.ID, for state: GridMenuState) -> Bool {
        var withOriginal = state
        withOriginal.hasKeptOriginal = state.selectedCount == 1
        return rows(for: withOriginal).first { $0.id == id }?.enabled ?? false
    }
}

extension BrowserItem {
    /// The listing could not read the file (it left placeholders for size and date).
    var isListingUnreadable: Bool {
        fileSize <= 0 || modificationDate.timeIntervalSince1970 <= 0
    }
}
