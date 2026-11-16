//
//  PhotoViewAccessibility.swift
//  ShrikeUI
//
//  What VoiceOver reads on the photo. Pure texts and
//  decisions; `ViewerContentView+PhotoAccessibility.swift` puts them on the view.
//

import AppKit
import ShrikeCore

enum PhotoViewAccessibility {

    /// The value is refreshed this long after the last zoom change, so
    /// VoiceOver does not speak every wheel tick.
    static let valueDelay: TimeInterval = 0.25

    /// `Zoom 100 percent`; a stand-in preview reads `Preview. Zoom 40 percent`.
    /// `pixelScale` 1.0 is 100 percent (one image pixel per screen pixel).
    static func value(pixelScale: Double, isPreview: Bool) -> String {
        let percent = Int((pixelScale * 100).rounded())
        let zoom = "Zoom \(percent) percent"
        return isPreview ? "Preview. \(zoom)" : zoom
    }

    /// The names of the rotor actions, in order.
    enum ActionName {
        static let zoomIn = "Zoom In"
        static let zoomOut = "Zoom Out"
        static let zoomToFit = "Zoom to Fit"
        static let previousPhoto = "Previous Photo"
        static let nextPhoto = "Next Photo"
    }
    static let actionNames = [ActionName.zoomIn, ActionName.zoomOut, ActionName.zoomToFit,
                              ActionName.previousPhoto, ActionName.nextPhoto]

    /// The help line, each sentence only when it is true of the keys of
    /// `preset` in the viewer: the arrow keys change photos; a bare plus and
    /// minus zoom (the Mac preset zooms with ⌘+ and ⌘−, so it says no such thing).
    @MainActor static func help(preset: ShortcutPreset) -> String? {
        if let cached = helpCache[preset] { return cached }
        let line = computeHelp(preset: preset)
        helpCache[preset] = line
        return line
    }

    /// One help line per preset: computed once (four shortcut lookups), so
    /// a photo change never looks shortcuts up.
    @MainActor private static var helpCache: [ShortcutPreset: String?] = [:]
    #if DEBUG
    /// Help lines computed since the start (tests: a photo change adds none).
    @MainActor static var helpComputationsForTesting = 0
    #endif

    @MainActor private static func computeHelp(preset: ShortcutPreset) -> String? {
        #if DEBUG
        helpComputationsForTesting += 1
        #endif
        func has(_ command: ShrikeCommand, _ key: String) -> Bool {
            ShortcutTable.bindings(for: command, context: .viewer, preset: preset)
                .contains(KeyBinding(key))
        }
        var sentences: [String] = []
        if has(.nextImage, SpecialKey.right) && has(.previousImage, SpecialKey.left) {
            sentences.append("Use the arrow keys to change photos.")
        }
        if has(.zoomIn, "+") && has(.zoomOut, "-") {
            sentences.append("Press plus or minus to zoom.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
