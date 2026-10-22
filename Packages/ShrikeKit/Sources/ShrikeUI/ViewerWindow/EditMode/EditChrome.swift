//
//  EditChrome.swift
//  ShrikeUI
//
//  Edit mode chrome: windowed, the edit toolbar swapped
//  into `window.toolbar`; full screen, the edit capsule.
//  Both show the same items in the same order and read one
//  `EditChromeState`; both send one `EditChromeAction`.
//

import AppKit

/// What the edit chrome shows. Pure value, compared to skip redraws.
struct EditChromeState: Equatable {
    /// Nil = no tool yet (E / ⌘E / Edit land on no tool).
    var tool: EditTool? = nil
    var canUndo = false
    var canRedo = false
    /// Effective session content differs from entry ("Unsaved changes").
    var hasEdits = false
    /// Valid focused or unapplied tool edits change the primary consequence, not recipe history.
    var hasPendingToolEdits = false
    var requiresCopy = false
    var isSaving = false
    /// The Save panel is open and the user has not chosen yet. The edit is
    /// still locked (`isSaving`), but nothing is being written, so the
    /// button keeps its normal title.
    var isAwaitingDestination = false
    var isTransitioning = false
    var acceptsInput: Bool { !isSaving && !isTransitioning }
    var savePolicy = "Changes will replace this file. An original backup is kept."
    var primaryTitle: String { (isSaving && !isAwaitingDestination) ? "Saving…" : (!(hasEdits || hasPendingToolEdits) ? "Done" : (requiresCopy ? "Save Copy…" : "Save Changes")) }

    /// Window subtitle in edit mode.
    var subtitle: String { hasEdits ? "Editing · Unsaved changes" : "Editing" }
}

/// Everything the edit chrome can ask for.
enum EditChromeAction: Equatable {
    case cancel
    case selectTool(EditTool)
    case undo
    case redo
    case reset
    case done
    case saveCopy
}

/// Tool picker order, symbols, names and key letters.
/// Levels joins after Color, so the picker
/// always shows the tool in use.
enum EditChromeTools {
    static let order: [EditTool] = [.crop, .rotate, .resize, .color, .levels]

    static func symbol(_ tool: EditTool) -> String {
        switch tool {
        case .crop: return "crop"
        case .rotate: return "crop.rotate"
        case .resize: return "arrow.up.left.and.arrow.down.right.square"
        case .color: return "slider.horizontal.3"
        case .levels: return "slider.horizontal.below.rectangle"
        }
    }

    static func name(_ tool: EditTool) -> String {
        switch tool {
        case .crop: return "Crop"
        case .rotate: return "Rotate"
        case .resize: return "Resize"
        case .color: return "Color"
        case .levels: return "Levels"
        }
    }

    static func key(_ tool: EditTool) -> String {
        switch tool {
        case .crop: return "C"
        case .rotate: return "R"
        case .resize: return "S"
        case .color: return "J"
        // Levels has no bare key; its key is the menu's ⇧⌘L / ⌃L.
        case .levels: return ""
        }
    }

    /// "Crop  ·  C". Levels reads the live preset: "Levels  ·  ⇧⌘L".
    @MainActor static func tooltip(_ tool: EditTool) -> String {
        if tool == .levels {
            return LiveTooltips.text(.levels, context: .viewer, preset: ShortcutTable.livePreset, title: name(tool))
        }
        return "\(name(tool))  ·  \(key(tool))"
    }

    static func image(_ tool: EditTool) -> NSImage {
        NSImage(systemSymbolName: symbol(tool), accessibilityDescription: name(tool)) ?? NSImage()
    }
}

// MARK: - The tool picker (window toolbar and capsule share it)

/// The five edit tools as one icon-only, single-choice control (spec 26 §1.3).
/// The window's toolbar item and the full-screen capsule use this one class.
/// It is drawn here, not by `NSSegmentedControl`: on macOS 26 the toolbar
/// ignores a segmented control's bezel colour and paints the chosen segment
/// grey, so the accent platter would never show. Nothing selected
/// (`selectedSegment == -1`) until a tool is chosen.
///
/// Accessibility: a radio group named "Tool"; each segment is a radio button
/// named after its tool, value 1 when chosen, and it can be pressed.
/// Keyboard (when the picker has focus): Left / Right choose the previous /
/// next tool, Space chooses the focused one.
@MainActor
final class EditToolPicker: NSControl {

    static var segmentWidth: CGFloat { ChromeTypography.targetHeight + 4 }
    static var height: CGFloat { ChromeTypography.targetHeight }
    /// The active tool's platter. 0.2.10 audit item 4: at 0.30 the fill was
    /// 1.7:1 against the dark bar and read grey (WCAG 1.4.11 asks 3:1 for the
    /// state of a control). 0.62 is about 3.1:1 on (17,17,17); the ring is
    /// the guarantee when a user's accent colour is darker.
    static let platterAlpha: CGFloat = 0.62
    /// The ring around the chosen platter: the accent mark at full strength.
    static let ringWidth: CGFloat = 1

    /// Fires with the tool the user clicked.
    var onPick: ((EditTool) -> Void)?

    /// The platter of the chosen segment (accent at `platterAlpha`).
    var selectedSegmentBezelColor: NSColor? {
        ShrikeAccent.mark.withAlphaComponent(Self.platterAlpha)
    }

    var selectedSegment = -1 {
        didSet {
            guard selectedSegment != oldValue else { return }
            for (i, seg) in segments.enumerated() { seg.isChosen = (i == selectedSegment) }
        }
    }
    private var focusedSegment = 0
    private let segments: [SegmentView]

    var segmentCount: Int { segments.count }

    init() {
        let tools = EditChromeTools.order
        segments = tools.map { SegmentView(tool: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(tools.count) * Self.segmentWidth, height: Self.height))
        for (i, seg) in segments.enumerated() {
            seg.picker = self
            seg.index = i
            addSubview(seg)
            if tools[i] == .levels {
                LiveTooltips.shared.bind(seg, command: .levels, context: .viewer,
                                         title: EditChromeTools.name(tools[i]))
            } else {
                seg.toolTip = EditChromeTools.tooltip(tools[i])
            }
        }
        target = self
        action = #selector(picked)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Tool")
        setAccessibilityChildren(segments)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: CGFloat(tools.count) * Self.segmentWidth).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(segments.count) * Self.segmentWidth, height: Self.height)
    }

    override func layout() {
        super.layout()
        for (i, seg) in segments.enumerated() {
            seg.frame = NSRect(x: CGFloat(i) * Self.segmentWidth, y: 0, width: Self.segmentWidth, height: bounds.height)
        }
    }

    // MARK: Segmented-control surface (tests and callers)

    func width(forSegment i: Int) -> CGFloat { segments.indices.contains(i) ? Self.segmentWidth : 0 }
    func image(forSegment i: Int) -> NSImage? { segments.indices.contains(i) ? segments[i].glyph : nil }
    /// Icon-only: no segment has a text label.
    func label(forSegment i: Int) -> String? { "" }
    func toolTip(forSegment i: Int) -> String? { segments.indices.contains(i) ? segments[i].toolTip : nil }
    func isEnabled(forSegment i: Int) -> Bool { segments.indices.contains(i) }
    /// The segment views (tests: pixel and hover checks).
    var segmentViewsForTesting: [NSView] { segments }

    /// Lights the segment of `tool`; nil lights nothing.
    func show(tool: EditTool?) {
        let index = tool.flatMap { EditChromeTools.order.firstIndex(of: $0) } ?? -1
        if index >= 0 { focusedSegment = index }
        selectedSegment = index
    }

    /// A click or key chose segment `i`.
    fileprivate func choose(_ i: Int) {
        guard segments.indices.contains(i) else { return }
        focusedSegment = i
        selectedSegment = i
        _ = sendAction(action, to: target)
    }

    @objc private func picked() {
        guard EditChromeTools.order.indices.contains(selectedSegment) else { return }
        onPick?(EditChromeTools.order[selectedSegment])
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: choose(max(0, (selectedSegment < 0 ? focusedSegment : selectedSegment) - 1))
        case 124: choose(min(segments.count - 1, (selectedSegment < 0 ? focusedSegment : selectedSegment) + 1))
        case 49: choose(focusedSegment)
        default: super.keyDown(with: event)
        }
    }

    // MARK: One segment

    /// One icon with its platter. A plain view (not a button), so the
    /// toolbar cannot restyle it.
    final class SegmentView: NSView {
        let tool: EditTool
        weak var picker: EditToolPicker?
        var index = 0
        let glyph: NSImage
        private let imageView = NSImageView()
        private var area: NSTrackingArea?
        private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
        private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
        var isChosen = false {
            didSet {
                guard isChosen != oldValue else { return }
                needsDisplay = true
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }

        init(tool: EditTool) {
            self.tool = tool
            glyph = EditChromeTools.image(tool)
            super.init(frame: .zero)
            imageView.image = glyph
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            imageView.contentTintColor = .labelColor
            imageView.imageScaling = .scaleNone
            imageView.setAccessibilityElement(false)
            addSubview(imageView)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(EditChromeTools.name(tool))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("programmatic only") }

        override var isFlipped: Bool { false }
        override func layout() {
            super.layout()
            imageView.frame = bounds
        }

        /// The platter's rect: inside the segment, like the toolbar hover.
        var platterRect: NSRect { bounds.insetBy(dx: ToolbarHover.inset, dy: ToolbarHover.inset) }

        override func draw(_ dirtyRect: NSRect) {
            let r = platterRect
            let path = NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2, yRadius: min(r.width, r.height) / 2)
            if isChosen {
                ShrikeAccent.mark.withAlphaComponent(EditToolPicker.platterAlpha).setFill()
                path.fill()
                let w = EditToolPicker.ringWidth
                let inner = r.insetBy(dx: w / 2, dy: w / 2)
                let ring = NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2)
                ring.lineWidth = w
                ShrikeAccent.mark.setStroke()
                ring.stroke()
            }
            if hovered || pressed {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let base: NSColor = dark ? .white : .black
                base.withAlphaComponent((dark ? ToolbarHover.darkAlpha : ToolbarHover.lightAlpha) * (pressed ? 1.6 : 1)).setFill()
                path.fill()
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                     owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }

        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func viewDidHide() { super.viewDidHide(); hovered = false; pressed = false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            pressed = true
            // Track until release; a click chooses on mouse-up inside.
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let inside = bounds.contains(convert(next.locationInWindow, from: nil))
                if next.type == .leftMouseUp {
                    pressed = false
                    if inside { picker?.choose(index) }
                    return
                }
                pressed = inside
            }
            pressed = false
        }

        override func accessibilityValue() -> Any? { isChosen ? 1 : 0 }
        override func accessibilityHelp() -> String? { toolTip }
        override func accessibilityPerformPress() -> Bool { picker?.choose(index); return true }
        override func isAccessibilitySelected() -> Bool { isChosen }
        override var focusRingMaskBounds: NSRect { bounds }

        // Test seams.
        var isHoveredForTesting: Bool { get { hovered } set { hovered = newValue } }
    }
}

// MARK: - Windowed: NSToolbar

@MainActor
final class EditToolbarController: NSObject, NSToolbarDelegate {

    static let toolbarIdentifier = NSToolbar.Identifier("shrike.viewer.editToolbar")

    enum ItemID {
        static let cancel = NSToolbarItem.Identifier("shrike.edit.cancel")
        static let tools = NSToolbarItem.Identifier("shrike.edit.tools")
        static let undoRedo = NSToolbarItem.Identifier("shrike.edit.undoRedo")
        static let reset = NSToolbarItem.Identifier("shrike.edit.reset")
        static let saveCopy = NSToolbarItem.Identifier("shrike.edit.saveCopy")
        static let done = NSToolbarItem.Identifier("shrike.edit.done")
    }

    /// Default item order, left to right.
    static let itemOrder: [NSToolbarItem.Identifier] = [
        ItemID.cancel, .flexibleSpace, ItemID.tools, ItemID.undoRedo,
        .flexibleSpace, ItemID.reset, ItemID.saveCopy, ItemID.done,
    ]

    /// Which items leave the bar first in a narrow window (spec 26 §1.4).
    static func visibilityPriority(_ id: NSToolbarItem.Identifier) -> NSToolbarItem.VisibilityPriority {
        switch id {
        case ItemID.cancel, ItemID.done: return .high
        case ItemID.tools: return .standard
        default: return .low
        }
    }

    var onAction: ((EditChromeAction) -> Void)?

    let toolbar: NSToolbar
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let saveCopyButton = NSButton(title: "Save Copy…", target: nil, action: nil)
    let toolPicker = EditToolPicker()
    private(set) var toolItem: NSToolbarItem?
    private(set) var undoGroup: NSToolbarItemGroup?
    private var doneItem: NSToolbarItem?
    private var primaryTitleMinimumWidth: NSLayoutConstraint?
    private var syncingSaveCopyItem = false
    private var constructingToolbarItemDepth = 0
    private var saveCopyMenuItem: NSMenuItem?
    private(set) var chromeState = EditChromeState()

    override init() {
        // Native toolbars with the same identifier synchronize item insertions
        // even without autosaving. Save actions belong to this edit session.
        toolbar = NSToolbar(identifier: Self.toolbarIdentifier + "." + UUID().uuidString)
        super.init()
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        for button in [cancelButton, resetButton, saveCopyButton, doneButton] {
            button.bezelStyle = .push
            button.target = self
        }
        cancelButton.action = #selector(cancelClicked)
        resetButton.action = #selector(resetClicked)
        doneButton.action = #selector(doneClicked)
        saveCopyButton.action = #selector(saveCopyClicked)
        // Return = Done; the key also gives the default button look.
        doneButton.keyEquivalent = "\r"
        // The same accent call as Apply and the capsule's Done, on every
        // macOS: one blue per window. (The item's `.prominent` style drew
        // pure (0, 120, 255) on 26.5 while the buttons drew a paler
        // violet-blue.)
        doneButton.useAccentFill()
        // Keys come from the shortcut table.
        LiveTooltips.shared.bind(cancelButton, command: .exitEditMode, context: .editMode, title: "Cancel")
        resetButton.toolTip = "Reset All Edits"
        LiveTooltips.shared.bind(doneButton, command: .editDone, context: .editMode)
        toolPicker.onPick = { [weak self] tool in self?.onAction?(.selectTool(tool)) }
        toolbar.delegate = self
        apply(chromeState)
    }

    func apply(_ newState: EditChromeState) {
        chromeState = newState
        for control in [cancelButton, resetButton, saveCopyButton, doneButton] { control.isEnabled = newState.acceptsInput }
        doneButton.setAccentTitle(newState.primaryTitle)
        updatePrimaryTitleMinimumWidth()
        doneButton.setAccessibilityLabel(newState.primaryTitle)
        doneButton.toolTip = newState.savePolicy
        doneItem?.label = newState.primaryTitle
        doneItem?.paletteLabel = newState.primaryTitle
        doneItem?.menuFormRepresentation?.title = newState.primaryTitle
        doneItem?.menuFormRepresentation?.isEnabled = newState.acceptsInput
        saveCopyButton.isHidden = newState.requiresCopy || !newState.hasEdits
        syncSaveCopyParticipation()
        saveCopyMenuItem?.isEnabled = newState.acceptsInput
        toolPicker.isEnabled = newState.acceptsInput
        resetButton.isEnabled = (newState.hasEdits || newState.canUndo) && newState.acceptsInput
        toolPicker.show(tool: newState.tool)
        if let menu = toolItem?.menuFormRepresentation?.submenu {
            for (i, entry) in menu.items.enumerated() {
                entry.state = EditChromeTools.order.indices.contains(i)
                    && newState.tool == EditChromeTools.order[i] ? .on : .off
            }
        }
        if let menu = undoGroup?.menuFormRepresentation?.submenu, menu.items.count == 2 {
            menu.items[0].isEnabled = newState.canUndo && newState.acceptsInput
            menu.items[1].isEnabled = newState.canRedo && newState.acceptsInput
        }
        resetMenuItem?.isEnabled = (newState.hasEdits || newState.canUndo) && newState.acceptsInput
        if let group = undoGroup, group.subitems.count == 2 {
            group.subitems[0].isEnabled = newState.canUndo && newState.acceptsInput
            group.subitems[1].isEnabled = newState.canRedo && newState.acceptsInput
        }
    }

    /// AppKit's glass custom view can retain its first content-size constraint
    /// after an attributed title changes. Supply the current native measurement
    /// before the toolbar calculates item widths; height remains native.
    private func updatePrimaryTitleMinimumWidth() {
        let width = doneButton.intrinsicContentSize.width
        guard width.isFinite, width > 0 else { return }
        if let constraint = primaryTitleMinimumWidth {
            if abs(constraint.constant - width) > 0.01 { constraint.constant = width }
        } else {
            let constraint = doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
            constraint.identifier = "shrike.edit.primaryTitleMinimumWidth"
            constraint.isActive = true
            primaryTitleMinimumWidth = constraint
        }
    }

    /// Hide the native wrapper too, including its overflow entry, on macOS 14.
    /// Delegate construction calls apply; keep that nested update idempotent.
    private func syncSaveCopyParticipation() {
        guard !syncingSaveCopyItem, constructingToolbarItemDepth == 0 else { return }
        syncingSaveCopyItem = true
        defer { syncingSaveCopyItem = false }
        let items = toolbar.items
        let index = items.firstIndex { $0.itemIdentifier == ItemID.saveCopy }
        if chromeState.hasEdits && !chromeState.requiresCopy {
            if index == nil, let primary = items.firstIndex(where: { $0.itemIdentifier == ItemID.done }) {
                toolbar.insertItem(withItemIdentifier: ItemID.saveCopy, at: primary)
            }
        } else if let index {
            toolbar.removeItem(at: index)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemOrder.filter { $0 != ItemID.saveCopy || (chromeState.hasEdits && !chromeState.requiresCopy) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemOrder }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // AppKit may still own an uncommitted insertion during this callback.
        // Read/render state here; only an external apply reconciles membership.
        constructingToolbarItemDepth += 1
        defer { constructingToolbarItemDepth -= 1 }
        switch itemIdentifier {
        case ItemID.cancel:
            return viewItem(itemIdentifier, cancelButton, label: "Cancel", menuTitle: "Cancel", action: #selector(cancelClicked))
        case ItemID.reset:
            let item = viewItem(itemIdentifier, resetButton, label: "Reset", menuTitle: "Reset All Edits", action: #selector(resetClicked))
            resetMenuItem = item.menuFormRepresentation
            resetMenuItem?.isEnabled = chromeState.hasEdits || chromeState.canUndo
            return item
        case ItemID.saveCopy:
            let item = viewItem(itemIdentifier, saveCopyButton, label: "Save Copy…", menuTitle: "Save Copy…", action: #selector(saveCopyClicked))
            saveCopyMenuItem = item.menuFormRepresentation
            saveCopyMenuItem?.isEnabled = chromeState.acceptsInput
            return item
        case ItemID.done:
            // The button carries the accent fill itself (`useAccentFill`).
            let item = viewItem(itemIdentifier, doneButton, label: chromeState.primaryTitle,
                                menuTitle: chromeState.primaryTitle, action: #selector(doneClicked))
            doneItem = item
            apply(chromeState)
            return item
        case ItemID.tools:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = toolPicker
            item.label = "Tool"
            item.paletteLabel = "Tool"
            item.autovalidates = false
            item.visibilityPriority = Self.visibilityPriority(itemIdentifier)
            // The overflow form: a "Tool" submenu with a check on the current tool.
            let form = NSMenuItem(title: "Tool", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Tool")
            for (i, tool) in EditChromeTools.order.enumerated() {
                let entry = NSMenuItem(title: EditChromeTools.name(tool), action: #selector(toolMenuPicked(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = i
                sub.addItem(entry)
            }
            form.submenu = sub
            item.menuFormRepresentation = form
            toolItem = item
            apply(chromeState)
            return item
        case ItemID.undoRedo:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo") ?? NSImage(),
                    NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo") ?? NSImage(),
                ],
                selectionMode: .momentary,
                labels: ["Undo", "Redo"],
                target: self, action: #selector(undoRedoPicked(_:))
            )
            group.label = "Undo"
            if group.subitems.count == 2 {
                LiveTooltips.shared.bind(group.subitems[0], command: .undo, context: .editMode)
                LiveTooltips.shared.bind(group.subitems[1], command: .redo, context: .editMode)
                for sub in group.subitems { sub.autovalidates = false }
            }
            group.autovalidates = false
            group.visibilityPriority = Self.visibilityPriority(itemIdentifier)
            let form = NSMenuItem(title: "Undo / Redo", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Undo / Redo")
            for (title, sel) in [("Undo", #selector(undoMenu)), ("Redo", #selector(redoMenu))] {
                let entry = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                entry.target = self
                sub.addItem(entry)
            }
            form.submenu = sub
            group.menuFormRepresentation = form
            undoGroup = group
            apply(chromeState)
            return group
        default:
            return nil
        }
    }

    private func viewItem(_ id: NSToolbarItem.Identifier, _ button: NSButton, label: String,
                          menuTitle: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        item.autovalidates = false
        item.visibilityPriority = Self.visibilityPriority(id)
        let form = NSMenuItem(title: menuTitle, action: action, keyEquivalent: "")
        form.target = self
        item.menuFormRepresentation = form
        return item
    }

    /// The Reset row of the overflow menu (enabled with the recipe's edits).
    private var resetMenuItem: NSMenuItem?

    // MARK: Actions

    @objc private func cancelClicked() { onAction?(.cancel) }
    @objc private func resetClicked() { onAction?(.reset) }
    @objc private func doneClicked() { onAction?(.done) }
    @objc private func saveCopyClicked() { onAction?(.saveCopy) }

    @objc private func undoRedoPicked(_ sender: Any?) {
        guard let group = undoGroup else { return }
        onAction?(group.selectedIndex == 1 ? .redo : .undo)
    }

    @objc private func toolMenuPicked(_ sender: NSMenuItem) {
        guard EditChromeTools.order.indices.contains(sender.tag) else { return }
        onAction?(.selectTool(EditChromeTools.order[sender.tag]))
    }
    @objc private func undoMenu() { onAction?(.undo) }
    @objc private func redoMenu() { onAction?(.redo) }
}

// MARK: - Full screen: the edit capsule

@MainActor
final class EditCapsuleView: HUDSurfaceView {

    var onAction: ((EditChromeAction) -> Void)?

    let label = NSTextField(labelWithString: "Editing")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let toolPicker = EditToolPicker()
    let undoRedo = NSSegmentedControl()
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let saveCopyButton = NSButton(title: "Save Copy…", target: nil, action: nil)
    private(set) var chromeState = EditChromeState()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        // The full-screen toolbar capsule in its
        // edit configuration; glass capsule on macOS 26.
        glassShape = .capsule
        setAccessibilityIdentifier("shrike.edit.capsule")
        build()
        apply(EditChromeState())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }

    private func build() {
        label.font = ChromeTypography.font(11)
        label.textColor = .secondaryLabelColor
        for button in [cancelButton, resetButton, saveCopyButton, doneButton] {
            button.bezelStyle = .push
            button.target = self
        }
        cancelButton.action = #selector(cancelClicked)
        resetButton.action = #selector(resetClicked)
        doneButton.action = #selector(doneClicked)
        saveCopyButton.action = #selector(saveCopyClicked)
        // Done is the default button (accent fill on 14/15;
        // Return clicks it once, so the edit keymap never sees Return).
        doneButton.keyEquivalent = "\r"
        // The system accent fill, the same call as the toolbar's Done and Apply.
        doneButton.useAccentFill()
        // Keys come from the shortcut table.
        LiveTooltips.shared.bind(cancelButton, command: .exitEditMode, context: .editMode, title: "Cancel")
        resetButton.toolTip = "Reset All Edits"
        LiveTooltips.shared.bind(doneButton, command: .editDone, context: .editMode)

        undoRedo.segmentCount = 2
        undoRedo.trackingMode = .momentary
        undoRedo.setImage(NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo"), forSegment: 0)
        undoRedo.setImage(NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo"), forSegment: 1)
        LiveTooltips.shared.bind(undoRedo, segment: 0, command: .undo, context: .editMode)
        LiveTooltips.shared.bind(undoRedo, segment: 1, command: .redo, context: .editMode)
        undoRedo.target = self
        undoRedo.action = #selector(undoRedoPicked)

        toolPicker.onPick = { [weak self] tool in self?.onAction?(.selectTool(tool)) }

        let stack = NSStackView(views: [label, cancelButton, toolPicker, undoRedo, resetButton, saveCopyButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Every view under the capsule (tests).
    var allSubviewsForTesting: [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) { for s in v.subviews { out.append(s); walk(s) } }
        walk(self)
        return out
    }

    func apply(_ newState: EditChromeState) {
        chromeState = newState
        doneButton.setAccessibilityLabel(newState.primaryTitle)
        doneButton.toolTip = newState.savePolicy
        saveCopyButton.isHidden = newState.requiresCopy || !newState.hasEdits
        for control in [cancelButton, resetButton, saveCopyButton, doneButton] { control.isEnabled = newState.acceptsInput }
        doneButton.setAccentTitle(newState.primaryTitle)
        toolPicker.isEnabled = newState.acceptsInput
        label.stringValue = newState.subtitle
        resetButton.isEnabled = (newState.hasEdits || newState.canUndo) && newState.acceptsInput
        undoRedo.setEnabled(newState.canUndo && newState.acceptsInput, forSegment: 0)
        undoRedo.setEnabled(newState.canRedo && newState.acceptsInput, forSegment: 1)
        toolPicker.show(tool: newState.tool)
    }

    @objc private func cancelClicked() { onAction?(.cancel) }
    @objc private func resetClicked() { onAction?(.reset) }
    @objc private func doneClicked() { onAction?(.done) }
    @objc private func saveCopyClicked() { onAction?(.saveCopy) }

    @objc private func undoRedoPicked() {
        onAction?(undoRedo.selectedSegment == 1 ? .redo : .undo)
    }
}
