//
//  BrowserActions.swift
//  ShrikeUI
//
//  Browser-scoped action enum + key-map resolver mirroring the viewer's
//  `ViewerAction` / `ViewerKeyMap` pattern. Browser shortcuts are documented
//
//  Keys come from `ShortcutTable` (the one table), the same
//  rows the menus, tooltips and Settings ▸ Shortcuts read.
//

import Foundation
import AppKit
import ShrikeCore

// MARK: - BrowserAction

public enum BrowserAction: Sendable, Hashable {
    // Navigation / selection
    case selectNext
    case selectPrev
    case selectDown
    case selectUp
    case openInViewer
    case upOneFolder
    case goBack
    case goForward
    case selectAll
    case deselectAll
    case focusSearch

    // View mode
    case viewModeGrid
    case viewModeFilmstrip
    case viewModeList
    case cycleSort

    // Rating / flag
    case rate(Int)           // 0-5
    case toggleFlag

    // File ops
    case copyImage
    case copyPath
    case revealInFinder
    case deleteToTrash
    case beginCopyChord      // "C" alone
    case beginMoveChord      // "M" alone

    // Chord follow-ups (a second key after C or M)
    case copyToFolder
    case moveToFolder
    /// Second key of a `C` / `M` chord.
    case fileToFolder(FileVerb, DestinationChoice)
    /// Esc during a chord: cancel it, nothing else.
    case cancelChord
    /// F2 / File ▸ Rename….
    case rename
    /// T / File ▸ Tags….
    case editTags

    // Viewer hand-off
    case toggleViewer
    /// Open in External Editor N (0-based slot).
    case openExternalEditor(slot: Int)
    /// Show in Maps for the one selected item.
    case showInMaps
    /// ⌘4 / FastStone `P`: the Compare window.
    case compare
    /// ⌘P / FastStone ⌥P: print the selection.
    case print
}

// MARK: - Key map

/// Browser resolver: a lookup in `ShortcutTable`. Arrow
/// keys are never mapped — the grid, filmstrip and list move their own
/// selection. Pure — safe for unit tests.
public enum BrowserKeyMap {

    public static func action(
        for snapshot: KeyEventSnapshot,
        preset: ShortcutPreset = .macNative,
        chordPrefix: Character? = nil
    ) -> BrowserAction? {
        if let prefix = chordPrefix {
            return resolveChordFollowup(prefix: prefix, snapshot: snapshot)
        }
        guard let command = ShortcutTable.command(for: snapshot, context: .browser, preset: preset) else {
            return nil
        }
        return action(for: command)
    }

    /// The browser action a table command runs; nil = menu-only or not
    /// wired yet (the menu item is disabled).
    public static func action(for command: ShrikeCommand) -> BrowserAction? {
        switch command {
        case .openSelection: return .openInViewer
        case .showInBrowser: return .toggleViewer
        case .enclosingFolder: return .upOneFolder
        case .back: return .goBack
        case .forward: return .goForward
        case .moveToTrash: return .deleteToTrash
        case .rate0: return .rate(0)
        case .rate1: return .rate(1)
        case .rate2: return .rate(2)
        case .rate3: return .rate(3)
        case .rate4: return .rate(4)
        case .rate5: return .rate(5)
        case .toggleFlag: return .toggleFlag
        case .copyToFolder: return .beginCopyChord
        case .moveToFolder: return .beginMoveChord
        case .rename: return .rename
        case .tags: return .editTags
        case .selectAll: return .selectAll
        case .deselectAll: return .deselectAll
        case .find: return .focusSearch
        case .copy: return .copyImage
        case .copyPath: return .copyPath
        case .revealInFinder: return .revealInFinder
        case .viewAsGrid: return .viewModeGrid
        case .viewAsFilmstrip: return .viewModeFilmstrip
        case .viewAsList: return .viewModeList
        case .showInMaps: return .showInMaps
        case .compare: return .compare
        case .print: return .print
        default:
            if let slot = command.externalEditorSlot { return .openExternalEditor(slot: slot) }
            return nil
        }
    }

    private static func resolveChordFollowup(
        prefix: Character,
        snapshot: KeyEventSnapshot
    ) -> BrowserAction? {
        switch FileChord.followup(prefix: prefix, snapshot: snapshot) {
        case .run(let verb, let choice)?: return .fileToFolder(verb, choice)
        case .cancel?: return .cancelChord
        case .passThrough?, nil: return nil
        }
    }
}
