//
//  BrowserDragDrop.swift
//  ShrikeUI
//
//  Drag out of the grid, list and viewer filmstrip, the
//  Browser content drop (navigate and select) and the sidebar folder drop
//  (move / copy through `FileOps`). The rules are pure so tests can call
//  them without a real drag.
//

import AppKit
import ShrikeCore
import ShrikeIO

enum BrowserDropRules {

    // MARK: Drag out

    /// Outside Shrike: copy only, so a drag to Finder never moves the
    /// original.
    static let outsideMask: NSDragOperation = .copy
    /// Inside Shrike: copy or move. `.generic` is what AppKit leaves when ⌘
    /// is held, so ⌘ reads as move.
    static let insideMask: NSDragOperation = [.copy, .move, .generic]

    static func sourceMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? insideMask : outsideMask
    }

    /// The drag items for `groups`, one per group.
    @MainActor
    static func dragItems(_ groups: [ImageGroup], source: String) -> [NSPasteboardItem] {
        groups.map { PhotoPasteboard.dragItem(for: $0, source: source) }
    }

    // MARK: Browser content

    /// True when the content area takes the drag: file URLs that name a
    /// folder or an image (path only, no disk read), and not the window's
    /// own grid (no reordering).
    @MainActor
    static func acceptsContentDrop(_ pasteboard: NSPasteboard, ownSource: String) -> Bool {
        if PhotoPasteboard.draggedGroups(on: pasteboard).contains(where: { $0.source == ownSource }) {
            return false
        }
        return PhotoPasteboard.fileURLs(on: pasteboard).contains {
            $0.hasDirectoryPath || ImageFormat.isSupported($0)
        }
    }

    enum ContentDrop: Equatable {
        /// Navigate to the folder.
        case folder(URL)
        /// Navigate to the first image's folder and select the dropped
        /// images that are in it.
        case images(folder: URL, files: [URL])
    }

    /// What a content drop does. The first dropped item decides: a folder
    /// opens (first folder only); images open their folder. Reads the disk
    /// (is it a folder?): call it off the main thread.
    nonisolated static func resolveContentDrop(_ urls: [URL]) -> ContentDrop? {
        func isFolder(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        guard let first = urls.first else { return nil }
        if isFolder(first) { return .folder(first.standardizedFileURL) }
        let images = urls.filter { !isFolder($0) && ImageFormat.isSupported($0) }
        guard let firstImage = images.first else {
            return urls.first(where: isFolder).map { .folder($0.standardizedFileURL) }
        }
        let folder = firstImage.deletingLastPathComponent().standardizedFileURL
        let files = images.filter { $0.deletingLastPathComponent().standardizedFileURL == folder }
        return .images(folder: folder, files: files.map(\.standardizedFileURL))
    }

    // MARK: Sidebar folder row

    /// Finder rules: ⌥ = copy, ⌘ = move; otherwise the same volume moves
    /// and another volume copies. Limited to what the source allows; nil
    /// when it allows neither.
    static func sidebarVerb(modifiers: NSEvent.ModifierFlags, mask: NSDragOperation,
                            sameVolume: Bool) -> FileVerb? {
        let canCopy = mask.contains(.copy)
        let canMove = mask.contains(.move) || mask.contains(.generic)
        var verb: FileVerb
        if modifiers.contains(.option) {
            verb = .copy
        } else if modifiers.contains(.command) {
            verb = .move
        } else {
            verb = sameVolume ? .move : .copy
        }
        if verb == .move, !canMove { verb = .copy }
        if verb == .copy, !canCopy { return canMove ? .move : nil }
        return verb
    }

    static func operation(for verb: FileVerb) -> NSDragOperation {
        verb == .copy ? .copy : .move
    }

    /// The volume a path is on, by path prefix only ("/Volumes/SD" or
    /// "/"): no disk read while the pointer moves.
    nonisolated static func volumeRoot(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return "/Volumes/" + parts[2] }
        return "/"
    }

    /// The groups a sidebar drop moves or copies: the whole group when
    /// the drag came from Shrike (RAW, sidecars), else the dropped image
    /// files grouped among themselves. Folders and other files are left
    /// out. Path-only, no disk read.
    @MainActor
    static func droppedGroups(_ pasteboard: NSPasteboard) -> [ImageGroup] {
        let dragged = PhotoPasteboard.draggedGroups(on: pasteboard)
        if !dragged.isEmpty { return dragged.map(\.group) }
        let images = PhotoPasteboard.fileURLs(on: pasteboard).filter {
            !$0.hasDirectoryPath && ImageFormat.isFolderScanCandidate($0)
        }
        return ImageGrouping.group(images, options: ImageGroupingPreference.options)
    }
}

// MARK: - Content drop view

/// The Browser content area's background: it takes file drops and
/// draws the 2 pt accent border, inset 2 pt, radius 6, while a drag it
/// accepts is over it.
@MainActor
final class BrowserContentContainerView: TokenBackgroundView {

    /// True when the drag on `pasteboard` is accepted.
    var dropValidator: ((NSPasteboard) -> Bool)?
    /// Runs the drop; returns false to refuse it.
    var onDrop: ((NSPasteboard) -> Bool)?

    let dropHighlight = DropHighlightView()

    override init(fillColor: NSColor) {
        super.init(fillColor: fillColor)
        registerForDraggedTypes([.fileURL, PhotoPasteboard.groupIDsType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Keeps the border above the grid, list and empty state.
    func installHighlight() {
        dropHighlight.removeFromSuperview()
        dropHighlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropHighlight)
        NSLayoutConstraint.activate([
            dropHighlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            dropHighlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            dropHighlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dropHighlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropValidator?(sender.draggingPasteboard) == true else { return [] }
        // Navigating copies nothing: no "+" badge when the source allows it.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return mask.contains(.copy) ? .copy : []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = operation(sender)
        dropHighlight.isHidden = op.isEmpty
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = operation(sender)
        dropHighlight.isHidden = op.isEmpty
        return op
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHighlight.isHidden = true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHighlight.isHidden = true
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !operation(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        guard dropValidator?(sender.draggingPasteboard) == true else { return false }
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// The accent drop border. Never takes clicks.
@MainActor
final class DropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.controlAccentColor.resolvedCGColor(for: effectiveAppearance)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
