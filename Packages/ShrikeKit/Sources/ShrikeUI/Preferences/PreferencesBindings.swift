//
//  PreferencesBindings.swift
//  ShrikeUI
//
//  SwiftUI plumbing for the Preferences window. `Prefs` is a static namespace,
//  so it has no `@Published` surface; we wrap it in a tiny `ObservableObject`
//  that forwards reads to `Prefs` and emits `objectWillChange` on every write.
//  This lets every tab re-render the instant a value changes without anyone
//  having to observe `UserDefaults.didChangeNotification`.
//
//  Do NOT use `@AppStorage` directly — it bypasses
//  the typed schema in `Prefs.swift`. Bindings go through `Prefs`.
//

import SwiftUI
import ShrikeCore

@MainActor
final class PreferencesStore: ObservableObject {

    // Mutation funnel — every setter calls `objectWillChange.send()` before
    // writing to `Prefs`. Keeps SwiftUI views in sync with out-of-band writes
    // from other parts of the app (e.g. the browser toggling show-hidden).
    //
    // We don't observe UserDefaults directly because the preferences window
    // is the only UI mutating these values interactively — everywhere else
    // reads once at startup or per-action.

    // MARK: - Scalar bindings

    /// Open viewers re-fit once when it changes.
    var viewerToolbarAutoHide: Binding<Bool> {
        binding(get: { Prefs.viewerToolbarAutoHide }, set: {
            Prefs.viewerToolbarAutoHide = $0
            NotificationCenter.default.post(name: .shrikeToolbarAutoHideChanged, object: nil)
        })
    }

    var showHiddenFiles: Binding<Bool> {
        binding(get: { Prefs.showHiddenFiles }, set: { value in
            guard Prefs.showHiddenFiles != value else { return }
            Prefs.showHiddenFiles = value
            // This existing Browser-only signal re-evaluates its listing rules.
            // Bindings can write off-main; selectors must still run on main.
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
                }
            }
        })
    }

    /// RAW+JPEG pairs: true = "Show as one item".
    var pairRAW: Binding<Bool> {
        binding(get: { ImageGroupingPreference.isEnabled },
                set: { PairsPreference.set(showAsOneItem: $0) })
    }

    var recentFoldersLimit: Binding<Int> {
        binding(get: { Prefs.recentFoldersLimit }, set: { Prefs.recentFoldersLimit = $0 })
    }

    var scrollWheelNavigates: Binding<Bool> {
        binding(get: { Prefs.scrollWheelNavigates }, set: { Prefs.scrollWheelNavigates = $0 })
    }

    /// Open Browser windows follow a change.
    var thumbnailSizePt: Binding<Int> {
        binding(get: { Prefs.thumbnailSizePt }, set: {
            Prefs.thumbnailSizePt = $0
            NotificationCenter.default.post(name: .shrikeThumbnailSizeChanged, object: nil)
        })
    }

    var cacheDiskCeilingBytes: Binding<Int64> {
        binding(
            get: { Prefs.cacheDiskCeilingBytes },
            set: { Prefs.cacheDiskCeilingBytes = $0 }
        )
    }

    var maxDisplayLongEdge: Binding<Int> {
        binding(get: { Prefs.maxDisplayLongEdge }, set: { Prefs.maxDisplayLongEdge = $0 })
    }

    var viewerBackgroundAlwaysBlack: Binding<Bool> {
        binding(
            get: { Prefs.viewerBackgroundAlwaysBlack },
            set: { Prefs.viewerBackgroundAlwaysBlack = $0 }
        )
    }

    // MARK: Editing tab

    var editJPEGQuality: Binding<Int> {
        binding(get: { Prefs.editJPEGQualityDefault }, set: { Prefs.editJPEGQualityDefault = $0 })
    }

    var editHEICQuality: Binding<Int> {
        binding(get: { Prefs.editHEICQualityDefault }, set: { Prefs.editHEICQualityDefault = $0 })
    }

    var editPreserveEXIFOnSave: Binding<Bool> {
        binding(get: { Prefs.editPreserveEXIFOnSave }, set: { Prefs.editPreserveEXIFOnSave = $0 })
    }

    var editStripGPSOnSave: Binding<Bool> {
        binding(get: { Prefs.editStripGPSOnSave }, set: { Prefs.editStripGPSOnSave = $0 })
    }

    var backupRetentionDays: Binding<Int> {
        binding(get: { Prefs.backupRetentionDays }, set: { Prefs.backupRetentionDays = $0 })
    }

    /// "Store ratings and flags with the file".
    var metadataWriteFileAttributes: Binding<Bool> {
        binding(get: { Prefs.metadataWriteFileAttributes },
                set: { Prefs.metadataWriteFileAttributes = $0 })
    }

    var viewerPositionOverlayAutoHides: Binding<Bool> {
        binding(
            get: { Prefs.viewerPositionOverlayAutoHides },
            set: { Prefs.viewerPositionOverlayAutoHides = $0 }
        )
    }

    var largerChrome: Binding<Bool> {
        binding(get: { Prefs.largerChrome }, set: { Prefs.largerChrome = $0
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil) })
    }
    var reviewControlsVisible: Binding<Bool> {
        binding(get: { Prefs.reviewControlsVisible }, set: { Prefs.reviewControlsVisible = $0
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil) })
    }
    var advanceAfterRating: Binding<Bool> {
        binding(get: { Prefs.advanceAfterRating }, set: { Prefs.advanceAfterRating = $0
            NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil) })
    }

    // MARK: - Mutation helpers

    /// Notify observers and then mutate. Callers use this for non-Binding
    /// writes (e.g. the "Reset this tab" button clearing UserDefaults keys
    /// directly).
    func notifyAndMutate(_ mutate: () -> Void) {
        objectWillChange.send()
        mutate()
    }

    // MARK: - Private

    private func binding<T>(
        get: @escaping @Sendable () -> T,
        set: @escaping @Sendable (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { [weak self] newValue in
                self?.objectWillChange.send()
                set(newValue)
            }
        )
    }
}

// MARK: - Byte formatter

enum PreferencesByteFormat {
    static func string(fromBytes bytes: Int64) -> String {
        FileSizeText.string(bytes, style: .binary)
    }
}

/// A Settings popup whose stored value is not one of its
/// choices shows an empty button (SwiftUI finds no matching tag). The
/// Browser's size slider and ⌘+ / ⌘− store any grid size (135 pt, say),
/// so every numeric popup lists the stored value too, in order.
enum SettingsChoices {
    static func including<T: Comparable & Hashable>(_ current: T, in options: [T]) -> [T] {
        options.contains(current) ? options : (options + [current]).sorted()
    }
}
