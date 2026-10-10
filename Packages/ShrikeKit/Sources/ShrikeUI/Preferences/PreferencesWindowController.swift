//
//  PreferencesWindowController.swift
//  ShrikeUI
//
//  Hand-rolled `NSWindowController` hosting a SwiftUI body via `NSHostingView`.
//  We bypass SwiftUI's `Settings { … }` scene because the app shell is an
//  `NSApplicationDelegate` + hand-authored `main.swift`.
//  Promoting to `@main App` risks the <250 ms cold
//  launch budget and none of the viewer/browser code is SwiftUI). This path
//  costs us one extra file but keeps the rest of the app shell untouched.
//
//  Tab bar: standard macOS `NSToolbar` in selectable-item mode, one item per
//  `PreferencesTab`. SF Symbol at 24 pt (17 pt would be smaller than
//  every built-in Settings app).
//

import AppKit
import Combine
import SwiftUI
import ShrikeCore
import ShrikeIO

@MainActor
public final class PreferencesWindowController: NSWindowController {

    private let selection: PreferencesSelection
    private let thumbnailCache: ThumbnailCache?
    private let toolbarIdentifier = NSToolbar.Identifier("shrike.preferences.toolbar")

    // Combine subscription bag. Held by the controller so bindings stay
    // alive for the life of the window.
    private var subs: Set<AnyCancellable> = []

    // Toolbar delegate is a separate object so its NSObjectProtocol conformance
    // doesn't force @objc inheritance tangles on the window controller itself.
    private var toolbarDelegate: PreferencesToolbarDelegate?

    public init(thumbnailCache: ThumbnailCache? = nil, backupStore: BackupStore? = nil) {
        let selection = PreferencesSelection(initial: PreferencesTab.loadSelected())
        self.selection = selection
        self.thumbnailCache = thumbnailCache

        // Non-resizable window; size ~600 × 500.
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 500)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        // Host the SwiftUI content.
        let root = PreferencesRootView(
            selection: selection,
            thumbnailCache: thumbnailCache,
            backupStore: backupStore
        )
        // One accent, the system's.
        let host = NSHostingView(rootView: root.tint(Color(nsColor: .controlAccentColor)))
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        // Build the toolbar.
        configureToolbar()

        // Keep the window title in lockstep with the active tab and mirror
        // the selection into the toolbar's selected-item indicator.
        selection.$tab
            .sink { [weak self] tab in
                guard let self else { return }
                self.window?.title = "\(tab.title) — Settings"
                self.window?.toolbar?.selectedItemIdentifier =
                    NSToolbarItem.Identifier(tab.rawValue)
            }
            .store(in: &subs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Public

    /// Bring the window to the front, creating it if needed. Called from
    /// `AppDelegate.showPreferencesWindow()` / the ⌘, menu item.
    public func show() {
        if let window = self.window, !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // No control starts focused (the first one showed
        // its text selected).
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens Settings on `tab` (Help ▸ Keyboard Shortcuts → `.shortcuts`).
    public func show(tab: PreferencesTab) {
        selection.tab = tab
        show()
    }

    // MARK: - Toolbar

    private func configureToolbar() {
        let delegate = PreferencesToolbarDelegate(
            onSelect: { [weak self] tab in
                self?.selection.tab = tab
            }
        )
        self.toolbarDelegate = delegate

        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = delegate
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbarStyle = .preference
        window?.toolbar = toolbar
        toolbar.selectedItemIdentifier =
            NSToolbarItem.Identifier(selection.tab.rawValue)
    }
}

// MARK: - Toolbar delegate

@MainActor
private final class PreferencesToolbarDelegate: NSObject, NSToolbarDelegate {

    private let onSelect: (PreferencesTab) -> Void

    init(onSelect: @escaping (PreferencesTab) -> Void) {
        self.onSelect = onSelect
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        PreferencesTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = PreferencesTab(rawValue: itemIdentifier.rawValue) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title

        // 24 pt SF Symbol.
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        if let image = NSImage(systemSymbolName: tab.symbolName,
                               accessibilityDescription: tab.title)?
            .withSymbolConfiguration(config)
        {
            item.image = image
        }

        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        item.isEnabled = true
        return item
    }

    @objc private func toolbarItemClicked(_ sender: Any?) {
        guard let item = sender as? NSToolbarItem,
              let tab = PreferencesTab(rawValue: item.itemIdentifier.rawValue)
        else { return }
        onSelect(tab)
    }
}
