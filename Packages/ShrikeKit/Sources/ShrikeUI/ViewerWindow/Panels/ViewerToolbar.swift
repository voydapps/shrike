//
//  ViewerToolbar.swift
//  ShrikeUI
//
//  Fullscreen bottom toolbar.
//
//  Custom NSView (NSToolbar isn't appropriate for the fullscreen overlay).
//  SF Symbols icons; action dispatch routes through the shared
//  `ViewerAction` enum owned by ViewerWindow.
//
//  Capsule: 44 pt high, no pin (the capsule shows when the pointer rests
//  in the bottom zone, or while its menu is open; spec 24 §1.2).
//   * 11 buttons + 5 hairlines in one NSStackView (spec 24 §1.3). Each button has an
//     explicit 32×32 frame and its OWN target/action (fixes issue #10 —
//     previously overlapping hit-test rects caused zoom-minus to be
//     silently absorbed by its neighbour and rotate-left to double-dispatch).
//

import AppKit
import ShrikeCore

@MainActor
final class ViewerToolbar: HUDSurfaceView {

    var actionDispatcher: ((ViewerAction) -> Void)?

    /// A capsule menu (the share picker) is open: the capsule stays
    /// shown until it closes.
    private(set) var holdsOpen = false {
        didSet { if holdsOpen != oldValue { onHoldChanged?() } }
    }
    /// Fired when `holdsOpen` changes.
    var onHoldChanged: (() -> Void)?

    private let contentContainer = NSView()

    /// Capsule height.
    static let height: CGFloat = 44

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A capsule on macOS 26 (radius = height / 2).
        glassShape = .capsule
        // Full-screen HUD: `labelColor` glyphs read light on the dark HUD.
        appearance = NSAppearance(named: .darkAqua)
        buildContentRow()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Present the system share picker anchored to the Share toolbar
    /// button. No sender args are threaded through every
    /// action case; the window asks the toolbar to show the picker.
    func showShare(from window: NSWindow, url: URL?) {
        guard let url else { return }
        guard let shareButton = buttonForAction(.share) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        holdsOpen = true
        // Present anchored to the share button's own frame in its window.
        picker.show(
            relativeTo: shareButton.bounds,
            of: shareButton,
            preferredEdge: .minY
        )
        _ = window // used to quiet unused-param warnings when wrapping
    }

    // MARK: - Build

    private let buttonStack = NSStackView()

    /// Ordered buttons list, indexed by their ViewerAction. Needed so
    /// `showShare(from:)` can find the share button without walking
    /// subviews.
    private var buttonsByAction: [ViewerActionKey: NSButton] = [:]

    /// Wrapper key for ViewerAction so we can hash it in a dictionary
    /// (ViewerAction is Hashable already, but associated values make it
    /// awkward as a dict key with our specific "by top-level case"
    /// lookup). We use a raw discriminator string.
    private struct ViewerActionKey: Hashable {
        let raw: String
    }

    private static func key(for action: ViewerAction) -> ViewerActionKey {
        ViewerActionKey(raw: String(describing: action))
    }

    private func buttonForAction(_ action: ViewerAction) -> NSButton? {
        buttonsByAction[Self.key(for: action)]
    }

    private func buildContentRow() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        // Content fills the full panel. No reserved pin
        // strip at the top; the corner overlay floats on top of the
        // content region.
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        buttonStack.orientation = .horizontal
        buttonStack.spacing = Self.buttonGap
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentContainer.heightAnchor.constraint(equalToConstant: Self.height),
        ])

        // Authoritative inventory (spec 24 §1.3): 11 buttons in 6 groups.
        // The capsule holds what you do to the photo or to get around;
        // flag, rating and histogram live in the inspector / View menu.
        // Move
        addButton(symbol: "chevron.left",  accessibility: "Previous photo",
                  selector: #selector(handlePrev(_:)), action: .prevImage)
        addButton(symbol: "chevron.right", accessibility: "Next photo",
                  selector: #selector(handleNext(_:)), action: .nextImage)
        addSeparator()
        // View: one zoom pull-down replaces Fit / 100 % / + / -.
        addZoomMenuButton()
        addSeparator()
        // Photo
        addButton(symbol: "rotate.left",
                  accessibility: "Rotate left",
                  selector: #selector(handleRotateLeft(_:)), action: .rotateLeft)
        addButton(symbol: "rotate.right",
                  accessibility: "Rotate right",
                  selector: #selector(handleRotateRight(_:)), action: .rotateRight)
        addSeparator()
        // Do
        addButton(symbol: "square.and.arrow.up",
                  accessibility: "Share",
                  selector: #selector(handleShare(_:)), action: .share)
        addButton(symbol: "slider.horizontal.3",
                  accessibility: "Edit",
                  selector: #selector(handleEdit(_:)), action: .openEditMode)
        addButton(symbol: "trash",
                  accessibility: "Delete",
                  selector: #selector(handleDelete(_:)), action: .deleteToTrash)
        addSeparator()
        // Go
        addButton(symbol: "square.grid.2x2",
                  accessibility: "Show in Browser",
                  selector: #selector(handleShowInBrowser(_:)), action: .showInBrowser)
        addSeparator()
        // Panel
        addButton(symbol: "info.circle",
                  accessibility: "Inspector",
                  selector: #selector(handleInfo(_:)), action: .toggleInspector)
        addButton(symbol: "arrow.down.right.and.arrow.up.left",
                  accessibility: "Exit full screen",
                  selector: #selector(handleExitFullScreen(_:)), action: .toggleFullscreen)
    }

    /// 32 pt buttons, 4 pt gaps; a group gap is 12 pt including the 1 pt
    /// hairline.
    static let buttonSize: CGFloat = 32
    static let buttonGap: CGFloat = 4
    static let zoomMenuWidth: CGFloat = 48

    // MARK: - Zoom pull-down

    /// Builds the View menu the zoom button opens. Set by the window.
    var zoomMenuProvider: (() -> NSMenu?)?
    private var zoomButton: HUDButton?

    private func addZoomMenuButton() {
        let btn = HUDButton(symbol: "plus.magnifyingglass", accessibility: "Zoom")
        btn.target = self
        btn.action = #selector(handleZoomMenu(_:))
        btn.toolTip = "Zoom"
        btn.setAccessibilityIdentifier("toolbar.zoomMenu")
        btn.setAccessibilityHelp("Opens the zoom menu")
        btn.translatesAutoresizingMaskIntoConstraints = false
        // The small arrow after the glyph marks it as a menu.
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down",
                                                 accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(chevron)
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: Self.zoomMenuWidth),
            btn.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            chevron.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        buttonStack.addArrangedSubview(btn)
        buttonsByAction[Self.key(for: .zoomMenu)] = btn
        zoomButton = btn
    }

    @objc private func handleZoomMenu(_ sender: Any?) {
        showZoomMenu()
    }

    /// Opens the View menu under the zoom button; the capsule stays up
    /// while it is open.
    func showZoomMenu() {
        guard let button = zoomButton, let menu = zoomMenuProvider?() else { return }
        holdsOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        holdsOpen = false
    }

    // MARK: - Per-button target/action methods (issue #10 fix)
    //
    // Each button gets its OWN @objc selector wired to a specific handler.
    // The previous implementation used a single `handleButton(_:)`
    // dispatcher with an `objc_setAssociatedObject` lookup — if the
    // associated object was missing (e.g. memory pressure during an
    // animation, or the lookup key rebinding across stack churn), the
    // dispatch silently swallowed the click. Explicit 1:1 selectors
    // eliminate that whole class of bug.

    @objc private func handlePrev(_ sender: Any?)        { actionDispatcher?(.prevImage) }
    @objc private func handleNext(_ sender: Any?)        { actionDispatcher?(.nextImage) }
    @objc private func handleRotateLeft(_ sender: Any?)  { actionDispatcher?(.rotateLeft) }
    @objc private func handleRotateRight(_ sender: Any?) { actionDispatcher?(.rotateRight) }
    @objc private func handleShowInBrowser(_ sender: Any?) { actionDispatcher?(.showInBrowser) }
    @objc private func handleExitFullScreen(_ sender: Any?) { actionDispatcher?(.toggleFullscreen) }
    @objc private func handleInfo(_ sender: Any?)        { actionDispatcher?(.toggleInspector) }
    @objc private func handleShare(_ sender: Any?)       { actionDispatcher?(.share) }
    @objc private func handleEdit(_ sender: Any?)        { actionDispatcher?(.openEditMode) }
    @objc private func handleDelete(_ sender: Any?)      { actionDispatcher?(.deleteToTrash) }

    /// The menu command a toolbar button runs, for its tooltip.
    static func command(for action: ViewerAction) -> ShrikeCommand? {
        switch action {
        case .prevImage: return .previousImage
        case .nextImage: return .nextImage
        case .zoomBestFit: return .zoomBestFit
        case .zoomActualSize: return .actualSize
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .rotateLeft: return .rotateLeft
        case .rotateRight: return .rotateRight
        case .toggleFlag: return .toggleFlag
        case .toggleInspector: return .toggleInspector
        case .toggleHistogram: return .toggleHistogram
        case .share: return .share
        case .openEditMode: return .editImage
        case .deleteToTrash: return .moveToTrash
        case .showInBrowser: return .showInBrowser
        case .toggleFullscreen: return .toggleFullScreen
        case .toggleRAWFile: return .toggleRAWFile
        case .unpinAllPanels: return .unpinAllPanels
        default: return nil
        }
    }

    /// The tooltip title where it differs from the command's own title.
    static func tooltipTitle(for action: ViewerAction) -> String? {
        switch action {
        case .toggleFullscreen: return "Exit Full Screen"
        default: return nil
        }
    }

    private func addButton(
        symbol: String,
        accessibility: String,
        selector: Selector,
        action: ViewerAction
    ) {
        // Borderless 28 × 28, 15 pt symbol, `labelColor`,
        // hover platter (same on macOS 14 / 15).
        let btn = HUDButton(symbol: symbol, accessibility: accessibility)
        btn.target = self
        btn.action = selector
        if let command = Self.command(for: action) {
            LiveTooltips.shared.bind(btn, command: command, context: .viewer,
                                     title: Self.tooltipTitle(for: action))
        } else {
            btn.toolTip = accessibility
        }
        btn.setAccessibilityIdentifier("toolbar.\(action)")
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            btn.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        buttonStack.addArrangedSubview(btn)
        buttonsByAction[Self.key(for: action)] = btn
    }

    /// Why Edit is off, as a second tooltip line (nil: none).
    func setEditExtraLine(_ line: String?) {
        guard let btn = buttonsByAction[Self.key(for: .openEditMode)] else { return }
        LiveTooltips.shared.setExtraLine(line, on: btn)
    }

    private func addSeparator() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 20),
        ])
        // 12 pt group gap including the 1 pt hairline: 5 + 1 + 6.
        if let before = buttonStack.arrangedSubviews.last { buttonStack.setCustomSpacing(5, after: before) }
        buttonStack.addArrangedSubview(v)
        buttonStack.setCustomSpacing(6, after: v)
    }

    // MARK: - Test seams

    /// Test seam — ordered list of ViewerActions each button dispatches
    /// (excluding separators). Lets issue-10 tests assert that the
    /// toolbar has zoom-in at slot 5, zoom-out at slot 6, rotate-left at
    /// slot 7, rotate-right at slot 8, etc.
    internal func buttonActionsForTesting() -> [ViewerAction] {
        buttonStack.arrangedSubviews.compactMap { view -> ViewerAction? in
            guard let btn = view as? NSButton else { return nil }
            let ident = btn.accessibilityIdentifier()
            guard ident.hasPrefix("toolbar.") else { return nil }
            return actionFromIdentifier(ident)
        }
    }

    /// Test seam — returns the button for a given accessibility id
    /// (e.g. "toolbar.zoomOut"). Used by hit-test tests.
    internal func buttonWithIdentifierForTesting(_ ident: String) -> NSButton? {
        buttonStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == ident }
    }

    /// Test seam — (target, action) pair for the button that dispatches
    /// `action`. Lets routing tests assert that each visible button has
    /// a unique selector (issue #10 misrouting diagnosis).
    internal func targetActionForButtonTesting(
        _ action: ViewerAction
    ) -> (AnyObject?, Selector?)? {
        guard let btn = buttonForAction(action) else { return nil }
        return (btn.target, btn.action)
    }

    /// Test seam — reduce ViewerAction identifier to the enum case. We
    /// can't recover associated values from this identifier alone, but
    /// the top-level enum cases we care about here are all no-associated
    /// values (nav/zoom/rotate/share/etc.).
    private func actionFromIdentifier(_ ident: String) -> ViewerAction? {
        let tail = String(ident.dropFirst("toolbar.".count))
        switch tail {
        case "prevImage":       return .prevImage
        case "nextImage":       return .nextImage
        case "zoomMenu":        return .zoomMenu
        case "showInBrowser":   return .showInBrowser
        case "toggleFullscreen": return .toggleFullscreen
        case "rotateLeft":      return .rotateLeft
        case "rotateRight":     return .rotateRight
        case "toggleInspector": return .toggleInspector
        case "share":           return .share
        case "openEditMode":    return .openEditMode
        case "deleteToTrash":   return .deleteToTrash
        default:                return nil
        }
    }

    /// Test seam — the SF Symbol names of the buttons, in order.
    internal static let symbolNamesForTesting: [String] = [
        "chevron.left", "chevron.right", "plus.magnifyingglass",
        "rotate.left", "rotate.right",
        "square.and.arrow.up", "slider.horizontal.3", "trash",
        "square.grid.2x2", "info.circle", "arrow.down.right.and.arrow.up.left",
    ]

    /// Test seam — a capsule menu opens / closes.
    internal func setHoldsOpenForTesting(_ flag: Bool) { holdsOpen = flag }

    /// Test seam — content-container frame.
    internal var contentContainerFrameForTesting: CGRect { contentContainer.frame }
}

// MARK: - NSSharingServicePickerDelegate

extension ViewerToolbar: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        // Called once the picker closes (service is nil when dismissed).
        Task { @MainActor [weak self] in self?.holdsOpen = false }
    }
}
