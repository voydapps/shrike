//
//  Prefs.swift
//  ShrikeCore
//
//  Typed `UserDefaults` wrapper. Every pref Shrike reads is declared here so
//  the Preferences SwiftUI scene and the rest of the app share one schema.
//
//  Threading — `UserDefaults` is thread-safe via Foundation's internal lock
//  but is not marked `Sendable`. We annotate the shared suite with
//  `nonisolated(unsafe)` to document that we rely on Foundation's locking,
//  not Swift concurrency guarantees. Reads / writes may originate from any
//  actor (the UI, background decode jobs, Preferences window).
//

import Foundation

// MARK: - External editor slots

/// Single entry in the user-configurable external-editor registry.
/// Encoded as JSON into `UserDefaults`.
public struct ExternalEditorSlot: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    /// Either a bundle identifier (e.g. `com.adobe.Photoshop`) or a POSIX
    /// path to an `.app` bundle. `NSWorkspace` handles both.
    public let bundleIdentifierOrPath: String
    /// Optional keyboard shortcut that routes to this editor when pressed
    /// in the viewer (`⌥⌘2` through `⌥⌘9`, etc).
    public let shortcut: ShortcutBinding?

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifierOrPath: String,
        shortcut: ShortcutBinding? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifierOrPath = bundleIdentifierOrPath
        self.shortcut = shortcut
    }
}

// MARK: - Prefs namespace

/// Static namespace. Every property reads / writes `ShrikeDefaults.store`
/// (`UserDefaults.standard` in the app, a per-process suite under tests).
/// Codable values (`ShortcutPreset`, `[ExternalEditorSlot]`) are JSON-encoded
/// into a `Data` blob under their key.
public enum Prefs {

    // UserDefaults isn't Sendable in the SDK; Foundation locks internally.
    nonisolated(unsafe) private static let defaults: UserDefaults = ShrikeDefaults.store

    // Underlying keys. Centralised here so migrations can find them. Also the
    // enumeration source of truth for `resetAll()` below — every typed prop
    // below must list its key via `Key.allKeys` so `resetAll()` wipes it.
    internal enum Key {
        static let shortcutPreset             = "shrike.shortcuts.preset"
        static let thumbnailSizePt            = "shrike.thumbnails.sizePt"
        static let browserSortKey             = "shrike.browser.sortKey"
        static let browserSortAscending       = "shrike.browser.sortAscending"
        static let browserViewMode            = "shrike.browser.viewMode"
        static let scrollWheelNavigates       = "shrike.input.scrollWheelNavigates"
        static let externalEditors            = "shrike.editors.slots"
        static let recentFoldersLimit         = "shrike.recent.foldersLimit"
        static let showHiddenFiles            = "shrike.browser.showHiddenFiles"
        static let cacheDiskCeilingBytes      = "shrike.cache.diskCeilingBytes"
        static let viewerBackgroundAlwaysBlack = "shrike.viewer.backgroundAlwaysBlack"
        static let viewerToolbarAutoHide = "shrike.viewer.toolbarAutoHide"
        static let viewerInspectorVisibleWindowed = "shrike.viewer.inspectorVisibleWindowed"
        static let maxDisplayLongEdge         = "shrike.viewer.maxDisplayLongEdge"
        static let viewerPositionOverlayAutoHides = "shrike.viewer.positionOverlayAutoHides"
        /// Remembers the last-selected tab in the Preferences window. Stored
        /// as the String rawValue of `PreferencesTab`. Surfaced via
        /// `Prefs.selectedPreferencesTabRaw` to keep the typed enum in the UI
        /// layer (ShrikeUI) where it belongs.
        static let selectedPreferencesTab     = "shrike.prefs.selectedTab"

        // MARK: Filmstrip + fullscreen chrome
        static let filmstripVisibleInWindowed   = "shrike.viewer.filmstrip.visibleInWindowed"
        static let filmstripHeightPt            = "shrike.viewer.filmstrip.heightPt"
        static let filmstripPinnedFullscreen    = "shrike.viewer.filmstrip.pinnedFullscreen"
        static let editRailPinnedFullscreen     = "shrike.viewer.editRail.pinnedFullscreen"
        static let exifPanelPinnedFullscreen    = "shrike.viewer.exifPanel.pinnedFullscreen"
        /// The rail shown in a window (View › Show Edit Rail).
        static let editRailVisibleInWindowed    = "shrike.viewer.editRail.visibleInWindowed"
        /// The one-time "rail on" switch has run.
        static let editRailDefaultOnApplied     = "shrike.viewer.editRail.defaultOnApplied"
        /// Hidden pref — not surfaced in Preferences UI. `defaults write` only.
        static let chromeFadeOutDelayMs         = "shrike.viewer.chromeFadeOutDelayMs"

        // MARK: Edit
        static let editJPEGQualityDefault                = "shrike.edit.jpegQualityDefault"
        static let editHEICQualityDefault                = "shrike.edit.heicQualityDefault"
        static let editPreserveEXIFOnSave                = "shrike.edit.preserveEXIFOnSave"
        static let editStripGPSOnSave                    = "shrike.edit.stripGPSOnSave"
        static let editRotateUseLosslessForJPEG          = "shrike.edit.rotateUseLosslessForJPEG"
        static let editAutoCropOnFreeRotate              = "shrike.edit.autoCropOnFreeRotate"
        static let editColorAdjustPreviewFullResAlways   = "shrike.edit.colorAdjustPreviewFullResAlways"
        static let editTrashDirOverride                  = "shrike.edit.trashDirOverride"

        // File safety (backups before overwrite, metadata mirroring).
        static let backupRetentionDays                   = "shrike.backups.retentionDays"
        static let metadataWriteFileAttributes           = "shrike.metadata.writeFileAttributes"
        static let backupMaxBytes                        = "shrike.backups.maxBytes"

        // Histogram, slideshow, favorites.
        static let viewerHistogramVisible = "shrike.viewer.histogramVisible"
        static let viewerHistogramMode    = "shrike.viewer.histogramMode"
        static let slideshowIntervalSec   = "shrike.slideshow.intervalSec"
        static let slideshowTransition    = "shrike.slideshow.transition"
        static let slideshowRandom        = "shrike.slideshow.random"
        static let slideshowFill          = "shrike.slideshow.fill"
        static let slideshowLoop          = "shrike.slideshow.loop"
        static let browserFavorites       = "shrike.browser.favorites"

        /// Every `shrike.*` user-preference key. `resetAll()` walks this list.
        /// Add new keys here when adding new typed props.
        static let allKeys: [String] = [
            shortcutPreset,
            thumbnailSizePt,
            browserSortKey,
            browserSortAscending,
            browserViewMode,
            scrollWheelNavigates,
            externalEditors,
            recentFoldersLimit,
            showHiddenFiles,
            cacheDiskCeilingBytes,
            viewerBackgroundAlwaysBlack,
            maxDisplayLongEdge,
            viewerPositionOverlayAutoHides,
            selectedPreferencesTab,
            filmstripVisibleInWindowed,
            filmstripHeightPt,
            filmstripPinnedFullscreen,
            editRailPinnedFullscreen,
            exifPanelPinnedFullscreen,
            editRailVisibleInWindowed,
            editRailDefaultOnApplied,
            chromeFadeOutDelayMs,
            editJPEGQualityDefault,
            editHEICQualityDefault,
            editPreserveEXIFOnSave,
            editStripGPSOnSave,
            editRotateUseLosslessForJPEG,
            editAutoCropOnFreeRotate,
            editColorAdjustPreviewFullResAlways,
            editTrashDirOverride,
            backupRetentionDays,
            metadataWriteFileAttributes,
            backupMaxBytes,
            viewerHistogramVisible,
            viewerHistogramMode,
            slideshowIntervalSec,
            slideshowTransition,
            slideshowRandom,
            slideshowFill,
            slideshowLoop,
            browserFavorites,
            viewerToolbarAutoHide,
            viewerInspectorVisibleWindowed,
            // Declared next to their owners.
            ImageGroupingPreference.key,       // shrike.grouping.pairRAW
            "shrike.editors.registry",          // ShrikeIO ExternalEditorRegistry.defaultsKey
            DestinationSlots.Key.destinations, // shrike.fileops.destinations
            DestinationSlots.Key.lastCopy,     // shrike.fileops.lastCopy
            DestinationSlots.Key.lastMove,     // shrike.fileops.lastMove
            // Print and contact sheet (PrintSettingsStore).
            PrintSettingsStore.Key.scaling,             // shrike.print.scaling
            PrintSettingsStore.Key.showFileName,        // shrike.print.showFileName
            PrintSettingsStore.Key.orientation,         // shrike.print.orientation
            PrintSettingsStore.Key.contactSheetColumns, // shrike.print.contactSheet.columns
            PrintSettingsStore.Key.contactSheetPaper,   // shrike.print.contactSheet.paper
            PrintSettingsStore.Key.contactSheetCaption, // shrike.print.contactSheet.caption
        ]
    }

    // MARK: Shortcuts

    public static var shortcutPreset: ShortcutPreset {
        get {
            guard let data = defaults.data(forKey: Key.shortcutPreset),
                  let decoded = try? JSONDecoder().decode(ShortcutPreset.self, from: data)
            else { return .macNative }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.shortcutPreset)
            }
        }
    }

    // MARK: Thumbnails

    /// Thumbnail long-edge in points at 1x. Scaled by `backingScaleFactor`
    /// in the caller. Default 180 matches FastStone's medium grid.
    public static var thumbnailSizePt: Int {
        get {
            let raw = defaults.object(forKey: Key.thumbnailSizePt) as? Int
            return raw ?? 180
        }
        set { defaults.set(newValue, forKey: Key.thumbnailSizePt) }
    }

    // MARK: Browser sort

    /// View ▸ Sort By: `name`, `dateCaptured`, `dateModified`, `size`,
    /// `rating`, `kind` or `dimensions`. One global setting.
    public static var browserSortKey: String {
        get { defaults.string(forKey: Key.browserSortKey) ?? "name" }
        set { defaults.set(newValue, forKey: Key.browserSortKey) }
    }

    /// View ▸ Sort By ▸ Ascending (true) / Descending (false).
    public static var browserSortAscending: Bool {
        get { defaults.object(forKey: Key.browserSortAscending) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.browserSortAscending) }
    }

    /// View ▸ as Grid (0) / as Filmstrip (1) / as List (2). One global
    /// setting, like the sort: a new Browser window and the next launch
    /// start in the last mode the user chose.
    public static var browserViewMode: Int {
        get { defaults.object(forKey: Key.browserViewMode) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Key.browserViewMode) }
    }

    // MARK: Input

    /// Settings › General › "Mouse wheel": true = Changes
    /// image (the default, FastStone behaviour), false = Zooms.
    public static var scrollWheelNavigates: Bool {
        get { defaults.object(forKey: Key.scrollWheelNavigates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.scrollWheelNavigates) }
    }

    // MARK: External editors

    public static var externalEditors: [ExternalEditorSlot] {
        get {
            guard let data = defaults.data(forKey: Key.externalEditors),
                  let decoded = try? JSONDecoder().decode([ExternalEditorSlot].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.externalEditors)
            }
        }
    }

    // MARK: Browser

    public static var recentFoldersLimit: Int {
        get {
            let raw = defaults.object(forKey: Key.recentFoldersLimit) as? Int
            return raw ?? 20
        }
        set { defaults.set(newValue, forKey: Key.recentFoldersLimit) }
    }

    public static var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.showHiddenFiles) }
        set { defaults.set(newValue, forKey: Key.showHiddenFiles) }
    }

    // MARK: Cache

    /// Disk ceiling for thumbnail cache. Default 512 MB
    public static var cacheDiskCeilingBytes: Int64 {
        get {
            if let raw = defaults.object(forKey: Key.cacheDiskCeilingBytes) as? Int64 {
                return raw
            }
            if let raw = defaults.object(forKey: Key.cacheDiskCeilingBytes) as? Int {
                return Int64(raw)
            }
            return 512 * 1024 * 1024
        }
        set { defaults.set(newValue, forKey: Key.cacheDiskCeilingBytes) }
    }

    // MARK: Viewer

    /// Hide the windowed viewer's titlebar and toolbar when
    /// the pointer is still. Default on.
    public static var viewerToolbarAutoHide: Bool {
        get { defaults.object(forKey: Key.viewerToolbarAutoHide) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.viewerToolbarAutoHide) }
    }

    /// New viewer windows open with the inspector shown.
    /// Default off; written on every toggle.
    public static var viewerInspectorVisibleWindowed: Bool {
        get { defaults.bool(forKey: Key.viewerInspectorVisibleWindowed) }
        set { defaults.set(newValue, forKey: Key.viewerInspectorVisibleWindowed) }
    }

    public static var viewerBackgroundAlwaysBlack: Bool {
        get {
            // Off by default; the windowed canvas follows
            // Light/Dark. Full screen is always black.
            if defaults.object(forKey: Key.viewerBackgroundAlwaysBlack) == nil {
                return false
            }
            return defaults.bool(forKey: Key.viewerBackgroundAlwaysBlack)
        }
        set { defaults.set(newValue, forKey: Key.viewerBackgroundAlwaysBlack) }
    }

    /// Maximum long edge (px) we decode eagerly for the viewer. Larger
    /// images are decoded at this size first and re-decoded at full-res
    /// on zoom-past-100%. Default 4096 covers most 4K+ displays.
    public static var maxDisplayLongEdge: Int {
        get {
            let raw = defaults.object(forKey: Key.maxDisplayLongEdge) as? Int
            return raw ?? 4096
        }
        set { defaults.set(newValue, forKey: Key.maxDisplayLongEdge) }
    }

    /// When true, the bottom-left position overlay ("N / M — filename") fades
    /// out after `NavigationFeedbackState.overlayIdleTimeout` (2.0 s) of nav
    /// inactivity, in a window and in full screen (spec 24 §1.2). This is the
    /// default: nothing is registered or stored, so a user who never touched
    /// the switch gets it. When false, the overlay is held open for the life
    /// of the viewer window so the user can glance down and see their folder
    /// position at any moment.
    public static var viewerPositionOverlayAutoHides: Bool {
        get {
            defaults.object(forKey: Key.viewerPositionOverlayAutoHides) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Key.viewerPositionOverlayAutoHides) }
    }

    // MARK: Filmstrip + fullscreen chrome

    /// Whether the docked filmstrip (below the canvas) is visible in
    /// windowed mode. Default `true`. Toggled by `⌘K` in windowed mode.
    /// Fullscreen mode has its own pin pref (`filmstripPinnedFullscreen`).
    public static var filmstripVisibleInWindowed: Bool {
        get {
            if defaults.object(forKey: Key.filmstripVisibleInWindowed) == nil {
                return true
            }
            return defaults.bool(forKey: Key.filmstripVisibleInWindowed)
        }
        set { defaults.set(newValue, forKey: Key.filmstripVisibleInWindowed) }
    }

    /// Height of the docked filmstrip in windowed mode. Clamped to
    /// `64...120` pt so the getter never returns an out-of-range value
    /// even if the user `defaults write`s nonsense. Default `80`.
    public static var filmstripHeightPt: Int {
        get {
            let raw = defaults.object(forKey: Key.filmstripHeightPt) as? Int
            let value = raw ?? 80
            return min(120, max(64, value))
        }
        set { defaults.set(min(120, max(64, newValue)), forKey: Key.filmstripHeightPt) }
    }

    /// Pin state for the top edge-hover filmstrip in fullscreen. Default
    /// `false`. Toggled by `⌘K` in fullscreen or by the on-panel pin glyph.
    public static var filmstripPinnedFullscreen: Bool {
        get { defaults.bool(forKey: Key.filmstripPinnedFullscreen) }
        set { defaults.set(newValue, forKey: Key.filmstripPinnedFullscreen) }
    }

    /// Pin state for the left edge-hover edit rail in fullscreen. Default
    /// `false`. Toggled by `⇧⌘E` or the on-panel pin glyph.
    public static var editRailPinnedFullscreen: Bool {
        get { defaults.bool(forKey: Key.editRailPinnedFullscreen) }
        set { defaults.set(newValue, forKey: Key.editRailPinnedFullscreen) }
    }

    /// Pin state for the right edge-hover EXIF/histogram panel in
    /// fullscreen. Default `false`. Toggled by `⌘I` or the on-panel pin
    /// glyph.
    public static var exifPanelPinnedFullscreen: Bool {
        get { defaults.bool(forKey: Key.exifPanelPinnedFullscreen) }
        set { defaults.set(newValue, forKey: Key.exifPanelPinnedFullscreen) }
    }

    /// The edit rail shows in a window only when this is
    /// on (View › Show Edit Rail, ⇧⌘E in a window). Default off. There
    /// is no hover reveal in a window; full screen keeps its edge zone
    /// and pin (`editRailPinnedFullscreen`).
    /// Default **on** (a missing value reads true).
    public static var editRailVisibleInWindowed: Bool {
        get { defaults.object(forKey: Key.editRailVisibleInWindowed) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.editRailVisibleInWindowed) }
    }

    /// Run once at launch, before the first viewer. Without
    /// the marker, a stored value becomes true (a chosen "off" can't be
    /// told from the old default), then the marker is set; after that the
    /// value is never touched again.
    public static func applyEditRailDefaultOnce() {
        guard defaults.object(forKey: Key.editRailDefaultOnApplied) == nil else { return }
        if defaults.object(forKey: Key.editRailVisibleInWindowed) != nil {
            defaults.set(true, forKey: Key.editRailVisibleInWindowed)
        }
        defaults.set(true, forKey: Key.editRailDefaultOnApplied)
    }

    /// Cursor-idle delay (ms) before hover-revealed chrome panels fade
    /// out in fullscreen mode. Default `1500` (1.5 s). Hidden pref —
    /// not surfaced in Preferences UI; tweakable via
    /// `defaults write app.shrike shrike.viewer.chromeFadeOutDelayMs -int N`
    /// for slow-testing or accessibility. Range clamped to `0...60_000`.
    public static var chromeFadeOutDelayMs: Int {
        get {
            let raw = defaults.object(forKey: Key.chromeFadeOutDelayMs) as? Int
            let value = raw ?? 1500
            return min(60_000, max(0, value))
        }
        set { defaults.set(min(60_000, max(0, newValue)), forKey: Key.chromeFadeOutDelayMs) }
    }

    // MARK: Edit

    /// JPEG quality default for `⌘S` / Save As. Stored 60–100; clamped
    /// on read so a hand-edited `defaults write` can't poison the
    /// slider. Default `92`.
    public static var editJPEGQualityDefault: Int {
        get {
            let raw = defaults.object(forKey: Key.editJPEGQualityDefault) as? Int
            let value = raw ?? 92
            return min(100, max(60, value))
        }
        set { defaults.set(min(100, max(60, newValue)), forKey: Key.editJPEGQualityDefault) }
    }

    /// HEIC quality default. Hidden pref — not surfaced in Preferences
    /// UI. Range 60–100. Default `80`.
    public static var editHEICQualityDefault: Int {
        get {
            let raw = defaults.object(forKey: Key.editHEICQualityDefault) as? Int
            let value = raw ?? 80
            return min(100, max(60, value))
        }
        set { defaults.set(min(100, max(60, newValue)), forKey: Key.editHEICQualityDefault) }
    }

    /// When true, Save / Save As carries EXIF (camera/lens/GPS etc.)
    /// from the source into the destination. Default `true`.
    public static var editPreserveEXIFOnSave: Bool {
        get {
            if defaults.object(forKey: Key.editPreserveEXIFOnSave) == nil { return true }
            return defaults.bool(forKey: Key.editPreserveEXIFOnSave)
        }
        set { defaults.set(newValue, forKey: Key.editPreserveEXIFOnSave) }
    }

    /// When true, Save / Save As drops the GPS sub-dictionary before
    /// writing. Paired with `editPreserveEXIFOnSave`; strips only the
    /// GPS fields, leaves the rest. Default `false`.
    public static var editStripGPSOnSave: Bool {
        get { defaults.bool(forKey: Key.editStripGPSOnSave) }
        set { defaults.set(newValue, forKey: Key.editStripGPSOnSave) }
    }

    /// Default state of the "Auto-crop corners" checkbox in the Rotate
    /// panel. Hidden pref. Default `true`.
    public static var editAutoCropOnFreeRotate: Bool {
        get {
            if defaults.object(forKey: Key.editAutoCropOnFreeRotate) == nil { return true }
            return defaults.bool(forKey: Key.editAutoCropOnFreeRotate)
        }
        set { defaults.set(newValue, forKey: Key.editAutoCropOnFreeRotate) }
    }

    /// When true, Color Adjust live preview skips the downsample-during-
    /// drag shortcut and renders full-res on every slider frame. Hidden
    /// escape hatch for test hardware where the downsample is visible.
    /// Default `false`.
    public static var editColorAdjustPreviewFullResAlways: Bool {
        get { defaults.bool(forKey: Key.editColorAdjustPreviewFullResAlways) }
        set { defaults.set(newValue, forKey: Key.editColorAdjustPreviewFullResAlways) }
    }

    // MARK: - File safety

    /// Days a pre-overwrite backup (see `BackupStore` in ShrikeIO) is kept
    /// before it is purged. Default 30. Negative = keep forever.
    public static var backupRetentionDays: Int {
        get {
            if defaults.object(forKey: Key.backupRetentionDays) == nil { return 30 }
            return defaults.integer(forKey: Key.backupRetentionDays)
        }
        set { defaults.set(newValue, forKey: Key.backupRetentionDays) }
    }

    /// Size cap of the backup store in bytes (no UI).
    /// Default 10 GiB. `0` or less = no cap.
    public static var backupMaxBytes: Int64 {
        get {
            guard let n = defaults.object(forKey: Key.backupMaxBytes) as? NSNumber else {
                return 10_737_418_240
            }
            return n.int64Value
        }
        set { defaults.set(NSNumber(value: newValue), forKey: Key.backupMaxBytes) }
    }

    /// When true, ratings and flags are also written to extended
    /// attributes on the image file (`app.shrike.rating` /
    /// `.flag`), so they survive moves done in Finder. Default `true`.
    public static var metadataWriteFileAttributes: Bool {
        get {
            if defaults.object(forKey: Key.metadataWriteFileAttributes) == nil { return true }
            return defaults.bool(forKey: Key.metadataWriteFileAttributes)
        }
        set { defaults.set(newValue, forKey: Key.metadataWriteFileAttributes) }
    }

    // MARK: - Histogram

    /// The viewer's histogram overlay is shown. Default `false`.
    public static var viewerHistogramVisible: Bool {
        get { defaults.bool(forKey: Key.viewerHistogramVisible) }
        set { defaults.set(newValue, forKey: Key.viewerHistogramVisible) }
    }

    /// `rgb`, `rgbl` or `l`. Default `rgbl`; unknown values read as the default.
    public static var viewerHistogramMode: String {
        get {
            let raw = defaults.string(forKey: Key.viewerHistogramMode) ?? "rgbl"
            return ["rgb", "rgbl", "l"].contains(raw) ? raw : "rgbl"
        }
        set { defaults.set(newValue, forKey: Key.viewerHistogramMode) }
    }

    // MARK: - Slideshow

    /// Seconds per image, 1–60. Default 4.
    public static var slideshowIntervalSec: Int {
        get {
            guard defaults.object(forKey: Key.slideshowIntervalSec) != nil else { return 4 }
            return min(60, max(1, defaults.integer(forKey: Key.slideshowIntervalSec)))
        }
        set { defaults.set(min(60, max(1, newValue)), forKey: Key.slideshowIntervalSec) }
    }

    /// `cut`, `fade` or `dissolve`. Default `fade`.
    public static var slideshowTransition: String {
        get {
            let raw = defaults.string(forKey: Key.slideshowTransition) ?? "fade"
            return ["cut", "fade", "dissolve"].contains(raw) ? raw : "fade"
        }
        set { defaults.set(newValue, forKey: Key.slideshowTransition) }
    }

    /// Random order. Default `false`.
    public static var slideshowRandom: Bool {
        get { defaults.bool(forKey: Key.slideshowRandom) }
        set { defaults.set(newValue, forKey: Key.slideshowRandom) }
    }

    /// Fill the screen (crop) instead of fitting. Default `false`.
    public static var slideshowFill: Bool {
        get { defaults.bool(forKey: Key.slideshowFill) }
        set { defaults.set(newValue, forKey: Key.slideshowFill) }
    }

    /// Start over after the last image. Default `true`.
    public static var slideshowLoop: Bool {
        get {
            guard defaults.object(forKey: Key.slideshowLoop) != nil else { return true }
            return defaults.bool(forKey: Key.slideshowLoop)
        }
        set { defaults.set(newValue, forKey: Key.slideshowLoop) }
    }

    // MARK: - Browser favorites

    /// JSON array of `{ "path": String, "bookmark": Data }`, or nil when
    /// never written (first launch seeds it).
    public static var browserFavoritesData: Data? {
        get { defaults.data(forKey: Key.browserFavorites) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.browserFavorites) }
            else { defaults.removeObject(forKey: Key.browserFavorites) }
        }
    }

    // MARK: - Preferences window state

    /// Raw String backing for the Preferences window's currently-selected tab.
    /// The typed `PreferencesTab` enum lives in `ShrikeUI` so ShrikeCore stays
    /// free of UI concerns — the UI layer maps this rawValue to its enum
    /// via `PreferencesTab(rawValue:)` with a default fallback.
    public static var selectedPreferencesTabRaw: String? {
        get { defaults.string(forKey: Key.selectedPreferencesTab) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedPreferencesTab)
            } else {
                defaults.removeObject(forKey: Key.selectedPreferencesTab)
            }
        }
    }

    // MARK: - Reset

    /// Every `shrike.*` UserDefaults key owned by the typed schema. Exposed so
    /// tests and the Preferences window can iterate without duplicating the
    /// key list. Order is not meaningful; callers treat it as a set.
    public static var allUserDefaultsKeys: [String] { Key.allKeys }

    /// Restore every typed preference to its schema default by clearing its
    /// `UserDefaults` key. Getters that return literal defaults when the key
    /// is absent (see `thumbnailSizePt`, `cacheDiskCeilingBytes`, etc.) will
    /// therefore start returning those literals again on the next read.
    ///
    /// Not called on a hot path — the Preferences window's "Reset all
    /// preferences…" affordance is the sole caller today. Safe from any
    /// isolation: `UserDefaults` handles its own locking (see the
    /// file header note on `nonisolated(unsafe)`).
    /// Keys that were removed: lossless rotate is always on, and
    /// backups replace the trash folder override.
    public static let retiredKeys: [String] = [
        Key.editRotateUseLosslessForJPEG,
        Key.editTrashDirOverride,
    ]

    /// Deletes the stored values of retired keys. Run at launch; a no-op
    /// once they are gone.
    public static func removeRetiredKeys(from store: UserDefaults? = nil) {
        let target = store ?? defaults
        for key in retiredKeys where target.object(forKey: key) != nil {
            target.removeObject(forKey: key)
        }
    }

    public static func resetAll() {
        for key in Key.allKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}
