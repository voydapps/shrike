//
//  ViewerSplitController.swift
//  ShrikeUI
//
//  The windowed viewer's content is a split view: the canvas,
//  then the system inspector item (280 pt, 240–360). The inspector view is
//  built on its first expand, so opening a photo reads no EXIF. It shows
//  the same model as the full-screen HUD inspector.
//

import AppKit
import ShrikeCore
import SwiftUI

extension Notification.Name {
    /// The "Hide the toolbar when the pointer is still" pref changed.
    static let shrikeToolbarAutoHideChanged = Notification.Name("shrike.viewer.toolbarAutoHideChanged")
    /// Settings ▸ Thumbnails ▸ Grid size changed.
    static let shrikeThumbnailSizeChanged = Notification.Name("shrike.thumbnails.sizeChanged")
}

/// The inspector item's controller. `loadView` makes an empty view; the
/// SwiftUI content is built by `materialize()` on the first expand.
@MainActor
final class ViewerInspectorViewController: NSViewController {
    private let model: InspectorViewModel
    private(set) var contentView: NSView?

    init(model: InspectorViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        view.setAccessibilityLabel("Inspector")
    }

    /// Builds the inspector content once.
    func materialize() {
        guard contentView == nil else { return }
        let host = NSHostingView(rootView: InspectorContent(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        // The column's width comes from the split view, never
        // from the SwiftUI content (as in the Browser's inspector pane).
        host.sizingOptions = []
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        contentView = host
    }
}

@MainActor
final class ViewerSplitController: NSSplitViewController {

    let canvasItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    let inspectorController: ViewerInspectorViewController
    /// Told when the inspector opens or closes (first open enables the
    /// shared model's header reads; the image re-fits on its own).
    ///
    /// Assigning the callback replays the current state: `viewDidLoad` opens
    /// the inspector from the pref before any owner can set this, so without
    /// the replay a window that opens with the inspector already shown never
    /// enabled the header reads (empty File / Capture rows).
    var onInspectorShownChanged: ((Bool) -> Void)? {
        didSet { if isInspectorShown { onInspectorShownChanged?(true) } }
    }
    /// The collapsed state to restore when full screen ends.
    private var collapsedBeforeFullScreen: Bool?

    /// The inspector's narrowest column (240–360).
    static let inspectorMinimumWidth: CGFloat = 240
    /// The canvas keeps this much beside the inspector. With the
    /// 240 pt inspector it fills the 480 pt window minimum, so a narrow
    /// window shrinks the inspector toward 240 pt (as the Browser does)
    /// and never pushes it past its column.
    static let canvasMinimumWidth: CGFloat = 240

    init(canvas: NSView, model: InspectorViewModel) {
        let canvasController = NSViewController()
        canvasController.view = canvas
        canvasItem = NSSplitViewItem(viewController: canvasController)
        canvasItem.minimumThickness = Self.canvasMinimumWidth
        inspectorController = ViewerInspectorViewController(model: model)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspectorItem.minimumThickness = Self.inspectorMinimumWidth
        inspectorItem.maximumThickness = 360
        inspectorItem.preferredThicknessFraction = 0
        inspectorItem.canCollapse = true
        // The toggle and the pref stay truthful: a resize never hides it.
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.isCollapsed = !Prefs.viewerInspectorVisibleWindowed
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(canvasItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "shrike.viewer.split"
        // The pref decides the open state for a new window.
        inspectorItem.isCollapsed = !Prefs.viewerInspectorVisibleWindowed
        if !inspectorItem.isCollapsed { inspectorShown(true) }
    }

    var isInspectorShown: Bool { !inspectorItem.isCollapsed }

    /// ⌘I and the toolbar's Inspector item (windowed).
    override func toggleInspector(_ sender: Any?) {
        setInspectorShown(inspectorItem.isCollapsed, animated: true)
    }

    func setInspectorShown(_ shown: Bool, animated: Bool) {
        guard shown != isInspectorShown else { return }
        // A user's own open or close wins over the edit-mode collapse.
        inspectorCollapsedForEdit = false
        if shown { inspectorController.materialize() }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inspectorItem.animator().isCollapsed = !shown
        } else {
            inspectorItem.isCollapsed = !shown
        }
        Prefs.viewerInspectorVisibleWindowed = shown
        inspectorShown(shown)
    }

    private func inspectorShown(_ shown: Bool) {
        if shown { inspectorController.materialize() }
        onInspectorShownChanged?(shown)
    }

    // MARK: Edit mode makes room for the tool panel (spec 26 §5)

    /// The canvas needs the tool panel column (280 + 16), the crop handle
    /// margins and a photo at least 320 pt wide: `EditLayout.minCanvasWidth`
    /// (648 pt, spec 27 V7; it was 360 in spec 26 §5). Narrower than this, the
    /// inspector steps aside while editing.
    static let canvasWidthForEditPanel: CGFloat = EditLayout.minCanvasWidth
    /// True while this controller has collapsed the inspector for editing.
    private(set) var inspectorCollapsedForEdit = false
    private var isEditing = false

    /// The inspector column's width while it is open (0 when collapsed).
    var inspectorColumnWidth: CGFloat {
        guard isInspectorShown else { return 0 }
        let width = inspectorController.view.frame.width
        return width > 0 ? width : 280
    }

    /// Edit mode started or ended. On end, an inspector we collapsed returns.
    func editModeChanged(active: Bool) {
        isEditing = active
        if active {
            // Spec 21b §9 (on-screen L16): the tool panel and the info panel together left
            // the photo about half the window. The info panel steps aside while editing
            // and comes back on exit unless the user opened it again meanwhile.
            guard isInspectorShown else { return }
            inspectorCollapsedForEdit = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                inspectorItem.isCollapsed = true
            }
            inspectorShown(false)
            return
        }
        guard inspectorCollapsedForEdit else { return }
        inspectorCollapsedForEdit = false
        // The pref was never touched, so it still says "open".
        inspectorItem.isCollapsed = false
        inspectorShown(true)
    }

    /// Called on every edit-mode layout. Collapses the inspector when the
    /// canvas is too narrow (also when ⌘I opens it again mid-edit); never
    /// re-opens it until edit mode ends (no flip-flop at the threshold). Not `setInspectorShown`: that writes the pref.
    func editCanvasWidth(_ width: CGFloat) {
        guard isEditing, isInspectorShown, width > 0,
              width < Self.canvasWidthForEditPanel else { return }
        inspectorCollapsedForEdit = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            inspectorItem.isCollapsed = true
        }
        inspectorShown(false)
    }

    // MARK: Full screen

    /// Remembers the state, then collapses with no animation.
    func willEnterFullScreen() {
        collapsedBeforeFullScreen = inspectorItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            inspectorItem.isCollapsed = true
        }
    }

    /// Puts back the state from before full screen.
    func willExitFullScreen() {
        guard let collapsed = collapsedBeforeFullScreen else { return }
        collapsedBeforeFullScreen = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            inspectorItem.isCollapsed = collapsed
        }
        if !collapsed { inspectorShown(true) }
    }
}
