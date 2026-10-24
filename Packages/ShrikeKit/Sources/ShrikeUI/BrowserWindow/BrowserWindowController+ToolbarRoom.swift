//
//  BrowserWindowController+ToolbarRoom.swift
//  ShrikeUI
//
//  Back/Forward, View, Sort and Filter are
//  always in the toolbar, never in the » menu, with the search field
//  closed or open, down to the window's minimum width.
//
//  Measured offscreen (macOS 26, theme-frame layout, `visibleItems`):
//  the toolbar section above the content pane needs about 360 pt for
//  Back/Forward, the title, Sort, Filter and the gaps, plus the View
//  group (56 pt as its pop-up, 119 pt as three segments) plus Search
//  (its field + 8 pt). Search is a plain item whose field is always open
//  (NSSearchToolbarItem would not open beside the
//  inspector's tracking separator); the controller sets the field's width
//  from the room, 110 pt in the narrow layout up to 200 pt.
//  AppKit habit that pushes items into » on its own:
//  - AppKit can budget the View group at its three-segment width even
//    when it then shows the pop-up. So the controller picks the pop-up
//    itself below `threeSegmentsFrom`.
//  The content pane's minimum width keeps room for the narrow layout
//  (View pop-up, narrow open field) with a 40 pt margin.
//

import AppKit

@MainActor
public enum BrowserToolbarRoom {

    /// What the toolbar section above the content pane needs besides the
    /// View group and Search (Back/Forward, title, Sort, Filter, gaps).
    static let fixedItems: CGFloat = 360
    static let viewCollapsed: CGFloat = 56
    static let viewExpanded: CGFloat = 119
    /// Around an open search field (its item's padding).
    static let searchPadding: CGFloat = 8
    /// Kept free on top of the measured sizes (on-screen drawing differs
    /// a little from the offscreen layout).
    static let margin: CGFloat = 40
    /// The search field's width in the narrow layout (the field is
    /// always open).
    public static let searchFieldWidth: CGFloat = 110
    /// The field's width when there is room to spare.
    public static let searchFieldMaximumWidth: CGFloat = 200

    /// The field's width for `room` pt of toolbar: what is left beside the
    /// other items and the View group, between 110 and 200 pt.
    public static func fieldWidth(room: CGFloat) -> CGFloat {
        let view = viewRepresentation(room: room) == .collapsed ? viewCollapsed : viewExpanded
        let free = floor(room - fixedItems - view - searchPadding - margin)
        return min(searchFieldMaximumWidth, max(searchFieldWidth, free))
    }

    /// Toolbar room taken by things that move into the content section
    /// when a side pane is hidden: the window buttons and the sidebar
    /// toggle, or the Inspector button.
    static let sidebarHiddenExtra: CGFloat = 130
    static let inspectorHiddenExtra: CGFloat = 50

    /// The content pane's minimum width: the narrow layout (View pop-up,
    /// open narrow field) plus the margin.
    public static var contentMinimumWidth: CGFloat {
        fixedItems + viewCollapsed + searchFieldWidth + searchPadding + margin
    }

    /// From this much room the View group may show its three segments.
    public static var threeSegmentsFrom: CGFloat {
        fixedItems + viewExpanded + searchFieldWidth + searchPadding + margin
    }

    /// The View group's look for `room` pt of toolbar.
    public static func viewRepresentation(room: CGFloat) -> NSToolbarItemGroup.ControlRepresentation {
        room >= threeSegmentsFrom ? .automatic : .collapsed
    }

    /// The window's narrowest width for the panes that are showing: the
    /// content pane's minimum, plus each shown pane at its minimum, plus (for
    /// each hidden pane) the toolbar room that moves into the content section.
    /// Both panes shown this is 1022 pt; both hidden, 754 pt. Capped at the
    /// display's visible width.
    static func minimumWindowWidth(sidebarShown: Bool, inspectorShown: Bool, visibleWidth: CGFloat? = nil) -> CGFloat {
        let width = contentMinimumWidth
            + (sidebarShown ? BrowserWindowController.sidebarMinimumWidth + 8 : sidebarHiddenExtra)
            + (inspectorShown ? BrowserWindowController.inspectorMinimumWidth : inspectorHiddenExtra)
        return visibleWidth.map { min(width, $0) } ?? width
    }

    /// The room for the items between the tracking separators.
    static func room(contentWidth: CGFloat, sidebarShown: Bool, inspectorShown: Bool) -> CGFloat {
        contentWidth
            - (sidebarShown ? 0 : sidebarHiddenExtra)
            - (inspectorShown ? 0 : inspectorHiddenExtra)
    }
}

extension BrowserWindowController {

    /// Follows the content pane: window resizes, divider drags and pane
    /// toggles all change its frame. (The split view's resize
    /// notification can come before the new frames are set.)
    func observeToolbarRoom() {
        let content = contentController.view
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentPaneFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: content
        )
    }

    @objc func contentPaneFrameDidChange(_ note: Notification) {
        updateToolbarRoom()
        updateMinimumWindowWidth()
    }

    /// A hidden side pane lowers the window's minimum width (audit on-screen
    /// L17: half-screen tiling on a laptop), a shown one raises it again.
    /// (AppKit widens the window itself when a pane is shown in a narrow one.)
    func updateMinimumWindowWidth() {
        guard let window, splitController.splitViewItems.count == 3 else { return }
        let items = splitController.splitViewItems
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.width
        let width = BrowserToolbarRoom.minimumWindowWidth(sidebarShown: !items[0].isCollapsed,
                                                          inspectorShown: !items[2].isCollapsed,
                                                          visibleWidth: visible)
        if window.minSize.width != width { window.minSize = NSSize(width: width, height: window.minSize.height) }
    }

    /// The room above the content pane now.
    var toolbarRoom: CGFloat {
        let items = splitController.splitViewItems
        guard items.count == 3 else { return 0 }
        let content = items[1].viewController.view.frame.width
        return BrowserToolbarRoom.room(contentWidth: content,
                                       sidebarShown: !items[0].isCollapsed,
                                       inspectorShown: !items[2].isCollapsed)
    }

    /// Shows the View group as its pop-up when there is no room for
    /// three segments beside an open search field.
    func updateToolbarRoom() {
        let room = toolbarRoom
        guard room > 0, let group = viewModeGroup else { return }
        let representation = BrowserToolbarRoom.viewRepresentation(room: room)
        if group.controlRepresentation != representation { group.controlRepresentation = representation }
        let width = BrowserToolbarRoom.fieldWidth(room: room)
        if searchFieldWidthConstraint.constant != width { searchFieldWidthConstraint.constant = width }
    }
}
