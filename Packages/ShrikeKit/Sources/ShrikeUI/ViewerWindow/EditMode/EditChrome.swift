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
    /// The recipe has operations (Reset enabled, "Unsaved changes").
    var hasEdits = false

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
}

/// Tool picker order, symbols, names and key letters.
/// Levels joins after Color, as on the rail,
/// so the picker always shows the tool in use.
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

// MARK: - Windowed: NSToolbar

@MainActor
final class EditToolbarController: NSObject, NSToolbarDelegate {

    static let toolbarIdentifier = NSToolbar.Identifier("shrike.viewer.editToolbar")

    enum ItemID {
        static let cancel = NSToolbarItem.Identifier("shrike.edit.cancel")
        static let tools = NSToolbarItem.Identifier("shrike.edit.tools")
        static let undoRedo = NSToolbarItem.Identifier("shrike.edit.undoRedo")
        static let reset = NSToolbarItem.Identifier("shrike.edit.reset")
        static let done = NSToolbarItem.Identifier("shrike.edit.done")
    }

    /// Default item order, left to right.
    static let itemOrder: [NSToolbarItem.Identifier] = [
        ItemID.cancel, .flexibleSpace, ItemID.tools, ItemID.undoRedo,
        .flexibleSpace, ItemID.reset, ItemID.done,
    ]

    var onAction: ((EditChromeAction) -> Void)?

    let toolbar: NSToolbar
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private(set) var toolGroup: NSToolbarItemGroup?
    private(set) var undoGroup: NSToolbarItemGroup?
    private(set) var chromeState = EditChromeState()

    override init() {
        toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        super.init()
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        for button in [cancelButton, resetButton, doneButton] {
            button.bezelStyle = .push
            button.target = self
        }
        cancelButton.action = #selector(cancelClicked)
        resetButton.action = #selector(resetClicked)
        doneButton.action = #selector(doneClicked)
        // Return = Done; the key also gives the default button look.
        doneButton.keyEquivalent = "\r"
        doneButton.bezelColor = .controlAccentColor   // same as the Apply buttons
        // Keys come from the shortcut table.
        LiveTooltips.shared.bind(cancelButton, command: .exitEditMode, context: .editMode, title: "Cancel")
        resetButton.toolTip = "Reset All Edits"
        LiveTooltips.shared.bind(doneButton, command: .editDone, context: .editMode)
        toolbar.delegate = self
        apply(chromeState)
    }

    func apply(_ newState: EditChromeState) {
        chromeState = newState
        resetButton.isEnabled = newState.hasEdits
        if let group = toolGroup {
            // No tool on entry shows nothing selected.
            group.selectedIndex = newState.tool.flatMap { EditChromeTools.order.firstIndex(of: $0) } ?? -1
        }
        if let group = undoGroup, group.subitems.count == 2 {
            group.subitems[0].isEnabled = newState.canUndo
            group.subitems[1].isEnabled = newState.canRedo
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemOrder }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemOrder }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.cancel: return viewItem(itemIdentifier, cancelButton, label: "Cancel")
        case ItemID.reset: return viewItem(itemIdentifier, resetButton, label: "Reset")
        case ItemID.done:
            let item = viewItem(itemIdentifier, doneButton, label: "Done")
            // No toolbar-item style. `.prominent`
            // drew its own #007AFF; Done is a plain default push button,
            // the same fill as every Apply button.
            return item
        case ItemID.tools:
            let tools = EditChromeTools.order
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: tools.map(EditChromeTools.image),
                selectionMode: .selectOne,
                labels: tools.map(EditChromeTools.name),
                target: self, action: #selector(toolPicked(_:))
            )
            group.label = "Tool"
            for (sub, tool) in zip(group.subitems, tools) {
                if tool == .levels {
                    LiveTooltips.shared.bind(sub, command: .levels, context: .viewer, title: EditChromeTools.name(tool))
                } else {
                    sub.toolTip = EditChromeTools.tooltip(tool)
                }
            }
            toolGroup = group
            apply(chromeState)
            return group
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
            undoGroup = group
            apply(chromeState)
            return group
        default:
            return nil
        }
    }

    private func viewItem(_ id: NSToolbarItem.Identifier, _ button: NSButton, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        item.autovalidates = false
        return item
    }

    // MARK: Actions

    @objc private func cancelClicked() { onAction?(.cancel) }
    @objc private func resetClicked() { onAction?(.reset) }
    @objc private func doneClicked() { onAction?(.done) }

    @objc private func toolPicked(_ sender: Any?) {
        guard let group = toolGroup,
              EditChromeTools.order.indices.contains(group.selectedIndex) else { return }
        onAction?(.selectTool(EditChromeTools.order[group.selectedIndex]))
    }

    @objc private func undoRedoPicked(_ sender: Any?) {
        guard let group = undoGroup else { return }
        onAction?(group.selectedIndex == 1 ? .redo : .undo)
    }
}

// MARK: - Full screen: the edit capsule

@MainActor
final class EditCapsuleView: HUDSurfaceView {

    var onAction: ((EditChromeAction) -> Void)?

    let label = NSTextField(labelWithString: "Editing")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let toolPicker = NSSegmentedControl()
    let undoRedo = NSSegmentedControl()
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
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
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        for button in [cancelButton, resetButton, doneButton] {
            button.bezelStyle = .push
            button.target = self
        }
        cancelButton.action = #selector(cancelClicked)
        resetButton.action = #selector(resetClicked)
        doneButton.action = #selector(doneClicked)
        // Done is the default button (accent fill on 14/15;
        // Return clicks it once, so the edit keymap never sees Return).
        doneButton.keyEquivalent = "\r"
        doneButton.bezelColor = .controlAccentColor   // same as the Apply buttons
        // Keys come from the shortcut table.
        LiveTooltips.shared.bind(cancelButton, command: .exitEditMode, context: .editMode, title: "Cancel")
        resetButton.toolTip = "Reset All Edits"
        LiveTooltips.shared.bind(doneButton, command: .editDone, context: .editMode)

        let tools = EditChromeTools.order
        toolPicker.segmentCount = tools.count
        toolPicker.trackingMode = .selectOne
        for (i, tool) in tools.enumerated() {
            toolPicker.setImage(EditChromeTools.image(tool), forSegment: i)
            if tool == .levels {
                LiveTooltips.shared.bind(toolPicker, segment: i, command: .levels, context: .viewer,
                                         title: EditChromeTools.name(tool))
            } else {
                toolPicker.setToolTip(EditChromeTools.tooltip(tool), forSegment: i)
            }
            toolPicker.setWidth(32, forSegment: i)
        }
        toolPicker.target = self
        toolPicker.action = #selector(toolPicked)
        toolPicker.setAccessibilityLabel("Tool")

        undoRedo.segmentCount = 2
        undoRedo.trackingMode = .momentary
        undoRedo.setImage(NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo"), forSegment: 0)
        undoRedo.setImage(NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo"), forSegment: 1)
        LiveTooltips.shared.bind(undoRedo, segment: 0, command: .undo, context: .editMode)
        LiveTooltips.shared.bind(undoRedo, segment: 1, command: .redo, context: .editMode)
        undoRedo.target = self
        undoRedo.action = #selector(undoRedoPicked)

        let stack = NSStackView(views: [label, cancelButton, toolPicker, undoRedo, resetButton, doneButton])
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

    func apply(_ newState: EditChromeState) {
        chromeState = newState
        label.stringValue = newState.subtitle
        resetButton.isEnabled = newState.hasEdits
        undoRedo.setEnabled(newState.canUndo, forSegment: 0)
        undoRedo.setEnabled(newState.canRedo, forSegment: 1)
        toolPicker.selectedSegment = newState.tool.flatMap { EditChromeTools.order.firstIndex(of: $0) } ?? -1
    }

    @objc private func cancelClicked() { onAction?(.cancel) }
    @objc private func resetClicked() { onAction?(.reset) }
    @objc private func doneClicked() { onAction?(.done) }

    @objc private func toolPicked() {
        let index = toolPicker.selectedSegment
        guard EditChromeTools.order.indices.contains(index) else { return }
        onAction?(.selectTool(EditChromeTools.order[index]))
    }

    @objc private func undoRedoPicked() {
        onAction?(undoRedo.selectedSegment == 1 ? .redo : .undo)
    }
}
