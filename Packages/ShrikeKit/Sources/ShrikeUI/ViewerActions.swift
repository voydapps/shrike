//
//  ViewerActions.swift
//  ShrikeUI
//
//  Viewer-scoped action catalog + Mac-native keymap for the viewer window.
//
//  Keys come from `ShortcutTable` (the one table); this file
//  maps its commands to viewer actions.
//

import Foundation
import AppKit
import ShrikeCore

/// Every user-triggerable action the viewer recognises today. Grows with scope.
public enum ViewerAction: Sendable, Hashable {
    // Navigation
    case nextImage
    case prevImage
    case firstImage
    case lastImage
    case prevFolder
    case nextFolder
    /// ⌘B / ⌘↑: back to (or open) the Browser.
    case showInBrowser

    // Zoom
    case zoomActualSize
    case zoomBestFit
    case zoom100
    case zoom200
    case zoom300
    case zoom1000
    case zoomIn
    case zoomOut
    case fitWidth
    case fitHeight
    case fitToWindow

    // Rotate / flip
    case rotateLeft
    case rotateRight
    case rotate180
    case flipHorizontal
    case flipVertical

    // View / panels
    case toggleFullscreen
    case exitFullscreen
    case toggleInspector
    case toggleExif
    case toggleFilmstrip
    case toggleHistogram
    case toggleMagnifierHold(Bool)   // true: pressed, false: released

    // Rating / flag / tags
    case rate(Int)         // 0-5
    case toggleFlag
    case editTags

    // File ops
    case copyToFolder
    case moveToFolder
    case copyPath
    case copyBitmap
    case paste
    case cut
    case deleteToTrash
    case rename
    case revealInFinder
    case undo
    case redo

    // Tools
    /// Open in External Editor N (0-based registry slot).
    case openExternalEditor(slot: Int)
    case openEditMode
    case slideshow
    case batch
    /// ⌘4 / FastStone `P`: the Compare window.
    case compare
    /// ⌘P / FastStone ⌥P: print the shown photo.
    case print
    case crop
    case resize
    case colorAdjust
    case showInMaps
    /// Share the current image via NSSharingServicePicker.
    /// Toolbar button presents the picker anchored to its own frame via
    /// `ViewerToolbar.showShare(from:)`.
    case share
    /// Reset the pending edit recipe to identity. Shown
    /// on the edit rail alongside the three tool buttons. Button is
    /// disabled when `editModeController.hasPendingEdits == false`.
    case resetEdits
    /// Toggle the persistent docked edit rail in windowed mode, or the
    /// fullscreen pin state in fullscreen mode. `⌘⇧E`.
    case toggleEditRail

    // Chord starters
    case beginCopyChord
    case beginMoveChord
    /// Begin a `⌘K` edit-tool chord. Waits for the next keypress
    /// (c/r/s/j → Crop/Rotate/Resize/Color).
    case beginEditToolChord
    /// Second key of a `C` / `M` chord.
    case fileToFolder(FileVerb, DestinationChoice)
    /// Esc during a chord: cancel it, nothing else.
    case cancelChord

    // MARK: - Edit mode

    /// Enter edit mode. Lands on the last-used tool, or Crop if none.
    case enterEditMode
    /// Attempt to exit edit mode. Shows the save alert when the recipe
    /// is dirty.
    case exitEditMode
    /// Select a specific tool inside edit mode.
    case selectEditTool(EditTool)
    /// Done (Return): apply the active tool, then save by
    /// the ⌘S rules, or leave when nothing changed.
    case applyCurrentEditTool
    /// Reset the active tool's parameters to identity (no recipe change).
    case resetCurrentEditTool
    /// Undo the last op in the recipe.
    case undoEdit
    /// Redo the last undone op.
    case redoEdit
    /// `⌘S` — save over current file.
    case saveEditedFile
    /// `⌘⇧S` — Save As… panel.
    case saveEditedFileAs
    /// Image ▸ Auto Contrast / Auto Color: lands on the
    /// Levels tool (entering edit mode first when needed), then applies.
    case autoLevels(LevelsAutoKind)
    /// Lossless JPEG rotate. Non-edit-mode action. Quarters: +1 CW, -1 CCW,
    /// +2/-2 180°. Falls through to recipe-path when the source isn't a
    /// JPEG or lossless rotator is stubbed.
    case rotateLossless(quarters: Int)
    /// Append a snapped 90° rotation to the active edit recipe. Bound to
    /// `[` / `]` in edit mode.
    case editRotate90(quarters: Int)
}

/// Active tool inside edit mode. Five tools specced; Lossless JPEG
/// Rotate is not an edit-mode tool (it's a one-shot menu/keyboard action).
public enum EditTool: String, Sendable, Hashable, CaseIterable {
    case crop
    case rotate
    case resize
    case color
    /// Levels.
    case levels
}

/// The two one-click Levels fixes.
public enum LevelsAutoKind: Sendable, Hashable {
    /// Stretches the combined R+G+B histogram in the RGB channel.
    case contrast
    /// Stretches R, G and B each on its own (removes a tint).
    case color

    /// Menu / undo name: "Auto Contrast", "Auto Color".
    public var title: String {
        switch self {
        case .contrast: return "Auto Contrast"
        case .color: return "Auto Color"
        }
    }
}

/// Lightweight snapshot of an `NSEvent` so test code can build events without
/// constructing a real NSEvent (which requires a running event loop).
public struct KeyEventSnapshot: Sendable, Hashable {
    public let key: String               // lowercased `KeyCharacters.key(of:)`
    public let modifiers: UInt           // NSEvent.ModifierFlags rawValue (stripped of deviceIndependent)
    public let isKeyUp: Bool
    public let keyCode: UInt16

    public init(key: String, modifiers: NSEvent.ModifierFlags = [], isKeyUp: Bool = false, keyCode: UInt16 = 0) {
        self.key = key
        self.modifiers = modifiers.rawValue
        self.isKeyUp = isKeyUp
        self.keyCode = keyCode
    }

    public var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// The typed key via `KeyCharacters` (a non-Latin layout falls back
    /// to the ASCII-capable layout's character for the same key).
    @MainActor
    public static func from(_ event: NSEvent, isKeyUp: Bool) -> KeyEventSnapshot {
        let chars = KeyCharacters.key(of: event).lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyEventSnapshot(
            key: chars,
            modifiers: flags,
            isKeyUp: isKeyUp,
            keyCode: event.keyCode
        )
    }
}

public enum ShortcutContext: Sendable, Hashable {
    case viewer
    case browser
    case compare
    case slideshow
    case editMode
}

/// Viewer + edit-mode resolver: a lookup in `ShortcutTable`
/// plus the `⌘K` / `C` / `M` chord follow-ups. Pure — safe for
/// unit tests.
public enum ViewerKeyMap {

    public static func action(
        for snapshot: KeyEventSnapshot,
        context: ShortcutContext,
        preset: ShortcutPreset = .macNative,
        chordPrefix: Character? = nil
    ) -> ViewerAction? {
        guard context == .viewer || context == .editMode else { return nil }
        if let prefix = chordPrefix {
            return resolveChordFollowup(prefix: prefix, snapshot: snapshot)
        }
        guard let command = ShortcutTable.command(for: snapshot, context: context, preset: preset) else {
            return nil
        }
        return action(for: command, context: context)
    }

    /// The viewer action a table command runs. nil = no key action (a
    /// menu-only command).
    public static func action(for command: ShrikeCommand, context: ShortcutContext) -> ViewerAction? {
        if context == .editMode {
            switch command {
            case .exitEditMode: return .exitEditMode
            case .editDone: return .applyCurrentEditTool
            case .undo: return .undoEdit
            case .redo: return .redoEdit
            case .editRotateStepLeft: return .editRotate90(quarters: -1)
            case .editRotateStepRight: return .editRotate90(quarters: 1)
            // In edit mode the rotate keys turn the recipe,
            // never the file; flips are disabled.
            case .rotateLeft: return .editRotate90(quarters: -1)
            case .rotateRight: return .editRotate90(quarters: 1)
            case .rotate180: return .editRotate90(quarters: 2)
            case .flipHorizontal, .flipVertical: return nil
            case .editCrop: return .selectEditTool(.crop)
            case .editRotate: return .selectEditTool(.rotate)
            case .editResize: return .selectEditTool(.resize)
            case .editColor: return .selectEditTool(.color)
            case .levels: return .selectEditTool(.levels)
            default: break
            }
        }
        switch command {
        case .nextImage: return .nextImage
        case .previousImage: return .prevImage
        case .firstImage: return .firstImage
        case .lastImage: return .lastImage
        case .nextFolder: return .nextFolder
        case .previousFolder: return .prevFolder
        case .showInBrowser, .enclosingFolder: return .showInBrowser
        case .escape: return .exitFullscreen
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .zoomToFit: return .fitToWindow
        case .actualSize: return .zoomActualSize
        case .zoom200: return .zoom200
        case .zoom300: return .zoom300
        case .zoomBestFit: return .zoomBestFit
        case .fitWidth: return .fitWidth
        case .fitHeight: return .fitHeight
        case .loupe: return .toggleMagnifierHold(true)
        case .rotateLeft: return .rotateLossless(quarters: -1)
        case .rotateRight: return .rotateLossless(quarters: 1)
        case .rotate180: return .rotateLossless(quarters: 2)
        case .flipHorizontal: return .flipHorizontal
        case .flipVertical: return .flipVertical
        case .rate0: return .rate(0)
        case .rate1: return .rate(1)
        case .rate2: return .rate(2)
        case .rate3: return .rate(3)
        case .rate4: return .rate(4)
        case .rate5: return .rate(5)
        case .toggleFlag: return .toggleFlag
        case .tags: return .editTags
        case .copyToFolder: return .beginCopyChord
        case .moveToFolder: return .beginMoveChord
        case .rename: return .rename
        case .copy: return .copyBitmap
        case .copyPath: return .copyPath
        case .revealInFinder: return .revealInFinder
        case .moveToTrash: return .deleteToTrash
        case .undo: return .undo
        case .redo: return .redo
        case .toggleInspector: return .toggleInspector
        case .toggleFilmstrip: return .toggleFilmstrip
        case .toggleHistogram: return .toggleHistogram
        case .toggleEditRail: return .toggleEditRail
        case .toggleFullScreen: return .toggleFullscreen
        case .slideshow: return .slideshow
        case .batch: return .batch
        case .compare: return .compare
        case .print: return .print
        case .editImage: return .enterEditMode
        case .save: return .saveEditedFile
        case .saveAs: return .saveEditedFileAs
        case .showInMaps: return .showInMaps
        case .levels: return .selectEditTool(.levels)
        case .autoContrast: return .autoLevels(.contrast)
        case .autoColor: return .autoLevels(.color)
        default:
            if let slot = command.externalEditorSlot { return .openExternalEditor(slot: slot) }
            return nil
        }
    }

    private static func resolveChordFollowup(
        prefix: Character, snapshot: KeyEventSnapshot
    ) -> ViewerAction? {
        // The `⌘K C/R/S/J` chord is gone: ⌘K is only
        // Show Filmstrip; tools are the bare C / R / S / J in edit mode.
        // `C` / `M` follow-ups. nil = cancel the chord and handle
        // the key normally.
        switch FileChord.followup(prefix: prefix, snapshot: snapshot) {
        case .run(let verb, let choice)?: return .fileToFolder(verb, choice)
        case .cancel?: return .cancelChord
        case .passThrough?, nil: return nil
        }
    }
}

@MainActor
public final class NavTaskCoalescer {

    private var currentTask: Task<Void, Never>?
    public private(set) var replacedCount: Int = 0
    private var runGeneration = 0

    /// True when the task started last has finished (or none was started
    /// or it was cancelled). Tests wait on this to know that, for example,
    /// a window's opening decode has landed.
    public private(set) var isIdle = true

    public init() {}

    /// Start a new coalesced task, cancelling any previous one. Returns the
    /// new task so callers that want to `await` it in tests can.
    @discardableResult
    public func run(
        _ body: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        if let previous = currentTask {
            previous.cancel()
            replacedCount += 1
        }
        runGeneration += 1
        let generation = runGeneration
        isIdle = false
        let task = Task { @MainActor in
            await body()
            if generation == runGeneration { isIdle = true }
        }
        currentTask = task
        return task
    }

    /// Cancel the current task (if any). Safe to call multiple times.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        runGeneration += 1
        isIdle = true
    }

    /// Test-only accessor — `true` if the currently-held task was cancelled
    /// (e.g. by a later `run` call). Used by the coalescing regression tests.
    public var isCurrentTaskCancelled: Bool {
        currentTask?.isCancelled ?? false
    }
}
