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
//  Capsule: 44 pt high, no pin (the capsule shows with the
//  bottom zone, with a pinned filmstrip, or while its menu is open).
//  Histogram `chart.bar.xaxis`; Info is "Inspector" (`info.circle`).
//   * 14 buttons + 4 separators in one NSStackView. Each button has an
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
        buttonStack.spacing = 6
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fill
        buttonStack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentContainer.heightAnchor.constraint(equalToConstant: Self.height),
        ])

        // Authoritative inventory (14 buttons + 4 separators).
        // Nav
        addButton(symbol: "chevron.left",  accessibility: "Previous image",
                  selector: #selector(handlePrev(_:)), action: .prevImage)
        addButton(symbol: "chevron.right", accessibility: "Next image",
                  selector: #selector(handleNext(_:)), action: .nextImage)
        addSeparator()
        // Zoom
        addButton(symbol: "arrow.up.left.and.down.right.magnifyingglass",
                  accessibility: "Fit",
                  selector: #selector(handleFit(_:)), action: .zoomBestFit)
        addButton(symbol: "1.magnifyingglass",
                  accessibility: "Actual size",
                  selector: #selector(handleActualSize(_:)), action: .zoomActualSize)
        addButton(symbol: "plus.magnifyingglass",
                  accessibility: "Zoom in",
                  selector: #selector(handleZoomIn(_:)), action: .zoomIn)
        addButton(symbol: "minus.magnifyingglass",
                  accessibility: "Zoom out",
                  selector: #selector(handleZoomOut(_:)), action: .zoomOut)
        addSeparator()
        // Both rail and toolbar carry rotate; the rail copy is
        // the primary source in edit sessions, the toolbar copy is the
        // ambient affordance when no edit is open.
        addButton(symbol: "rotate.left",
                  accessibility: "Rotate left",
                  selector: #selector(handleRotateLeft(_:)), action: .rotateLeft)
        addButton(symbol: "rotate.right",
                  accessibility: "Rotate right",
                  selector: #selector(handleRotateRight(_:)), action: .rotateRight)
        addSeparator()
        // Flag / info / histogram
        addButton(symbol: "flag",
                  accessibility: "Flag",
                  selector: #selector(handleFlag(_:)), action: .toggleFlag)
        addButton(symbol: "info.circle",
                  accessibility: "Inspector",
                  selector: #selector(handleInfo(_:)), action: .toggleInspector)
        addButton(symbol: "chart.bar.xaxis",
                  accessibility: "Histogram",
                  selector: #selector(handleHistogram(_:)), action: .toggleHistogram)
        addSeparator()
        // Share (replaces the broken openExternalEditor slot) + delete.
        addButton(symbol: "square.and.arrow.up",
                  accessibility: "Share",
                  selector: #selector(handleShare(_:)), action: .share)
        // A visible way into edit mode in full screen.
        addButton(symbol: "slider.horizontal.3",
                  accessibility: "Edit",
                  selector: #selector(handleEdit(_:)), action: .openEditMode)
        addButton(symbol: "trash",
                  accessibility: "Delete",
                  selector: #selector(handleDelete(_:)), action: .deleteToTrash)
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
    @objc private func handleFit(_ sender: Any?)         { actionDispatcher?(.zoomBestFit) }
    @objc private func handleActualSize(_ sender: Any?)  { actionDispatcher?(.zoomActualSize) }
    @objc private func handleZoomIn(_ sender: Any?)      { actionDispatcher?(.zoomIn) }
    @objc private func handleZoomOut(_ sender: Any?)     { actionDispatcher?(.zoomOut) }
    @objc private func handleRotateLeft(_ sender: Any?)  { actionDispatcher?(.rotateLeft) }
    @objc private func handleRotateRight(_ sender: Any?) { actionDispatcher?(.rotateRight) }
    @objc private func handleFlag(_ sender: Any?)        { actionDispatcher?(.toggleFlag) }
    @objc private func handleInfo(_ sender: Any?)        { actionDispatcher?(.toggleInspector) }
    @objc private func handleHistogram(_ sender: Any?)   { actionDispatcher?(.toggleHistogram) }
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
            LiveTooltips.shared.bind(btn, command: command, context: .viewer)
        } else {
            btn.toolTip = accessibility
        }
        btn.setAccessibilityIdentifier("toolbar.\(action)")
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: HUDButton.size),
            btn.heightAnchor.constraint(equalToConstant: HUDButton.size),
        ])
        buttonStack.addArrangedSubview(btn)
        buttonsByAction[Self.key(for: action)] = btn
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
        buttonStack.addArrangedSubview(v)
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
        case "zoomBestFit":     return .zoomBestFit
        case "zoomActualSize":  return .zoomActualSize
        case "zoomIn":          return .zoomIn
        case "zoomOut":         return .zoomOut
        case "rotateLeft":      return .rotateLeft
        case "rotateRight":     return .rotateRight
        case "toggleFlag":      return .toggleFlag
        case "toggleInspector": return .toggleInspector
        case "toggleHistogram": return .toggleHistogram
        case "share":           return .share
        case "openEditMode":    return .openEditMode
        case "deleteToTrash":   return .deleteToTrash
        default:                return nil
        }
    }

    /// Test seam — the SF Symbol names of the buttons, in order.
    internal static let symbolNamesForTesting: [String] = [
        "chevron.left", "chevron.right",
        "arrow.up.left.and.down.right.magnifyingglass", "1.magnifyingglass",
        "plus.magnifyingglass", "minus.magnifyingglass",
        "rotate.left", "rotate.right", "flag", "info.circle", "chart.bar.xaxis",
        "square.and.arrow.up", "slider.horizontal.3", "trash",
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
