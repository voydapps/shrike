//
//  BrowserWindowController+Commands.swift
//  ShrikeUI
//
//  Menu commands on the Browser. The controller is the
//  window's delegate, so it is in the responder chain after the window.
//

import AppKit
import ShrikeCore

extension BrowserWindowController: ShrikeMenuActions, NSMenuItemValidation, ShrikeCommandTarget, NSSearchFieldDelegate {

    /// Smallest and largest thumbnail size (the toolbar slider's range).
    static let thumbnailSizeRange = 64...320
    static let thumbnailSizeStep = 32

    // MARK: Responder-chain entry points

    @objc public func performShrikeCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = item.shrikeCommand else { return }
        // File ▸ Copy / Move to Folder ▸ slot rows (tag = slot, 0 = Choose Folder…).
        if let verb = FileVerb(command: command), item.parent != nil {
            guard canPerform(command) else { return }
            fileToFolder(verb, item.tag == 0 ? .choose : .slot(item.tag))
            return
        }
        perform(command)
    }

    /// Edit ▸ Copy outside a text field: the selected files and their
    /// images.
    @objc public func copy(_ sender: Any?) {
        perform(.copy)
    }

    /// View ▸ Sort By ▸ Ascending (tag 0) / Descending (tag 1).
    @objc public func setSortDirection(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        var sort = contentController.sort
        sort.direction = tag == 1 ? .descending : .ascending
        applySort(sort)
    }

    func sortDirectionState(tag: Int) -> NSControl.StateValue {
        let descending = contentController.sort.direction == .descending
        return (tag == 1) == descending ? .on : .off
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case ShrikeMainMenu.commandAction, #selector(NSText.copy(_:)),
             #selector(NSText.selectAll(_:)):
            guard let command = menuItem.shrikeCommand else { return false }
            // The right-click menu's Rename… is for one photo (spec 25 §12.1).
            if menuItem.identifier == BrowserContentViewController.contextRenameIdentifier,
               contentController.selectedItems.count != 1 { return false }
            menuItem.state = menuState(for: command)
            switch command {
            case .toggleSidebar:
                menuItem.title = isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            case .toggleInspector:
                menuItem.title = isInspectorCollapsed ? "Show Inspector" : "Hide Inspector"
            case .toggleRAWFile:
                // Always present, greyed when it cannot apply (spec 27 B5).
                menuItem.isHidden = false
                menuItem.title = rawSwitchMenuTitle
            default: break
            }
            return canPerform(command)
        case #selector(setSortDirection(_:)):
            menuItem.state = sortDirectionState(tag: menuItem.tag)
            return true
        case #selector(toolbarToggleInspector(_:)):
            // The Inspector item's » row.
            menuItem.state = isInspectorCollapsed ? .off : .on
            return true
        case NSSelectorFromString("undo:"):
            guard let manager = window?.undoManager else { return false }
            menuItem.title = manager.undoMenuItemTitle
            return manager.canUndo
        case NSSelectorFromString("redo:"):
            guard let manager = window?.undoManager else { return false }
            menuItem.title = manager.redoMenuItemTitle
            return manager.canRedo
        default:
            return responds(to: menuItem.action)
        }
    }

    /// Esc in the search field ends the search; every other
    /// key keeps the field's own handling.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField {
            if commandSelector == #selector(NSResponder.insertTab(_:)) { return moveFocus(from: textView, backward: false) }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) { return moveFocus(from: textView, backward: true) }
        }
        guard control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        endSearchWithEscape()
        return true
    }

    /// Edit ▸ Select All when the grid is not first responder.
    @objc override public func selectAll(_ sender: Any?) { perform(.selectAll) }

    @objc public func undo(_ sender: Any?) { window?.undoManager?.undo() }
    @objc public func redo(_ sender: Any?) { window?.undoManager?.redo() }

    // MARK: ShrikeCommandTarget

    public var commandFileURLs: [URL] {
        contentController.selectedItems.map(\.url)
    }

    /// Share ▸: the selection, each photo with its RAW sibling.
    public var shareFileURLs: [URL] {
        contentController.selectedItems.flatMap { ShareSubmenu.files(of: $0.group) }
    }

    /// The listed folder (Open… starts here).
    public var displayedFolderURL: URL? { currentFolder }

    private var isSidebarCollapsed: Bool {
        splitController.splitViewItems.first?.isCollapsed ?? true
    }

    var isInspectorCollapsed: Bool {
        splitController.splitViewItems.last?.isCollapsed ?? true
    }

    public func canPerform(_ command: ShrikeCommand) -> Bool {
        let selected = contentController.selectedItems.count
        let count = contentController.visibleItems.count
        let size = Prefs.thumbnailSizePt
        if command.externalEditorSlot != nil { return selected > 0 }
        switch command {
        case .viewAsGrid, .viewAsFilmstrip, .viewAsList, .filter, .find,
             .toggleSidebar, .toggleInspector,
             .sortByName, .sortByDateCaptured, .sortByDateModified, .sortBySize,
             .sortByRating, .sortByKind, .sortByDimensions:
            return true
        case .largerThumbnails:
            return contentController.mode != .list && size < Self.thumbnailSizeRange.upperBound
        case .smallerThumbnails:
            return contentController.mode != .list && size > Self.thumbnailSizeRange.lowerBound
        case .openSelection, .showInBrowser, .moveToTrash, .copy, .copyPath,
             .copyToFolder, .moveToFolder, .rename, .tags,
             .revealInFinder, .share, .deselectAll, .toggleFlag,
             .rate0, .rate1, .rate2, .rate3, .rate4, .rate5,
             .rotateLeft, .rotateRight, .rotate180, .flipHorizontal, .flipVertical:
            return selected > 0
        case .selectAll, .nextImage, .previousImage, .firstImage, .lastImage, .slideshow:
            return count > 0
        case .enclosingFolder:
            guard let folder = currentFolder else { return false }
            return folder.deletingLastPathComponent().path != folder.path
        case .addToFavorites:
            return currentFolder != nil
        case .toggleRAWFile:
            // One selected pair (a JPEG with its RAW beside it).
            return contentController.rawSwitchCandidate != nil
        case .showInMaps:
            // One item with GPS.
            return selectedCoordinate != nil
        case .revertToOriginal:
            // One selected item that Shrike edited.
            return revertableSelection != nil
        case .back:
            return !backStack.isEmpty
        case .forward:
            return !forwardStack.isEmpty
        case .nextFolder, .previousFolder:
            // In the Browser.
            return currentFolder != nil
        case .goToFolder:
            //
            return true
        case .batch:
            // The selection, or the whole folder.
            return count > 0
        case .compare:
            // 1 selected compares it with the next.
            return selected > 0 && count >= 2
        case .print:
            // The selection, one photo per page.
            return selected > 0
        case .pageSetup:
            return true
        case .exportContactSheet:
            // Every listed image, or the selection.
            return count > 0
        default:
            // Favorites: not wired to a menu item.
            return false
        }
    }

    public func perform(_ command: ShrikeCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .slideshow: startSlideshow()
        case .addToFavorites: addCurrentFolderToFavorites()
        case .sortByName: applySortKey(.name)
        case .sortByDateCaptured: applySortKey(.dateCaptured)
        case .sortByDateModified: applySortKey(.dateModified)
        case .sortBySize: applySortKey(.size)
        case .sortByRating: applySortKey(.rating)
        case .sortByKind: applySortKey(.kind)
        case .sortByDimensions: applySortKey(.dimensions)
        case .filter: showFilterPopover(filterButton)
        case .largerThumbnails: stepThumbnailSize(+Self.thumbnailSizeStep)
        case .smallerThumbnails: stepThumbnailSize(-Self.thumbnailSizeStep)
        case .toggleSidebar: splitController.toggleSidebar(nil)
        case .toggleInspector:
            if let item = splitController.splitViewItems.last {
                item.animator().isCollapsed = !item.isCollapsed
            }
        case .nextImage: contentController.moveSelection(1)
        case .previousImage: contentController.moveSelection(-1)
        case .firstImage: contentController.moveSelection(-contentController.visibleItems.count)
        case .lastImage: contentController.moveSelection(contentController.visibleItems.count)
        case .rotateLeft: orientSelection(.rotate(quarters: -1))
        case .rotateRight: orientSelection(.rotate(quarters: 1))
        case .rotate180: orientSelection(.rotate(quarters: 2))
        case .flipHorizontal: orientSelection(.flipHorizontal)
        case .flipVertical: orientSelection(.flipVertical)
        case .revertToOriginal: revertSelectionToOriginal()
        case .nextFolder: goToAdjacentFolder(.next)
        case .previousFolder: goToAdjacentFolder(.previous)
        case .goToFolder: showGoToFolderSheet()
        case .batch: openBatch(renameOn: false)
        case .pageSetup: PrintController.runPageSetup(on: window)
        case .exportContactSheet: showContactSheetSheet()
        default:
            if let action = BrowserKeyMap.action(for: command) { dispatch(action) }
        }
    }

    public func menuState(for command: ShrikeCommand) -> NSControl.StateValue {
        let mode = contentController.mode
        switch command {
        case .viewAsGrid: return mode == .grid ? .on : .off
        case .viewAsFilmstrip: return mode == .filmstrip ? .on : .off
        case .viewAsList: return mode == .list ? .on : .off
        default:
            guard let key = Self.sortKey(for: command) else { return .off }
            return contentController.sort.key == key ? .on : .off
        }
    }

    // MARK: Helpers

    static func sortKey(for command: ShrikeCommand) -> BrowserSortKey? {
        switch command {
        case .sortByName: return .name
        case .sortByDateCaptured: return .dateCaptured
        case .sortByDateModified: return .dateModified
        case .sortBySize: return .size
        case .sortByRating: return .rating
        case .sortByKind: return .kind
        case .sortByDimensions: return .dimensions
        default: return nil
        }
    }

    private func applySortKey(_ key: BrowserSortKey) {
        var sort = contentController.sort
        sort.key = key
        applySort(sort)
    }

    func applySort(_ sort: BrowserSort) {
        contentController.sort = sort
    }

    private func stepThumbnailSize(_ delta: Int) {
        let range = Self.thumbnailSizeRange
        let size = min(range.upperBound, max(range.lowerBound, Prefs.thumbnailSizePt + delta))
        thumbSizeSlider.doubleValue = Double(size)
        thumbSizeChanged(thumbSizeSlider)
    }
}
