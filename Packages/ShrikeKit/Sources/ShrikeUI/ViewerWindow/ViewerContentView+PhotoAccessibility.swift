//
//  ViewerContentView+PhotoAccessibility.swift
//  ShrikeUI
//
//  The photo view as VoiceOver sees it. Set from here
//  (ShrikeUI) on the plain NSView properties of `MetalImageView`, so
//  ShrikeRendering does not change.
//

import AppKit
import ShrikeCore

/// What the photo view says about itself; the texts are in `PhotoViewAccessibility`.
@MainActor
final class PhotoAccessibilityState {
    var name: String?
    var isPreview = false
    var work: DispatchWorkItem?
    var actionsInstalled = false
    /// The preset the help line was written for.
    var helpPreset: ShortcutPreset?
    var defaultsObserver: (any NSObjectProtocol)?
    isolated deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
    /// `.valueChanged` posts since the start (tests).
    var valuePosts = 0
}

extension ViewerContentView {

    /// Role, name, value, help and the five rotor actions. `dispatch` runs
    /// the same viewer commands as the menu.
    func installPhotoAccessibility(dispatch: @escaping @MainActor (ViewerAction) -> Void) {
        // Called on every photo change (next/prev path): after the first
        // call it returns at once. The help line follows a preset change
        // through the defaults notification, never through a photo change.
        guard !photoAccessibility.actionsInstalled else { return }
        photoAccessibility.actionsInstalled = true
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        refreshPhotoAccessibilityHelp()
        photoAccessibility.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPhotoAccessibilityHelp() }
        }
        func action(_ name: String, _ command: ViewerAction) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) {
                MainActor.assumeIsolated { dispatch(command) }
                return true
            }
        }
        typealias Names = PhotoViewAccessibility.ActionName
        imageView.setAccessibilityCustomActions([
            action(Names.zoomIn, .zoomIn),
            action(Names.zoomOut, .zoomOut),
            action(Names.zoomToFit, .zoomBestFit),
            action(Names.previousPhoto, .prevImage),
            action(Names.nextPhoto, .nextImage),
        ])
        refreshPhotoAccessibilityValue(post: false)
    }

    /// The help line for the current shortcut preset (cached per preset).
    func refreshPhotoAccessibilityHelp() {
        let preset = Prefs.shortcutPreset
        guard photoAccessibility.helpPreset != preset else { return }
        photoAccessibility.helpPreset = preset
        imageView.setAccessibilityHelp(PhotoViewAccessibility.help(preset: preset))
    }

    /// The file name, set when the photo changes.
    func setPhotoAccessibilityName(_ name: String?) {
        photoAccessibility.name = name
        imageView.setAccessibilityLabel(name)
    }

    /// A stand-in preview is on screen (or the real photo took over).
    func setPhotoAccessibilityPreview(_ on: Bool) {
        guard photoAccessibility.isPreview != on else { return }
        photoAccessibility.isPreview = on
        schedulePhotoAccessibilityValue()
    }

    /// Updates the value 250 ms after the last call.
    func schedulePhotoAccessibilityValue() {
        photoAccessibility.work?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshPhotoAccessibilityValue(post: true) }
        }
        photoAccessibility.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PhotoViewAccessibility.valueDelay, execute: work)
    }

    /// Writes the value now. `post`: tell VoiceOver the value changed.
    func refreshPhotoAccessibilityValue(post: Bool) {
        photoAccessibility.work = nil
        imageView.setAccessibilityValue(photoAccessibilityValueForTesting)
        if post {
            photoAccessibility.valuePosts += 1
            NSAccessibility.post(element: imageView, notification: .valueChanged)
        }
    }

    /// The text VoiceOver reads as the photo's value right now.
    var photoAccessibilityValueForTesting: String {
        PhotoViewAccessibility.value(pixelScale: imageView.pixelScale, isPreview: photoAccessibility.isPreview)
    }
}
