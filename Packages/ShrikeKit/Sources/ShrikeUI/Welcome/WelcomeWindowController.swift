//
//  WelcomeWindowController.swift
//  ShrikeUI
//
//  The Welcome window. Plain AppKit: it
//  is on the launch path when Shrike starts with nothing to open.
//
//  Left: app icon, title, drop zone, Open… / Open Folder…. Right: the
//  Recent list. Items that are gone (disk unplugged) are dimmed after an
//  off-main check; clicking one explains why instead of failing quietly.
//

import AppKit
import ShrikeCore

@MainActor
public final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    /// The Recent list scrolls when it is taller than this.
    static let maxListHeight: CGFloat = 300
    static let rowHeight: CGFloat = 40
    static let size = NSSize(width: 640, height: 440)
    static let recentColumnWidth: CGFloat = 264

    public var onOpenURLs: (([URL]) -> Void)?
    public var onOpenFiles: (() -> Void)?
    public var onOpenFolder: (() -> Void)?
    public var onClose: (() -> Void)?

    private let recentURLs: @MainActor () -> [URL]
    /// Forgets Recent items whose folder is gone (tests pass a stub, so
    /// the shared document controller is not touched).
    private let forgetRecents: @MainActor ([URL]) -> Void
    /// Items found dead and pruned in this window: never shown again.
    private(set) var prunedRecents: Set<URL> = []

    let openButton = NSButton(title: "Open Photo…", target: nil, action: nil)
    let openFolderButton = NSButton(title: "Open Folder…", target: nil, action: nil)
    let dropZone = WelcomeDropZone(frame: .zero)
    let emptyLabel = NSTextField(labelWithString: "No recent items")
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let recentStack = NSStackView()
    private let recentScroll = NSScrollView()
    private var recentScrollHeight: NSLayoutConstraint?
    /// "“Trip” is not available…" and other notices.
    let toastHost = ToastHostView(placement: .browser)
    private(set) var recentRows: [WelcomeRecentRow] = []
    private(set) var shownRecents: [URL] = []
    private(set) var missingRecents: Set<URL> = []

    public init(
        recentURLs: @escaping @MainActor () -> [URL] = AppCommands.recentURLs,
        forgetRecents: @escaping @MainActor ([URL]) -> Void = AppCommands.forgetRecents
    ) {
        self.recentURLs = recentURLs
        self.forgetRecents = forgetRecents
        let window = WelcomeWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to Shrike"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Public

    public func show() {
        reloadRecents()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A one-line notice under the Recent list (e.g. nothing could open).
    public func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        NSAccessibility.post(element: messageLabel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Esc closes Welcome.
    override public func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Recent list

    func reloadRecents() {
        recentRows.forEach { $0.removeFromSuperview() }
        shownRecents = Array(recentURLs().filter { !prunedRecents.contains($0) }
            .prefix(max(1, Prefs.recentFoldersLimit)))
        missingRecents = []
        recentRows = shownRecents.enumerated().map { index, url in
            makeRow(for: url, index: index)
        }
        for row in recentRows {
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.recentColumnWidth).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        recentScrollHeight?.constant = min(CGFloat(recentRows.count) * Self.rowHeight, Self.maxListHeight)
        recentScroll.isHidden = recentRows.isEmpty
        linkKeyViews()
        emptyLabel.isHidden = !shownRecents.isEmpty
        checkAvailability(shownRecents)
    }

    /// Opens a Recent item, or explains why it can't.
    func openRecent(_ url: URL) {
        if missingRecents.contains(url) {
            if toastHost.superview == nil, let root = window?.contentView { toastHost.install(in: root) }
            toastHost.show(ToastContent(
                "“\(url.lastPathComponent)” is not available. The disk may be disconnected.", kind: .error
            ))
            return
        }
        onOpenURLs?([url])
    }

    func markMissing(_ urls: [URL]) {
        missingRecents = Set(urls)
        for (index, url) in shownRecents.enumerated() where missingRecents.contains(url) {
            let row = recentRows[index]
            row.alphaValue = 0.5
            row.attributedTitle = Self.rowTitle(for: url, available: false)
            row.setAccessibilityLabel("\(url.lastPathComponent), not available")
        }
    }

    private func checkAvailability(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard !missing.isEmpty else { return }
            let dead = missing.filter { AppCommands.isDeadRecent($0) }
            await self?.handleMissing(missing, dead: dead)
        }
    }

    /// Deleted folders leave the list (and Open Recent); an unplugged disk's
    /// items stay, dimmed.
    func handleMissing(_ missing: [URL], dead: [URL]) {
        guard !dead.isEmpty else { markMissing(missing); return }
        prunedRecents.formUnion(dead)
        forgetRecents(dead)
        reloadRecents()
    }

    /// Tab order: Open…, Open Folder…, the Recent list (one stop; ↑/↓
    /// move inside it), back to Open….
    private func linkKeyViews() {
        window?.autorecalculatesKeyViewLoop = false
        openFolderButton.nextKeyView = openButton
        openButton.nextKeyView = recentRows.first ?? openFolderButton
        for (index, row) in recentRows.enumerated() {
            row.nextKeyView = openFolderButton
            row.previousRow = index > 0 ? recentRows[index - 1] : nil
            row.nextRow = index + 1 < recentRows.count ? recentRows[index + 1] : nil
        }
    }

    private func makeRow(for url: URL, index: Int) -> WelcomeRecentRow {
        let row = WelcomeRecentRow(title: "", target: self, action: #selector(recentClicked(_:)))
        row.isBordered = false
        row.setButtonType(.momentaryChange)
        row.alignment = .left
        row.imagePosition = .imageLeading
        row.imageHugsTitle = true
        // No disk read: folders have no extension.
        let isFolder = url.hasDirectoryPath || url.pathExtension.isEmpty
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        row.image = NSImage(systemSymbolName: isFolder ? "folder" : "photo",
                            accessibilityDescription: nil)?.withSymbolConfiguration(config)
        row.contentTintColor = .secondaryLabelColor
        row.attributedTitle = Self.rowTitle(for: url, available: true)
        row.tag = index
        row.setAccessibilityLabel("\(url.lastPathComponent), \(Self.abbreviatedPath(url))")
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func recentClicked(_ sender: NSButton) {
        guard shownRecents.indices.contains(sender.tag) else { return }
        openRecent(shownRecents[sender.tag])
    }

    static func abbreviatedPath(_ url: URL) -> String {
        UserFacingPath.string(url.deletingLastPathComponent())
    }

    static func rowTitle(for url: URL, available: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let title = NSMutableAttributedString(string: url.lastPathComponent, attributes: [
            .font: ChromeTypography.font(13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
        title.append(NSAttributedString(string: "\n" + (available ? abbreviatedPath(url) : "Not available"), attributes: [
            .font: ChromeTypography.font(11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]))
        return title
    }

    // MARK: Actions

    @objc private func openFilesClicked(_ sender: Any?) { onOpenFiles?() }
    @objc private func openFolderClicked(_ sender: Any?) { onOpenFolder?() }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        // A solid window background (the old material
        // sampled the desktop and came out a different grey).
        let root = TokenBackgroundView(fillColor: .windowBackgroundColor)
        root.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = root

        // Title block.
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: "Shrike")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Open a photo or a folder to start.")
        subtitle.font = ChromeTypography.font(13)
        subtitle.textColor = .secondaryLabelColor
        let titleText = NSStackView(views: [title, subtitle])
        titleText.orientation = .vertical
        titleText.alignment = .leading
        titleText.spacing = 2
        let titleBlock = NSStackView(views: [icon, titleText])
        titleBlock.orientation = .horizontal
        titleBlock.alignment = .centerY
        titleBlock.spacing = 12

        // Drop zone and buttons.
        dropZone.onDrop = { [weak self] urls in self?.onOpenURLs?(urls) }
        openButton.target = self
        openButton.action = #selector(openFilesClicked(_:))
        // "Open…" is the plain bordered button; "Open Folder…" is the primary
        // (spec 27 P3-11). ⌘O opens files from the menu.
        openButton.controlSize = .large
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderClicked(_:))
        openFolderButton.controlSize = .large
        // Spec 27 P3-11: "Open Folder…" is the primary (accent default button,
        // Return); "Open…" stays the plain bordered button.
        openButton.bezelStyle = .push
        openFolderButton.bezelStyle = .rounded
        openFolderButton.isBordered = true
        openFolderButton.keyEquivalent = "\r"
        openFolderButton.bezelColor = ShrikeAccent.mark
        let buttons = NSStackView(views: [openFolderButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let left = NSStackView(views: [titleBlock, dropZone, buttons])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 20

        // Recent column.
        let header = NSTextField(labelWithString: "Recent")
        header.font = ChromeTypography.font(11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.setAccessibilityRole(.staticText)
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 0
        recentStack.setAccessibilityElement(true)
        recentStack.setAccessibilityRole(.list)
        recentStack.setAccessibilityLabel("Recent")
        emptyLabel.font = ChromeTypography.font(13)
        emptyLabel.textColor = .secondaryLabelColor
        messageLabel.font = ChromeTypography.font(11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        messageLabel.preferredMaxLayoutWidth = Self.recentColumnWidth
        // The list scrolls past `maxListHeight`.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        recentScroll.contentView = clip
        recentScroll.documentView = recentStack
        recentScroll.drawsBackground = false
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        recentScroll.translatesAutoresizingMaskIntoConstraints = false
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        let height = recentScroll.heightAnchor.constraint(equalToConstant: 0)
        recentScrollHeight = height
        NSLayoutConstraint.activate([
            height,
            recentScroll.widthAnchor.constraint(equalToConstant: Self.recentColumnWidth),
            recentStack.topAnchor.constraint(equalTo: clip.topAnchor),
            recentStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            recentStack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        let right = NSStackView(views: [header, recentScroll, emptyLabel, messageLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator

        for view in [left, right, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            dropZone.widthAnchor.constraint(equalToConstant: 304),
            dropZone.heightAnchor.constraint(equalToConstant: 240),

            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            left.widthAnchor.constraint(equalToConstant: 304),
            left.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 12),

            separator.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            right.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 15),
            right.widthAnchor.constraint(equalToConstant: Self.recentColumnWidth),
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
    }
}

// MARK: - Drop zone

/// Dashed box that takes photos and folders. It lights up only for drags
/// Shrike can open.
@MainActor
final class WelcomeDropZone: NSView {

    var onDrop: (([URL]) -> Void)?
    private(set) var isHighlighted = false {
        didSet { needsDisplay = true }
    }
    private let border = CAShapeLayer()

    /// The dashed border at rest: at least 3:1 against the window (WCAG 1.4.11).
    static let idleBorderColor = NSColor.secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        border.fillColor = nil
        layer?.addSublayer(border)
        let label = NSTextField(labelWithString: "Drop photos or folders here")
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop photos or folders here")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                             cornerWidth: 11, cornerHeight: 11, transform: nil)
    }

    override func updateLayer() {
        // AppKit sets the view's appearance as current here, so the
        // dynamic colours resolve for light and dark.
        if isHighlighted {
            border.strokeColor = ShrikeAccent.mark.resolvedCGColor(for: effectiveAppearance)
            border.lineWidth = 2
            border.lineDashPattern = nil
            layer?.backgroundColor = ShrikeAccent.mark.withAlphaComponent(0.08).resolvedCGColor(for: effectiveAppearance)
        } else {
            border.strokeColor = Self.idleBorderColor.resolvedCGColor(for: effectiveAppearance)
            border.lineWidth = 1.5
            border.lineDashPattern = [6, 4]
            layer?.backgroundColor = nil
        }
    }

    static func openable(_ urls: [URL]) -> Bool {
        let request = WindowCoordinator.classify(urls)
        return !request.images.isEmpty || !request.folders.isEmpty
    }

    private static func urls(from info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = Self.openable(Self.urls(from: sender))
        isHighlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isHighlighted = false
        let urls = Self.urls(from: sender)
        guard Self.openable(urls) else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - Recent rows and keys

/// A Recent row: focusable, ↑/↓ move between rows, Return opens.
@MainActor
final class WelcomeRecentRow: NSButton {

    weak var previousRow: WelcomeRecentRow?
    weak var nextRow: WelcomeRecentRow?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch KeyCharacters.key(of: event) {
        case SpecialKey.up: move(to: previousRow)
        case SpecialKey.down: move(to: nextRow)
        case SpecialKey.returnKey, SpecialKey.enter: performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    private func move(to row: WelcomeRecentRow?) {
        guard let row else { NSSound.beep(); return }
        window?.makeFirstResponder(row)
        row.scrollToVisible(row.bounds)
    }
}

/// Return on a focused Recent row opens it instead of pressing the
/// default "Open…" button.
@MainActor
final class WelcomeWindow: NSWindow {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let row = firstResponder as? WelcomeRecentRow,
           event.modifierFlags.intersection(KeyBinding.relevantModifiers).isEmpty,
           case let key = KeyCharacters.key(of: event),
           key == SpecialKey.returnKey || key == SpecialKey.enter {
            row.performClick(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Top-anchored clip view so a short list starts at the top.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
