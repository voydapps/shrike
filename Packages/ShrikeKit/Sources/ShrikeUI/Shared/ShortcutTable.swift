//
//  ShortcutTable.swift
//  ShrikeUI
//
//  THE one shortcut table. It feeds:
//    * the viewer / browser / edit-mode keymaps (`ViewerKeyMap`,
//      `BrowserKeyMap` are lookups here),
//    * the menu bar's key equivalents (`ShrikeMainMenu`),
//    * tooltips,
//    * the Settings ▸ Shortcuts tab.
//  No other file hard-codes a key.
//
//  Lives in ShrikeUI (not ShrikeCore sketches) because its rows name
//  UI commands. It is the only key map: ShrikeCore keeps just the preset
//  setting (`ShortcutPreset`); its old `ShortcutRegistry` was removed.
//

import AppKit
import ShrikeCore

// MARK: - Commands

/// Every command a key, a menu item or a toolbar button can trigger.
public enum ShrikeCommand: String, CaseIterable, Sendable {
    // File
    case newBrowserWindow, open, openFolder, close, save, saveAs, revertToOriginal
    case rename, copyToFolder, moveToFolder, tags, addToFavorites, revealInFinder, share
    case openExternalEditor1, openExternalEditor2, openExternalEditor3, openExternalEditor4
    case openExternalEditor5, openExternalEditor6, openExternalEditor7, openExternalEditor8
    case openExternalEditor9
    case moveToTrash, pageSetup, print, exportContactSheet
    // Edit
    case undo, redo, cut, copy, copyPath, paste, selectAll, deselectAll, find
    // Window
    case minimize, welcome
    // View
    case viewAsGrid, viewAsFilmstrip, viewAsList
    case sortByName, sortByDateCaptured, sortByDateModified, sortBySize, sortByRating, sortByKind, sortByDimensions
    case filter, largerThumbnails, smallerThumbnails
    case zoomIn, zoomOut, zoomToFit, actualSize, zoom200, zoom300, zoomBestFit, fitWidth, fitHeight, loupe
    case toggleSidebar, toggleToolbar, customizeToolbar, toggleInspector, toggleFilmstrip, toggleHistogram
    case slideshow, compare, toggleFullScreen, unpinAllPanels
    // Image
    case rotateLeft, rotateRight, rotate180, flipHorizontal, flipVertical
    case rate0, rate1, rate2, rate3, rate4, rate5, toggleFlag
    case editImage, editCrop, editRotate, editResize, editColor, resetEdits
    case levels, autoContrast, autoColor, batch, showInMaps, toggleRAWFile
    // Go
    case nextImage, previousImage, firstImage, lastImage
    case nextFolder, previousFolder, enclosingFolder, back, forward, goToFolder, showInBrowser
    // Keys without a menu item
    case openSelection, escape, exitEditMode, editDone, editRotateStepLeft, editRotateStepRight
    // Compare window keys
    case compareNextAll, comparePreviousAll, compareFitAll, compareLock
    case compareFocus1, compareFocus2, compareFocus3, compareFocus4
    case compareFocusNext, compareFocusPrevious
    // App
    case settings, keyboardShortcuts

    /// Title Case name, as menus and tooltips show it.
    public var title: String {
        switch self {
        case .newBrowserWindow: return "New Browser Window"
        case .open: return "Open…"
        case .openFolder: return "Open Folder…"
        case .close: return "Close"
        case .save: return "Save"
        case .saveAs: return "Save As…"
        case .revertToOriginal: return "Revert to Original…"
        case .rename: return "Rename…"
        case .copyToFolder: return "Copy to Folder"
        case .moveToFolder: return "Move to Folder"
        case .tags: return "Tags…"
        case .addToFavorites: return "Add to Favorites"
        case .revealInFinder: return "Reveal in Finder"
        case .share: return "Share"
        case .openExternalEditor1, .openExternalEditor2, .openExternalEditor3,
             .openExternalEditor4, .openExternalEditor5, .openExternalEditor6,
             .openExternalEditor7, .openExternalEditor8, .openExternalEditor9:
            return "External Editor \((externalEditorSlot ?? 0) + 1)"
        case .moveToTrash: return "Move to Trash"
        case .pageSetup: return "Page Setup…"
        case .print: return "Print…"
        case .exportContactSheet: return "Export Contact Sheet…"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .copyPath: return "Copy Path"
        case .paste: return "Paste"
        case .minimize: return "Minimize"
        case .welcome: return "Welcome to Shrike"
        case .selectAll: return "Select All"
        case .deselectAll: return "Deselect All"
        case .find: return "Find…"
        case .viewAsGrid: return "as Grid"
        case .viewAsFilmstrip: return "as Filmstrip"
        case .viewAsList: return "as List"
        case .sortByName: return "Name"
        case .sortByDateCaptured: return "Date Captured"
        case .sortByDateModified: return "Date Modified"
        case .sortBySize: return "Size"
        case .sortByRating: return "Rating"
        case .sortByKind: return "Kind"
        case .sortByDimensions: return "Dimensions"
        case .filter: return "Filter…"
        case .largerThumbnails: return "Larger Thumbnails"
        case .smallerThumbnails: return "Smaller Thumbnails"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomToFit: return "Zoom to Fit"
        case .actualSize: return "Actual Size"
        case .zoom200: return "Zoom 200 %"
        case .zoom300: return "Zoom 300 %"
        case .zoomBestFit: return "Best Fit"
        case .fitWidth: return "Fit Width"
        case .fitHeight: return "Fit Height"
        case .loupe: return "Loupe"
        case .toggleSidebar: return "Show Sidebar"
        case .toggleToolbar: return "Show Toolbar"
        case .customizeToolbar: return "Customize Toolbar…"
        case .toggleInspector: return "Show Inspector"
        case .toggleFilmstrip: return "Show Filmstrip"
        case .toggleHistogram: return "Show Histogram"
        case .slideshow: return "Slideshow…"
        case .compare: return "Compare"
        case .toggleFullScreen: return "Enter Full Screen"
        case .unpinAllPanels: return "Unpin All Panels"
        case .toggleRAWFile: return "Show RAW File"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .rotate180: return "Rotate 180°"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .rate0: return "None"
        case .rate1: return "★"
        case .rate2: return "★★"
        case .rate3: return "★★★"
        case .rate4: return "★★★★"
        case .rate5: return "★★★★★"
        case .toggleFlag: return "Flag"
        case .editImage: return "Edit Image"
        case .editCrop: return "Crop"
        case .editRotate: return "Rotate"
        case .editResize: return "Resize"
        case .editColor: return "Color"
        case .resetEdits: return "Reset Edits"
        case .levels: return "Levels…"
        case .autoContrast: return "Auto Contrast"
        case .autoColor: return "Auto Color"
        case .batch: return "Batch…"
        case .showInMaps: return "Show in Maps"
        case .nextImage: return "Next Image"
        case .previousImage: return "Previous Image"
        case .firstImage: return "First Image"
        case .lastImage: return "Last Image"
        case .nextFolder: return "Next Folder"
        case .previousFolder: return "Previous Folder"
        case .enclosingFolder: return "Enclosing Folder"
        case .back: return "Back"
        case .forward: return "Forward"
        case .goToFolder: return "Go to Folder…"
        case .showInBrowser: return "Show in Browser"
        case .openSelection: return "Open in Viewer"
        case .escape: return "Exit Full Screen, Return to Browser, or Close"
        case .exitEditMode: return "Exit Edit Mode"
        case .editDone: return "Done"
        case .editRotateStepLeft: return "Rotate Step Left"
        case .editRotateStepRight: return "Rotate Step Right"
        case .compareNextAll: return "Next Image in All Panes"
        case .comparePreviousAll: return "Previous Image in All Panes"
        case .compareFitAll: return "Fit All"
        case .compareLock: return "Sync Zoom and Pan"
        case .compareFocus1: return "Focus Pane 1"
        case .compareFocus2: return "Focus Pane 2"
        case .compareFocus3: return "Focus Pane 3"
        case .compareFocus4: return "Focus Pane 4"
        case .compareFocusNext: return "Next Pane"
        case .compareFocusPrevious: return "Previous Pane"
        case .settings: return "Settings…"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        }
    }

    /// Open in External Editor 1 … 9, slot order.
    public static let externalEditorCommands: [ShrikeCommand] = [
        .openExternalEditor1, .openExternalEditor2, .openExternalEditor3,
        .openExternalEditor4, .openExternalEditor5, .openExternalEditor6,
        .openExternalEditor7, .openExternalEditor8, .openExternalEditor9,
    ]

    /// ⌘1 … ⌘4 in the Compare window, pane order.
    public static let compareFocusCommands: [ShrikeCommand] = [
        .compareFocus1, .compareFocus2, .compareFocus3, .compareFocus4,
    ]

    /// 0-based registry slot of an Open in External Editor command.
    public var externalEditorSlot: Int? {
        Self.externalEditorCommands.firstIndex(of: self)
    }
}

// MARK: - Keys

/// One key + modifiers. `key` is what `KeyCharacters.key(of:)`
/// reports, lowercased; special keys use the Cocoa function-key code
/// points.
public struct KeyBinding: Hashable, Sendable {
    public let key: String
    public let modifierRaw: UInt

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.modifierRaw = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRaw) }
    public var isModified: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }
    public var isFunctionKey: Bool { SpecialKey.isFunctionKey(key) }

    /// "⌥⌘R", "⌫", "F5", "Space".
    public var displayString: String {
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + SpecialKey.glyph(for: key)
    }

    /// The menu item's `keyEquivalent`, or nil for bare keys (menus
    /// only carry modified keys and F-keys).
    public var menuKeyEquivalent: String? {
        guard isModified || isFunctionKey else { return nil }
        if key == SpecialKey.backspace { return "\u{8}" }
        return key
    }
}

/// Cocoa function-key code points, from the AppKit constants.
public enum SpecialKey {
    static func char(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
    public static let left = char(NSLeftArrowFunctionKey)
    public static let right = char(NSRightArrowFunctionKey)
    public static let up = char(NSUpArrowFunctionKey)
    public static let down = char(NSDownArrowFunctionKey)
    public static let home = char(NSHomeFunctionKey)
    public static let end = char(NSEndFunctionKey)
    public static let pageUp = char(NSPageUpFunctionKey)
    public static let pageDown = char(NSPageDownFunctionKey)
    public static let forwardDelete = char(NSDeleteFunctionKey)
    public static let f2 = char(NSF2FunctionKey)
    public static let f5 = char(NSF5FunctionKey)
    public static let backspace = "\u{7F}"
    public static let returnKey = "\r"
    public static let enter = "\u{3}"
    public static let escape = "\u{1B}"
    public static let space = " "
    public static let tab = "\t"

    static func isFunctionKey(_ key: String) -> Bool { key == f2 || key == f5 }

    static func glyph(for key: String) -> String {
        switch key {
        case left: return "←"
        case right: return "→"
        case up: return "↑"
        case down: return "↓"
        case home: return "Home"
        case end: return "End"
        case pageUp: return "Page Up"
        case pageDown: return "Page Down"
        case forwardDelete: return "⌦"
        case backspace, "\u{8}": return "⌫"
        case f2: return "F2"
        case f5: return "F5"
        case returnKey: return "↩"
        case "\t": return "⇥"
        case enter: return "⌤"
        case escape: return "Esc"
        case space: return "Space"
        default: return key.uppercased()
        }
    }
}

// MARK: - Table

public struct ShortcutRow: Hashable, Sendable {
    public let command: ShrikeCommand
    public let context: ShortcutContext
    public let binding: KeyBinding
}

public enum ShortcutTable {

    // MARK: Lookups

    /// The command for a key press, or nil.
    public static func command(
        for snapshot: KeyEventSnapshot, context: ShortcutContext, preset: ShortcutPreset
    ) -> ShrikeCommand? {
        let binding = KeyBinding(snapshot.key, snapshot.flags)
        return index(for: preset)[context]?[binding]
    }

    /// Every binding of `command` in `context`, table order.
    public static func bindings(
        for command: ShrikeCommand, context: ShortcutContext, preset: ShortcutPreset
    ) -> [KeyBinding] {
        rows(for: preset).filter { $0.command == command && $0.context == context }.map(\.binding)
    }

    /// The key a menu item shows: the first modified binding in the
    /// viewer or browser context. Identical in both presets for every
    /// menu key, so the Mac preset is read.
    public static func menuBinding(for command: ShrikeCommand) -> KeyBinding? {
        menuIndex[command]
    }

    /// "⌫, ⌘⌫, ⌦" — the Shortcuts tab's key column.
    public static func displayString(
        for command: ShrikeCommand, context: ShortcutContext, preset: ShortcutPreset
    ) -> String {
        bindings(for: command, context: context, preset: preset).map(\.displayString).joined(separator: ", ")
    }

    /// "Previous Image  ·  ←". Title only when unbound.
    @MainActor
    public static func tooltip(for command: ShrikeCommand, context: ShortcutContext) -> String {
        guard let first = bindings(for: command, context: context, preset: livePreset).first else {
            return command.title
        }
        return "\(command.title)  ·  \(first.displayString)"
    }

    // MARK: Live preset

    @MainActor private static var cachedPreset: ShortcutPreset?
    @MainActor private static var observer: (any NSObjectProtocol)?

    /// `Prefs.shortcutPreset`, cached and refreshed when defaults change
    /// (the keymaps read the live preset on every key event).
    @MainActor
    public static var livePreset: ShortcutPreset {
        if let cachedPreset { return cachedPreset }
        let value = Prefs.shortcutPreset
        cachedPreset = value
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ShortcutTable.cachedPreset = nil }
            }
        }
        return value
    }

    // MARK: Storage

    public static func rows(for preset: ShortcutPreset) -> [ShortcutRow] {
        preset == .fastStoneCompat ? fastStoneRows : macRows
    }

    private static func index(for preset: ShortcutPreset) -> [ShortcutContext: [KeyBinding: ShrikeCommand]] {
        preset == .fastStoneCompat ? fastStoneIndex : macIndex
    }

    private static func buildIndex(_ rows: [ShortcutRow]) -> [ShortcutContext: [KeyBinding: ShrikeCommand]] {
        var out: [ShortcutContext: [KeyBinding: ShrikeCommand]] = [:]
        for row in rows where out[row.context]?[row.binding] == nil {
            out[row.context, default: [:]][row.binding] = row.command
        }
        return out
    }

    private static let macRows = makeRows(fastStone: false)
    private static let fastStoneRows = makeRows(fastStone: true)
    private static let macIndex = buildIndex(macRows)
    private static let fastStoneIndex = buildIndex(fastStoneRows)
    private static let menuIndex: [ShrikeCommand: KeyBinding] = {
        var out: [ShrikeCommand: KeyBinding] = [:]
        for row in macRows where (row.context == .viewer || row.context == .browser)
            && out[row.command] == nil && row.binding.menuKeyEquivalent != nil {
            out[row.command] = row.binding
        }
        // App-level commands have no context.
        out[.newBrowserWindow] = KeyBinding("n", .command)
        out[.open] = KeyBinding("o", .command)
        out[.openFolder] = KeyBinding("o", [.command, .shift])
        out[.close] = KeyBinding("w", .command)
        out[.cut] = KeyBinding("x", .command)
        out[.paste] = KeyBinding("v", .command)
        out[.minimize] = KeyBinding("m", .command)
        out[.settings] = KeyBinding(",", .command)
        out[.keyboardShortcuts] = KeyBinding("/", .command)
        return out
    }()

    // swiftlint:disable:next function_body_length
    private static func makeRows(fastStone fs: Bool) -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        func add(_ c: ShrikeCommand, _ ctx: ShortcutContext, _ keys: KeyBinding...) {
            for k in keys { rows.append(ShortcutRow(command: c, context: ctx, binding: k)) }
        }
        func k(_ key: String, _ m: NSEvent.ModifierFlags = []) -> KeyBinding { KeyBinding(key, m) }
        // ⌥⌘1 … ⌥⌘9 in both presets;
        // FastStone adds E / ⌥2 … ⌥9.
        func addExternalEditors(_ ctx: ShortcutContext) {
            for (slot, command) in ShrikeCommand.externalEditorCommands.enumerated() {
                add(command, ctx, k("\(slot + 1)", [.command, .option]))
                if fs { add(command, ctx, slot == 0 ? k("e") : k("\(slot + 1)", .option)) }
            }
        }
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        let cmdOpt: NSEvent.ModifierFlags = [.command, .option]
        let ctrlCmd: NSEvent.ModifierFlags = [.control, .command]
        let ctrlOptCmd: NSEvent.ModifierFlags = [.control, .option, .command]
        let K = SpecialKey.self

        // ---------------- Viewer ----------------
        let v = ShortcutContext.viewer
        add(.nextImage, v, k(K.right), k(K.space), k(K.pageDown))
        // ⇧Space = previous.
        add(.previousImage, v, k(K.left), k(K.pageUp), k(K.space, .shift))
        if fs { add(.previousImage, v, k(K.backspace)) }
        add(.firstImage, v, k(K.home))
        add(.lastImage, v, k(K.end))
        add(.nextFolder, v, k(K.right, cmdOpt))
        add(.previousFolder, v, k(K.left, cmdOpt))
        add(.showInBrowser, v, k("b", cmd), k(K.up, cmd))
        add(.escape, v, k(K.escape))
        add(.zoomIn, v, k("+", cmd), k("=", cmd), k("+", cmdShift))
        add(.zoomOut, v, k("-", cmd))
        add(.zoomToFit, v, k("0", cmd))
        add(.actualSize, v, k("1", cmd), k("a"), k("/"))
        add(.zoom200, v, k("2", cmd))
        add(.zoom300, v, k("3", cmd))
        add(.zoomBestFit, v, k("b"), k("*"))
        add(.fitWidth, v, k("w", .shift))
        add(.fitHeight, v, k("h", .shift))
        add(.loupe, v, k("z"))
        add(.rotateLeft, v, k("l", cmd))
        add(.rotateRight, v, k("r", cmd))
        add(.rotate180, v, k("r", cmdShift))
        add(.flipHorizontal, v, k("f", cmdShift), k("h"))
        add(.flipVertical, v, k("v", cmdShift), k("v"))
        let ratings: [ShrikeCommand] = [.rate0, .rate1, .rate2, .rate3, .rate4, .rate5]
        for (n, c) in ratings.enumerated() { add(c, v, fs ? k("\(n)", .control) : k("\(n)")) }
        add(.toggleFlag, v, k("q"), k("\\"))
        add(.tags, v, k("t"))
        add(.copyToFolder, v, k("c"))
        add(.moveToFolder, v, k("m"))
        add(.rename, v, k(K.f2))
        add(.copy, v, k("c", cmd))
        add(.copyPath, v, k("c", cmdOpt))
        add(.revealInFinder, v, k("r", cmdOpt))
        if fs { add(.revealInFinder, v, k("w")) }
        if fs {
            add(.moveToTrash, v, k(K.forwardDelete), k(K.backspace, cmd))
        } else {
            add(.moveToTrash, v, k(K.backspace, cmd))
        }
        add(.undo, v, k("z", cmd))
        add(.redo, v, k("z", cmdShift))
        add(.toggleInspector, v, k("i", cmd))
        add(.toggleFilmstrip, v, k("k", cmd))
        add(.toggleHistogram, v, k("j", cmdShift))
        // ⌃H toggles the histogram in both presets.
        add(.toggleHistogram, v, k("h", .control))
        // ⌥R: view-only switch between a pair's primary and its RAW.
        add(.toggleRAWFile, v, k("r", .option))
        add(.toggleFullScreen, v, k("f", ctrlCmd))
        if fs { add(.toggleFullScreen, v, k("f"), k(K.returnKey), k(K.enter)) }
        if fs { add(.actualSize, v, k("1")); add(.zoom200, v, k("2")); add(.zoom300, v, k("3")); add(.zoomToFit, v, k("0")) }
        if fs { add(.rotateLeft, v, k("l")); add(.rotateRight, v, k("r")) }
        add(.slideshow, v, k(K.f5))
        if fs { add(.slideshow, v, k("s")) }
        add(.editImage, v, k("e", cmd))
        if !fs { add(.editImage, v, k("e")) }
        add(.save, v, k("s", cmd))
        add(.saveAs, v, k("s", cmdShift))
        add(.toggleToolbar, v, k("t", cmdOpt))
        add(.goToFolder, v, k("g", cmdShift))
        // Levels and its autos.
        add(.levels, v, fs ? k("l", .control) : k("l", cmdShift))
        if fs { add(.levels, v, k("l", cmdShift)) }
        add(.autoContrast, v, k("l", [.command, .shift, .option]))
        add(.autoColor, v, k("b", cmdShift))
        add(.compare, v, k("4", cmd))
        if fs { add(.compare, v, k("p")) }
        add(.batch, v, k("b", cmdOpt))
        add(.print, v, k("p", cmd))
        if fs { add(.print, v, k("p", .option)) }
        add(.pageSetup, v, k("p", cmdShift))
        add(.showInMaps, v, k("m", ctrlCmd)); if fs { add(.showInMaps, v, k("m", [.control, .shift])) }
        addExternalEditors(v)

        // ---------------- Edit mode ----------------
        let e = ShortcutContext.editMode
        add(.exitEditMode, e, k(K.escape))
        // The navigation keys work in edit
        // mode and ask first (the exit alert) when there are changes.
        // The crop frame, when it has keyboard focus, takes the arrows
        // itself (1 px nudge, ⇧ 10 px) before they get here.
        add(.nextImage, e, k(K.right), k(K.space), k(K.pageDown))
        add(.previousImage, e, k(K.left), k(K.pageUp), k(K.space, .shift))
        add(.firstImage, e, k(K.home))
        add(.lastImage, e, k(K.end))
        add(.nextFolder, e, k(K.right, cmdOpt))
        add(.previousFolder, e, k(K.left, cmdOpt))
        // Return = Done (apply the tool, then save).
        add(.editDone, e, k(K.returnKey), k(K.enter))
        add(.undo, e, k("z", cmd))
        add(.redo, e, k("z", cmdShift))
        add(.save, e, k("s", cmd))
        add(.saveAs, e, k("s", cmdShift))
        add(.editCrop, e, k("c"))
        add(.editRotate, e, k("r"))
        add(.editResize, e, k("s"))
        add(.editColor, e, k("j"))
        add(.editRotateStepLeft, e, k("["))
        add(.editRotateStepRight, e, k("]"))
        add(.rotateLeft, e, k("l", cmd))
        add(.rotateRight, e, k("r", cmd))
        add(.rotate180, e, k("r", cmdShift))
        add(.toggleFilmstrip, e, k("k", cmd))
        add(.toggleHistogram, e, k("j", cmdShift))
        add(.zoomIn, e, k("+", cmd), k("=", cmd))
        add(.zoomOut, e, k("-", cmd))
        add(.zoomToFit, e, k("0", cmd))
        add(.actualSize, e, k("1", cmd))

        // ---------------- Browser ----------------
        let b = ShortcutContext.browser
        add(.openSelection, b, k(K.returnKey), k(K.enter), k(K.down, cmd), k(K.space))
        add(.showInBrowser, b, k("b", cmd))
        add(.enclosingFolder, b, k(K.up, cmd))
        add(.back, b, k("[", cmd))
        add(.forward, b, k("]", cmd))
        if fs {
            add(.moveToTrash, b, k(K.forwardDelete), k(K.backspace, cmd))
        } else {
            add(.moveToTrash, b, k(K.backspace, cmd))
        }
        for (n, c) in ratings.enumerated() { add(c, b, fs ? k("\(n)", .control) : k("\(n)")) }
        add(.toggleFlag, b, k("q"), k("\\"))
        add(.tags, b, k("t"))
        add(.copyToFolder, b, k("c"))
        add(.moveToFolder, b, k("m"))
        add(.rename, b, k(K.f2))
        add(.selectAll, b, k("a", cmd))
        add(.deselectAll, b, k("a", cmdShift))
        add(.find, b, k("f", cmd))
        add(.filter, b, k("f", cmdOpt))
        add(.copy, b, k("c", cmd))
        add(.copyPath, b, k("c", cmdOpt))
        add(.revealInFinder, b, k("r", cmdOpt))
        add(.viewAsGrid, b, k("1", cmd))
        add(.viewAsFilmstrip, b, k("2", cmd))
        add(.viewAsList, b, k("3", cmd))
        let sorts: [ShrikeCommand] = [.sortByName, .sortByDateCaptured, .sortByDateModified,
                                     .sortBySize, .sortByRating, .sortByKind, .sortByDimensions]
        for (n, c) in sorts.enumerated() { add(c, b, k("\(n + 1)", ctrlOptCmd)) }
        add(.largerThumbnails, b, k("+", cmd), k("=", cmd), k("+", cmdShift))
        add(.smallerThumbnails, b, k("-", cmd))
        add(.toggleSidebar, b, k("s", ctrlCmd))
        add(.toggleToolbar, b, k("t", cmdOpt))
        add(.toggleInspector, b, k("i", cmd))
        add(.addToFavorites, b, k("d", cmd))
        add(.goToFolder, b, k("g", cmdShift))
        add(.undo, b, k("z", cmd))
        add(.redo, b, k("z", cmdShift))
        add(.rotateLeft, b, k("l", cmd))
        add(.rotateRight, b, k("r", cmd))
        add(.rotate180, b, k("r", cmdShift))
        add(.flipHorizontal, b, k("f", cmdShift))
        add(.flipVertical, b, k("v", cmdShift))
        add(.nextFolder, b, k(K.right, cmdOpt))
        add(.previousFolder, b, k(K.left, cmdOpt))
        add(.slideshow, b, k(K.f5))
        if fs { add(.slideshow, b, k("s")) }
        add(.compare, b, k("4", cmd))
        if fs { add(.compare, b, k("p")) }
        add(.batch, b, k("b", cmdOpt))
        add(.print, b, k("p", cmd))
        if fs { add(.print, b, k("p", .option)) }
        add(.pageSetup, b, k("p", cmdShift))
        add(.showInMaps, b, k("m", ctrlCmd)); if fs { add(.showInMaps, b, k("m", [.control, .shift])) }
        // ⌥R: view-only switch between the selected pair's JPEG and RAW.
        add(.toggleRAWFile, b, k("r", .option))
        addExternalEditors(b)

        // ---------------- Compare ----------------
        // ⇧ with a rating or flag key applies it to every pane; that is a
        // lookup rule (`CompareKeyMap`), not extra rows.
        let c = ShortcutContext.compare
        add(.previousImage, c, k(K.left))
        add(.nextImage, c, k(K.right))
        add(.comparePreviousAll, c, k(K.left, .shift))
        add(.compareNextAll, c, k(K.right, .shift))
        add(.zoomIn, c, k("+"), k("="), k("+", .shift))
        add(.zoomOut, c, k("-"))
        add(.compareFitAll, c, k("0"))
        for (n, command) in ratings.enumerated() where n > 0 {
            add(command, c, fs ? k("\(n)", .control) : k("\(n)"))
        }
        if fs { add(.rate0, c, k("0", .control)) }
        add(.toggleFlag, c, k("q"), k("\\"))
        add(.rotateLeft, c, k("l", cmd))
        add(.rotateRight, c, k("r", cmd))
        if fs { add(.rotateLeft, c, k("l")); add(.rotateRight, c, k("r")) }
        add(.compareLock, c, k("s"))
        if fs {
            add(.moveToTrash, c, k(K.forwardDelete), k(K.backspace, cmd))
        } else {
            add(.moveToTrash, c, k(K.backspace, cmd))
        }
        for (n, command) in ShrikeCommand.compareFocusCommands.enumerated() { add(command, c, k("\(n + 1)", cmd)) }
        add(.compareFocusNext, c, k(K.tab))
        add(.compareFocusPrevious, c, k(K.tab, .shift))
        add(.undo, c, k("z", cmd))
        add(.redo, c, k("z", cmdShift))
        add(.escape, c, k(K.escape))
        return rows
    }
}
