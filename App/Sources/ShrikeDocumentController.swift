//
//  ShrikeDocumentController.swift
//  Shrike
//
//  NSDocumentController subclass. We run our own so we
//  can route folder drops to BrowserWindow and file drops to ViewerWindow
//  without AppKit trying to instantiate a document per image.
//
//  It also keeps File ▸ Open Recent's list; WindowCoordinator notes every
//  opened folder and photo in it.

import AppKit
import ShrikeCore

final class ShrikeDocumentController: NSDocumentController {

    // AppKit instantiates the first NSDocumentController-ish class to be
    // referenced; main.swift touches `.shared` before NSApp exists so that
    // this subclass wins.
    override init() {
        super.init()
    }

    // Required by NSDocumentController / NSCoder compliance. We never
    // instantiate from a nib, but the compiler wants this declared.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShrikeDocumentController is created programmatically.")
    }

    /// Open Recent keeps as many items as Settings ▸ General says.
    ///
    /// `nonisolated` on purpose: AppKit reads this from its "Document Recents"
    /// background operation queue (`_NSRecentItemsMenuController`) after every
    /// `noteNewRecentDocumentURL(_:)`. A main-actor getter trips Swift 6's
    /// runtime isolation check there (EXC_BREAKPOINT in
    /// `_dispatch_assert_queue_fail`). Keep this body free of main-actor state:
    /// `Prefs` reads `UserDefaults`, which is thread-safe.
    nonisolated override var maximumRecentDocumentCount: Int {
        max(0, Prefs.recentFoldersLimit)
    }
}
