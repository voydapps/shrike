//
//  ViewerWindow+Commands.swift
//  ShrikeUI
//
//  Menu commands on the viewer: which apply, and what they
//  run. Keys and menus share one path: the command maps to a
//  `ViewerAction` through `ViewerKeyMap.action(for:context:)`.
//

import AppKit
import ShrikeCore

extension ViewerWindow: ShrikeMenuActions, ShrikeCommandTarget {

    // MARK: Responder-chain entry points

    @objc public func performShrikeCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = item.shrikeCommand else { return }
        // File ▸ Copy / Move to Folder ▸ slot rows carry the slot number
        // in `tag` (0 = Choose Folder…).
        if let verb = FileVerb(command: command), item.parent?.submenu != nil,
           item.parent?.submenu === item.menu {
            guard canPerform(command) else { return }
            fileToFolder(verb, item.tag == 0 ? .choose : .slot(item.tag))
            return
        }
        perform(command)
    }

    /// Edit ▸ Copy outside a text field: the file and its image.
    @objc public func copy(_ sender: Any?) {
        perform(.copy)
    }

    override public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case ShrikeMainMenu.commandAction, #selector(NSText.copy(_:)):
            guard let command = menuItem.shrikeCommand else { return false }
            menuItem.state = menuState(for: command)
            if let title = panelMenuTitle(command) {
                // The panel items flip their title, no check.
                menuItem.title = title
                menuItem.state = .off
            }
            return canPerform(command)
        case NSSelectorFromString("undo:"):
            if contentRoot.isEditModeActive {
                // "Undo Auto Contrast" after an auto.
                menuItem.title = contentRoot.editModeController.undoMenuTitle
                return true
            }
            menuItem.title = windowUndoManager.undoMenuItemTitle
            return windowUndoManager.canUndo
        case NSSelectorFromString("redo:"):
            if contentRoot.isEditModeActive {
                menuItem.title = contentRoot.editModeController.redoMenuTitle
                return true
            }
            menuItem.title = windowUndoManager.redoMenuItemTitle
            return windowUndoManager.canRedo
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    // MARK: ShrikeCommandTarget

    public var commandFileURLs: [URL] {
        displayedItem.map { [$0.group.primary] } ?? []
    }

    /// Share ▸: the photo on screen with its RAW sibling.
    public var shareFileURLs: [URL] {
        displayedItem.map { ShareSubmenu.files(of: $0.group) } ?? []
    }

    public func canPerform(_ command: ShrikeCommand) -> Bool {
        let edit = contentRoot.isEditModeActive
        let item = displayedItem
        let hasPixels = contentRoot.imageView.image != nil
        let last = list.count - 1
        // Open in External Editor N: the displayed item.
        if command.externalEditorSlot != nil { return item != nil && !edit }
        switch command {
        case .save, .saveAs:
            return edit
        case .revertToOriginal:
            return item != nil && !edit && isDisplayedEdited
        case .showInMaps:
            // Enabled only when the photo has GPS.
            return item != nil && !edit && displayedCoordinate != nil
        case .moveToTrash, .copyToFolder, .moveToFolder, .rename, .tags:
            return item != nil && !edit
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .toggleFlag:
            // Allowed on the error overlay too: the store keys by file.
            return item != nil
        case .revealInFinder, .copy, .copyPath, .share:
            return item != nil
        case .rotateLeft, .rotateRight, .rotate180:
            return hasPixels
        case .flipHorizontal, .flipVertical, .loupe, .editImage:
            return hasPixels && !edit
        case .zoomIn:
            return hasPixels && contentRoot.imageView.canZoomIn
        case .zoomOut:
            return hasPixels && contentRoot.imageView.canZoomOut
        case .zoomToFit, .actualSize, .zoom200, .zoom300,
             .zoomBestFit, .fitWidth, .fitHeight,
             .editCrop, .editRotate, .editResize, .editColor:
            return hasPixels
        case .levels, .autoContrast, .autoColor:
            // Viewer only; they land on Levels.
            return hasPixels
        case .resetEdits:
            return edit && contentRoot.editModeController.hasPendingEdits
        case .toggleFilmstrip:
            return !edit
        case .toggleInspector, .toggleHistogram, .toggleEditRail,
             .toggleFullScreen, .showInBrowser, .goToFolder:
            return true
        case .nextImage:
            return item.map { $0.listIndex < last } ?? false
        case .previousImage, .firstImage:
            return item.map { $0.listIndex > 0 } ?? false
        case .lastImage:
            return item.map { $0.listIndex != last } ?? false
        case .nextFolder, .previousFolder:
            return displayedFolder != nil
        case .slideshow:
            return !list.isEmpty && !edit
        case .batch:
            // The current list.
            return !list.isEmpty && !edit
        case .compare:
            // The shown photo and the next.
            return item != nil && list.count >= 2 && !edit
        case .print:
            // The shown photo.
            return item != nil && !edit
        case .pageSetup:
            return true
        default:
            // Browser-only and app commands never reach a viewer.
            return false
        }
    }

    public func perform(_ command: ShrikeCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .loupe:
            contentRoot.setLoupeActive(!contentRoot.isLoupeActive)
        case .editCrop: dispatch(.selectEditTool(.crop))
        case .editRotate: dispatch(.selectEditTool(.rotate))
        case .editResize: dispatch(.selectEditTool(.resize))
        case .editColor: dispatch(.selectEditTool(.color))
        case .levels: dispatch(.selectEditTool(.levels))
        case .autoContrast: dispatch(.autoLevels(.contrast))
        case .autoColor: dispatch(.autoLevels(.color))
        case .resetEdits: dispatch(.resetEdits)
        case .revertToOriginal: revertDisplayedToOriginal()
        case .showInMaps: showDisplayedInMaps()
        case .goToFolder: showGoToFolderSheet()
        case .pageSetup: PrintController.runPageSetup(on: self)
        default:
            let context: ShortcutContext = contentRoot.isEditModeActive ? .editMode : .viewer
            if let action = ViewerKeyMap.action(for: command, context: context) {
                dispatch(action)
            }
        }
    }

    /// Open in External Editor N: the whole displayed item (a RAW+JPEG
    /// pair follows the editor's Send RAW), or Settings for an empty slot.
    func openDisplayedInExternalEditor(slot: Int) {
        guard let group = displayedItem?.group else { return }
        externalEditorLaunch = ExternalEditors.open(groups: [group], slot: slot) { [weak self] content, action in
            self?.contentRoot.toast(content, action: action)
        }
    }

    // MARK: Show in Maps

    /// The displayed file's GPS, when it has been read and has one.
    var displayedCoordinate: PhotoInfo.Coordinate? {
        guard let url = displayedItem?.group.primary, let known = displayedLocation,
              known.url == url else { return nil }
        return known.coordinate
    }

    /// Reads the displayed file's GPS a moment after it is shown (never
    /// on the first-pixel path; fast flips skip the read), so Image ▸
    /// Show in Maps can be enabled or disabled.
    func scheduleLocationLookup() {
        locationLookup?.cancel()
        displayedLocation = nil
        guard let url = displayedItem?.group.primary, url.isFileURL else { return }
        locationLookup = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let coordinate = await ShowInMaps.readLocation(of: url)
            guard !Task.isCancelled, let self, self.displayedItem?.group.primary == url else { return }
            self.displayedLocation = KnownLocation(url: url, coordinate: coordinate)
        }
    }

    /// Menu, key or inspector link: Maps at the displayed photo, or the
    /// "no location" toast (the key works before the read has finished).
    func showDisplayedInMaps() {
        guard let url = displayedItem?.group.primary else { return }
        if let known = displayedLocation, known.url == url {
            openMaps(known.coordinate, file: url)
            return
        }
        locationLookup?.cancel()
        locationLookup = Task { [weak self] in
            let coordinate = await ShowInMaps.readLocation(of: url)
            guard let self, self.displayedItem?.group.primary == url else { return }
            self.displayedLocation = KnownLocation(url: url, coordinate: coordinate)
            self.openMaps(coordinate, file: url)
        }
    }

    private func openMaps(_ coordinate: PhotoInfo.Coordinate?, file: URL) {
        if let coordinate, ShowInMaps.open(coordinate, file: file) { return }
        contentRoot.toast(ToastContent(ShowInMaps.noLocation))
    }

    /// "Show …" / "Hide …" by the setting (a faded or
    /// squeezed-out rail still reads "Hide"); nil for other commands.
    func panelMenuTitle(_ command: ShrikeCommand) -> String? {
        switch command {
        case .toggleInspector: return inspectorMenuTitle()
        case .toggleEditRail: return contentRoot.isEditRailShown ? "Hide Edit Rail" : "Show Edit Rail"
        case .toggleFilmstrip: return contentRoot.isFilmstripShown ? "Hide Filmstrip" : "Show Filmstrip"
        case .toggleHistogram: return contentRoot.isHistogramShown ? "Hide Histogram" : "Show Histogram"
        default: return nil
        }
    }

    public func menuState(for command: ShrikeCommand) -> NSControl.StateValue {
        switch command {
        case .loupe: return contentRoot.isLoupeActive ? .on : .off
        case .toggleHistogram: return contentRoot.isHistogramShown ? .on : .off
        case .toggleEditRail: return contentRoot.isEditRailShown ? .on : .off
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .toggleFlag:
            return cullingMenuState(for: command)
        default: return .off
        }
    }
}

extension FileVerb {
    /// The verb of a Copy / Move to Folder command.
    init?(command: ShrikeCommand) {
        switch command {
        case .copyToFolder: self = .copy
        case .moveToFolder: self = .move
        default: return nil
        }
    }
}
