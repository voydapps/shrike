//
//  BatchViews.swift
//  ShrikeUI
//
//  The Batch window's SwiftUI content: one form (queue on
//  the left, operations, output, "If a file exists", live preview, the
//  preset bar), replaced in place by the Running view and then the Done
//  view. No step bar. Type: body 13 pt, secondary lines
//  11 pt, counters in monospaced digits; the clash triangle is
//  accent.warning, the template error outline accent.danger.
//

import AppKit
import SwiftUI
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// What the buttons ask the window controller to do.
@MainActor
struct BatchViewActions {
    var addItems: () -> Void = {}
    var chooseOutput: () -> Void = {}
    var savePreset: () -> Void = {}
    var deletePreset: (String) -> Void = { _ in }
    var cancel: () -> Void = {}
    var copyLog: () -> Void = {}
    var showInFinder: () -> Void = {}
    var openInShrike: () -> Void = {}
    var done: () -> Void = {}
    var undoBatch: () -> Void = {}
    var canUndoBatch: () -> Bool = { false }
    /// The right column's content height and its scroll view's height.
    var formMeasured: (_ content: CGFloat, _ viewport: CGFloat) -> Void = { _, _ in }
}

/// Tokens… popover groups.
public enum BatchTokens {
    public static let groups: [(title: String, tokens: [String])] = [
        ("Date", ["{yyyy}", "{MM}", "{dd}", "{yyyy-MM-dd}", "{HH-mm-ss}",
                  "{date:yyyyMMdd}", "{filedate:yyyy-MM-dd}"]),
        ("Counter", ["{counter}", "{counter:000}", "{counter:0000}"]),
        ("File", ["{name}", "{ext}", "{rating}"]),
        ("Camera", ["{camera}", "{lens}", "{iso}", "{aperture}", "{shutter}", "{focal}"]),
    ]
}

extension BatchTokens {
    /// What a field means, with a sample value.
    /// The sample is fixed text, not read from the first photo.
    public static func hint(_ token: String) -> String {
        switch token {
        case "{yyyy}": return "Year the photo was taken, like 2021"
        case "{MM}": return "Month the photo was taken, like 06"
        case "{dd}": return "Day the photo was taken, like 14"
        case "{yyyy-MM-dd}": return "Date the photo was taken, like 2021-06-14"
        case "{HH-mm-ss}": return "Time the photo was taken, like 07-57-12"
        case "{date:yyyyMMdd}": return "Date the photo was taken, like 20210614"
        case "{filedate:yyyy-MM-dd}": return "Date the file was last changed, like 2021-06-14"
        case "{counter}": return "A number that counts up, like 1, 2, 3"
        case "{counter:000}": return "A counter with 3 digits, like 001, 002"
        case "{counter:0000}": return "A counter with 4 digits, like 0001, 0002"
        case "{name}": return "The file name without its ending, like IMG_4219"
        case "{ext}": return "The file ending, like jpg"
        case "{rating}": return "The star rating, 0 to 5"
        case "{camera}": return "Camera model, like Canon EOS 60D"
        case "{lens}": return "Lens model, like EF-S24mm f/2.8 STM"
        case "{iso}": return "ISO speed, like 100"
        case "{aperture}": return "Aperture, like f10"
        case "{shutter}": return "Shutter time, like 1-400"
        case "{focal}": return "Focal length, like 24mm"
        default: return "Add this field to the name"
        }
    }
}

struct BatchRootView: View {
    @ObservedObject var model: BatchModel
    let actions: BatchViewActions
    let inserter: BatchTokenInserter

    var body: some View {
        Group {
            switch model.phase {
            case .form: BatchFormView(model: model, actions: actions, inserter: inserter)
            case .running: BatchRunningView(model: model)
            case .done: BatchDoneView(model: model, actions: actions)
            }
        }
        .font(.system(size: ChromeTypography.size(13)))
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Form

struct BatchFormView: View {
    @ObservedObject var model: BatchModel
    let actions: BatchViewActions
    let inserter: BatchTokenInserter
    @State private var showsTokens = false
    @State private var columnHeights = CGSize.zero   // width = controls above the preview, height = viewport
    /// The preview box's smallest height; the window fit counts only this much of the list.
    static let previewMinHeight: CGFloat = 120
    /// The column's padding (2 × 16) and the gap above the preview (12).
    static let columnExtra: CGFloat = 44

    private func reportFormHeight() {
        actions.formMeasured(columnHeights.width + Self.columnExtra + Self.previewMinHeight, columnHeights.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BatchQueuePane(model: model, actions: actions)
                    .disabled(model.reviewingRemaining)
                    .frame(width: 280)
                Divider()
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.reviewingRemaining {
                        Text("Review remaining work. Completed steps will not run again. To change the selection or operations, choose Run Another Batch.").textSelection(.enabled)
                        HStack { BatchTextButton("Back to Results") { model.cancelRemainingReview() }; BatchTextButton("Run Another Batch") { model.runAnother() } }
                    }
                    operations.disabled(model.reviewingRemaining)
                    if model.reviewingRemaining {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                            GridRow {
                                Text("Output")
                                outputRow
                            }
                        }
                    }
                    conflictRow
                    if model.showsWhatWillHappenHeading {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What will happen").font(.headline)
                        ForEach(model.whatWillHappenLines, id: \.self) { line in
                            // The skip lines are secondary.
                            Text(line).foregroundStyle(line == model.unreadableLine || line == model.invalidNameLine ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            // The folder on its own line, right under the sentence.
                            if line == model.consequenceSummary, let path = model.outputPathLine {
                                Text(path).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                                    .help(path)
                                    .accessibilityLabel("Output folder").accessibilityValue(path)
                            }
                        }
                        ForEach(model.conversionDisclosures, id: \.self) { disclosure in Text(disclosure).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    }
                    }
                }
                // The window fits the controls, not the preview list.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    columnHeights.width = $0; reportFormHeight()
                }
                // The list scrolls in its own box, which takes the rest of the column.
                BatchPreviewBox(model: model)
                    .frame(height: max(Self.previewMinHeight, columnHeights.height - columnHeights.width - Self.columnExtra))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    columnHeights.height = $0; reportFormHeight()
                }
            }
            Divider()
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var formats: [ExportFormat] { SaveAsAccessory.offeredFormats }

    private var quality: Binding<Double> {
        Binding(get: { Double(model.form.quality) },
                set: { model.form.quality = Int($0.rounded()) })
    }

    private var resizeMode: Binding<ResizeOptions.Mode> {
        Binding(get: { model.form.resizeMode }, set: { model.setResizeMode($0) })
    }

    private var operations: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                BatchCheckbox("Convert", isOn: $model.form.convertOn)
                HStack(spacing: 8) {
                    // The label is a Text of its own: a Picker's label
                    // stays bright in a disabled row.
                    Text("Format").dimsWithRow()
                    Picker("Format", selection: $model.form.format) {
                        ForEach(formats, id: \.self) { Text(SaveAsAccessory.title(of: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if SaveAsAccessory.showsQuality(model.form.format) {
                        Text("Quality").dimsWithRow()
                        Slider(value: quality, in: 60...100)
                            .frame(width: BatchLayout.qualitySliderWidth)
                            .accessibilityLabel("Quality")
                            .accessibilityValue(Text(verbatim: "\(model.form.quality)"))
                            .sliderDimsWithRow()
                        Text(verbatim: "\(model.form.quality)")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                            .dimsWithRow()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!model.form.convertOn)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 16) {
                    BatchCheckbox("Keep metadata", isOn: $model.form.keepMetadata)
                    BatchCheckbox("Remove location", isOn: $model.form.removeLocation)
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!model.form.convertOn)
            }
            GridRow {
                BatchCheckbox("Resize", isOn: $model.form.resizeOn)
                HStack(spacing: 8) {
                    Picker("Resize by", selection: resizeMode) {
                        Text("Long edge").tag(ResizeOptions.Mode.longEdge)
                        Text("Width").tag(ResizeOptions.Mode.width)
                        Text("Height").tag(ResizeOptions.Mode.height)
                        Text("Percent").tag(ResizeOptions.Mode.percent)
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Size", value: $model.form.resizeValue, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 64)
                        .accessibilityLabel(model.form.resizeMode == .percent ? "Percent" : "Pixels")
                    Text(model.form.resizeMode == .percent ? "%" : "px")
                        .dimsWithRow(secondary: true)
                        .fixedSize()
                    BatchCheckbox("Don't enlarge", isOn: $model.form.dontEnlarge)
                        .fixedSize()
                        .padding(.leading, 8)
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!model.form.resizeOn)
            }
            GridRow {
                BatchCheckbox("Rotate", isOn: $model.form.rotateOn)
                Picker("Rotation", selection: $model.form.rotation) {
                    ForEach(BatchRotation.menuOrder, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.form.rotateOn)
            }
            GridRow {
                BatchCheckbox("Rename", isOn: $model.form.renameOn)
                HStack(spacing: 8) {
                    BatchTemplateField(text: $model.form.template, inserter: inserter)
                        .frame(minWidth: 220, maxWidth: 320)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .systemRed), lineWidth: 2)
                                .opacity(model.templateFeedback.fieldOutlineRed ? 1 : 0)
                        )
                    Button("Insert Field…") { showsTokens.toggle() }
                        .accessibilityLabel("Insert Field")
                        .help("Insert a part of the photo's data into the name")
                        .popover(isPresented: $showsTokens, arrowEdge: .bottom) {
                            BatchTokenPopover { token in
                                inserter.insert(token) { model.form.template += $0 }
                            }
                        }
                }
                .disabled(!model.form.renameOn)
            }
            if let line = model.templateFeedback.underField {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(line)
                        .font(.system(size: ChromeTypography.size(12)))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if let example = model.exampleLine {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(example)
                        .font(.system(size: ChromeTypography.size(12)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 8) {
                    Text("Start").dimsWithRow()
                    TextField("Start", value: $model.form.counterStart, format: .number.grouping(.never))
                        .labelsHidden()
                        .monospacedDigit()
                        .frame(width: 56)
                        .accessibilityLabel("Counter start")
                    Text("Case").dimsWithRow()
                        .padding(.leading, 8)
                    Picker("Case", selection: $model.form.nameCase) {
                        Text("Keep").tag(NameCase.keep)
                        Text("lowercase").tag(NameCase.lower)
                        Text("UPPERCASE").tag(NameCase.upper)
                        Text("Title Case").tag(NameCase.title)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!model.form.renameOn)
            }
            if !model.reviewingRemaining {
                GridRow {
                    Text("Output")
                    outputRow
                }
            }
        }
    }

    /// "If a file exists" (a full-width row).
    private var conflictRow: some View {
        HStack(spacing: 8) {
            Text("If a file exists").dimsWithRow()
            Picker("If a file exists", selection: $model.form.onConflict) {
                Text("Keep Both").tag(ConflictAnswer.Action.keepBoth)
                Text("Skip").tag(ConflictAnswer.Action.skip)
                Text("Replace").tag(ConflictAnswer.Action.replace)
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!model.form.writesToFolder && !model.form.renameOn)
    }

    @ViewBuilder
    private var outputRow: some View {
        switch BatchModel.Copy.outputForm(inPlaceText: model.inPlaceText, writesToFolder: model.form.writesToFolder,
                                          changesOriginals: model.changesOriginals) {
        case .notice(let text):
            outputNotice(text)
        case .folderNotice(let text):
            VStack(alignment: .leading, spacing: 6) {
                outputNotice(text)
                outputFolderField
            }
        case .folder(let note):
            VStack(alignment: .leading, spacing: 4) {
                outputFolderField
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .none:
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// The orange notice box of a plan that changes originals.
    private func outputNotice(_ text: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemOrange).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .systemOrange).opacity(0.4), lineWidth: 1))
            .accessibilityElement(children: .combine)
    }

    private var outputFolderField: some View {
            HStack(spacing: 8) {
                Text(model.outputFolder.map(UserFacingPath.string) ?? "—")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(minWidth: 220, maxWidth: BatchLayout.outputFieldMaxWidth, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                    .help(model.outputFolder.map(UserFacingPath.string) ?? "")
                    .accessibilityLabel("Output folder")
                    .accessibilityValue(model.outputFolder.map(UserFacingPath.string) ?? "none")
                Button("Choose…", action: actions.chooseOutput)
            }
    }

    /// The Run button's title; its accessibility label is the same text.
    private var runTitle: String {
        BatchModel.Copy.footerRunTitle(reviewingRemaining: model.reviewingRemaining, queueCount: model.queue.count,
                                       processable: model.processableCount, changesOriginals: model.changesOriginals)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("Preset")
            Menu(model.presetTitle) {
                // A Toggle in a menu is a menu item with a check mark:
                // the current preset shows one. Choosing
                // the checked one again applies it again.
                ForEach(model.presets, id: \.name) { preset in
                    Toggle(preset.name, isOn: Binding(get: { model.isCurrent(preset) },
                                                      set: { _ in model.apply(preset) }))
                }
                Divider()
                Button("Save Preset…", action: actions.savePreset)
                if let name = model.deletablePresetName {
                    Button("Delete “\(name)”") { actions.deletePreset(name) }
                }
            }
            .fixedSize()
            .accessibilityLabel("Preset")
            .disabled(model.reviewingRemaining)
            if let line = model.validationLine {
                Text(line)
                    .foregroundStyle(model.templateFeedback.footerIsError ? Color(nsColor: .systemRed) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            // AppKit buttons: SwiftUI's footer buttons reached
            // assistive apps with no name at all.
            BatchTextButton("Cancel", key: .cancel, action: actions.cancel)
            BatchTextButton(runTitle, key: .defaultAction, isEnabled: model.canRun,
                            help: "Run the batch (Return or ⌘Return)") {
                // Return in a text field only commits it: `BatchKeyButton`
                // declines that Return before this runs.
                model.requestRun()
            }
                // Return is the real default button; ⌘Return keeps working
                // (a button holds one shortcut, so a hidden twin carries it).
                .background(
                    Button("") {
                        // ⌘Return from a field: the typed value counts.
                        BatchWindowController.current?.window?.makeFirstResponder(nil)
                        model.requestRunWhenCurrent()
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                )
        }
    }
}

/// What Return and Esc do while a text field of the Batch window is being
/// edited: Return commits the typed value (a size, a
/// template) and must not also start a batch that rewrites files; Esc
/// cancels the edit and must not close the window. ⌘Return, mouse clicks
/// and keys with no field being edited work as usual.
enum BatchFieldKeys {
    enum Key: Equatable { case plainReturn, plainEscape, other }

    static func key(_ event: NSEvent) -> Key {
        guard event.type == .keyDown else { return .other }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return .other }
        switch event.keyCode {
        case 36, 76: return .plainReturn   // Return, keypad Enter
        case 53: return .plainEscape
        default: return .other
        }
    }

    /// The field editor of a text field in `window`, while one is being edited.
    @MainActor static func editor(in window: NSWindow?) -> NSTextView? {
        guard let text = window?.firstResponder as? NSTextView, text.isFieldEditor else { return nil }
        return text
    }

    /// The `NSTextMovement` of an end-of-editing notification was Return.
    static func endedWithReturn(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue
    }
}

/// The Batch footer's buttons. The default button (Return) and the cancel
/// button (Esc) leave those keys to a text field that is being edited:
/// - The window offers Return to its buttons before the field editor sees
///   it: the default button commits the field instead of running.
/// - When the field editor ends editing with Return, AppKit presses the
///   default button itself, after the field has already let go; the button
///   notes that end of editing and declines that one press. Focus then
///   leaves the field, so the next Return runs.
/// - Esc cancels the edit (the field's delegate puts the old value back) and
///   keeps the window.
final class BatchKeyButton: NSButton {
    private var declineReturnPress = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidEndEditingNotification, object: nil)
        guard window != nil, keyEquivalent == "\r" else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(fieldEndedEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: nil)
    }

    @objc private func fieldEndedEditing(_ note: Notification) {
        guard keyEquivalent == "\r", let field = note.object as? NSView, let window, field.window === window,
              BatchFieldKeys.endedWithReturn(note.userInfo) else { return }
        declineReturnPress = true
        // The same turn of the run loop: AppKit's press follows at once. Then
        // the field (which AppKit selects again) lets go of the focus.
        DispatchQueue.main.async { [weak self, weak window] in
            self?.declineReturnPress = false
            if BatchFieldKeys.editor(in: window) != nil { window?.makeFirstResponder(nil) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, let editor = BatchFieldKeys.editor(in: window) else {
            return super.performKeyEquivalent(with: event)
        }
        switch (BatchFieldKeys.key(event), keyEquivalent) {
        case (.plainReturn, "\r"):
            guard isEnabled else { return super.performKeyEquivalent(with: event) }
            window.makeFirstResponder(nil)   // commits the typed value; the next Return runs
            return true
        case (.plainEscape, "\u{1b}"):
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))   // the field puts its old value back
            if let field = editor.delegate as? NSTextField { field.abortEditing() }
            window.makeFirstResponder(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if declineReturnPress {
            declineReturnPress = false
            return false
        }
        return super.sendAction(action, to: target)
    }
}

// MARK: - Dimming with the row

/// Greys a label out when its row is disabled, like the row's checkboxes
/// and pop-ups. SwiftUI keeps a Text's colour in a disabled row, so
/// "Format", "Quality" and "px" stayed bright while Convert was off.
struct BatchLabelDimming: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    var secondary = false

    static let disabledColor = Color(nsColor: .disabledControlTextColor)

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? (secondary ? Color.secondary : Color.primary) : Self.disabledColor)
    }
}

/// Greys a slider out when its row is disabled. A disabled SwiftUI Slider
/// keeps its white knob and looks active.
struct BatchSliderDimming: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    static let disabledOpacity: Double = 0.4

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : Self.disabledOpacity)
    }
}

extension View {
    func dimsWithRow(secondary: Bool = false) -> some View {
        modifier(BatchLabelDimming(secondary: secondary))
    }

    func sliderDimsWithRow() -> some View {
        modifier(BatchSliderDimming())
    }
}

// MARK: - Queue

struct BatchQueuePane: View {
    @ObservedObject var model: BatchModel
    let actions: BatchViewActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(model.queue.count) \(model.queue.count == 1 ? "photo" : "photos") chosen")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Text(verbatim: model.scopeDescription)
                        .font(.system(size: ChromeTypography.size(11)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = BatchModel.duplicatesNote(model.droppedDuplicateCount) {
                        // Read with the queue line; the icon is not read on its own.
                        Label {
                            Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle").font(.system(size: 12))
                        }
                        .font(.system(size: ChromeTypography.size(11)))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: note))
                        .accessibilityAddTraits(.isStaticText)
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                // AppKit buttons: SwiftUI backs a borderless image button with
                // an NSButton whose own title is empty and which ignores
                // `.accessibilityLabel`, so assistive apps read no name.
                BatchIconButton(symbol: "plus", name: "Add Photos", help: "Add Photos…",
                                isEnabled: true, action: actions.addItems)
                BatchIconButton(symbol: "minus", name: "Remove from Queue", help: "Remove from Queue",
                                isEnabled: !model.selection.isEmpty, action: { model.removeSelected() })
            }
            .padding(.leading, BatchLayout.queueHeadingInset)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            List(selection: $model.selection) {
                ForEach(model.queue) { item in
                    HStack(spacing: 8) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let size = model.sizes[item.id] {
                            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                                .font(.system(size: ChromeTypography.size(11)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: BatchLayout.dimensionsColumnWidth, alignment: .trailing)
                        }
                    }
                    .tag(item.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .onDeleteCommand { model.removeSelected() }
            .overlay {
                if model.queue.isEmpty {
                    Text(BatchModel.Copy.emptyQueue)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Preview

struct BatchPreviewBox: View {
    @ObservedObject var model: BatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.moreCount > 0 ? "Preview · first 200 of \(model.queue.count)" : "Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.previewRows.enumerated()), id: \.offset) { _, row in
                        BatchPreviewRowView(row: row, clashText: model.clashText(for: row))
                    }
                    if model.moreCount > 0 {
                        Text(BatchModel.Copy.andMore(model.moreCount))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

struct BatchPreviewRowView: View {
    let row: BatchPreviewRow
    /// `BatchPreviewRowLook.clashText` for this row (nil: no words, no warning sign).
    var clashText: String?

    /// What VoiceOver reads for a skipped-look row (`broken.jpg. Skipped. Shrike can't read this file.`);
    /// nil for a normal row (its parts combine).
    static func accessibilityText(for row: BatchPreviewRow) -> String? {
        BatchPreviewRowLook.skipText(row.skip).map {
            BatchPreviewRowLook.accessibilityLabel(name: row.source.primary.lastPathComponent, skipText: $0)
        }
    }

    var body: some View {
        if let reason = BatchPreviewRowLook.skipText(row.skip) {
            skippedRow(reason)
        } else {
            normalRow
        }
    }

    /// A skipped photo: no arrow and no new name; icon, grey name, grey reason.
    private func skippedRow(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            Text(row.source.primary.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Spacer(minLength: 8)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: ChromeTypography.size(12)))
        .accessibilityRepresentation {
            Text(Self.accessibilityText(for: row) ?? reason)
        }
    }

    private var normalRow: some View {
        HStack(spacing: 6) {
            if clashText != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemYellow))
                    .accessibilityHidden(true)
            }
            Text(row.source.primary.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("→").foregroundStyle(.secondary)
            Text(row.outputName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let skip = row.skip {
                Text(clashText ?? skip.message).foregroundStyle(.secondary).lineLimit(1)
            } else {
                if let clashText {
                    Text(clashText).foregroundStyle(.secondary).lineLimit(1)
                }
                if let size = row.outputSize {
                    Text(verbatim: "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: BatchLayout.dimensionsColumnWidth, alignment: .trailing)
                }
            }
        }
        .font(.system(size: ChromeTypography.size(12)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tokens

struct BatchTokenPopover: View {
    let insert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(BatchTokens.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6, alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(group.tokens, id: \.self) { token in
                            Button(token) { insert(token) }
                                .font(.system(size: 11, design: .monospaced))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Insert \(token): \(BatchTokens.hint(token))")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 440)
    }
}

/// Inserts a token at the caret of the template field (replacing the
/// selection), like typing it. Undo in the field works as usual.
@MainActor
final class BatchTokenInserter {
    weak var field: NSTextField?

    func insert(_ token: String, fallback: (String) -> Void) {
        guard let field, let window = field.window else { return fallback(token) }
        if field.currentEditor() == nil {
            window.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        }
        guard let editor = field.currentEditor() as? NSTextView else { return fallback(token) }
        editor.insertText(token, replacementRange: editor.selectedRange())
    }
}

/// The name template field (AppKit, so Tokens… can insert at the caret).
struct BatchTemplateField: NSViewRepresentable {
    @Binding var text: String
    let inserter: BatchTokenInserter

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Name template")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inserter.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.currentEditor() == nil { context.coordinator.committed = text }
        field.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        /// The value before the current edit; Esc puts it back.
        var committed: String
        init(text: Binding<String>) { self.text = text; committed = text.wrappedValue }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            committed = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            text.wrappedValue = committed
            textView.string = committed
            control.stringValue = committed
            control.abortEditing()
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

// MARK: - Running

/// A plain bar. The system bar glides to a new value over a second or so, so it
/// trailed the "n of N" counter; this one shows the same value at once.
struct BatchProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .transaction { $0.animation = nil }
    }
}

struct BatchRunningView: View {
    @ObservedObject var model: BatchModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.runningTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 12)
                BatchProgressBar(fraction: model.progressFraction)
                    .frame(height: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel("Batch progress")
                    .accessibilityValue(BatchModel.Copy.progress(model.completed, model.total))
                    .padding(.bottom, 8)
                Text(model.progressLine)
                    .font(.system(size: ChromeTypography.size(13)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
                    .padding(.bottom, 6)
                Text(model.currentName ?? " ")
                    .font(.system(size: ChromeTypography.size(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .batchColumn()
            Divider()
            HStack {
                Spacer()
                BatchTextButton(model.isStopping ? "Stopping…" : "Stop Batch", key: .commandPeriod,
                                isEnabled: !model.isStopping,
                                help: "No new photos start. Photos already finished are kept. (⌘.)") { model.stop() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Done

struct BatchDoneView: View {
    @ObservedObject var model: BatchModel
    let actions: BatchViewActions

    var body: some View {
        VStack(spacing: 0) {
            if model.skippedRows.isEmpty {
                calm
            } else {
                withReasons
            }
            Divider()
            HStack(spacing: 8) {
                BatchActionsMenu(title: "Actions", items: [
                    .init(title: "Copy Log", isEnabled: true, action: actions.copyLog),
                    .init(title: "Show Completed Files", isEnabled: !model.doneURLs.isEmpty, action: actions.showInFinder),
                    .init(title: "Open Completed in Shrike", isEnabled: !model.doneFolders.isEmpty, action: actions.openInShrike),
                    .init(title: "Undo Batch", isEnabled: actions.canUndoBatch(), action: actions.undoBatch),
                    .init(title: "Run Another Batch", isEnabled: true) { model.runAnother() },
                ])
                Spacer()
                if model.canReviewRemaining {
                    BatchTextButton("Review Remaining…") { model.reviewRemaining() }
                }
                BatchTextButton("Done", key: .defaultAction, action: actions.done)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Everything went through: a check before the summary, the folder
    /// under it, in the same column and at the same top as the running view.
    private var calm: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow(icon: model.resultIcon.symbolName,
                     color: model.resultIcon.isGreen ?Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor),
                     title: model.resultTitle, summary: model.summary)
            backupLine
            folderLink
        }
        .batchColumn()
    }

    /// Some items were skipped or failed: the summary, the folder, then
    /// one row per item with its reason.
    private var withReasons: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow(icon: model.resultIcon.symbolName,
                     color: Color(nsColor: .secondaryLabelColor), title: model.resultTitle, summary: model.summary)
            backupLine
            folderLink
            List {
                ForEach(model.skippedRows, id: \.source) { row in
                    skipRow(row)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: model.skippedRows.count > 8))
            .frame(minHeight: 100, maxHeight: .infinity)
            if model.hasIntentionalSkips {
                Text("Tick the skips you chose to include them in Review Remaining.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, BatchLayout.doneHintInset)
            }
        }
        .batchColumn()
    }

    /// One skipped or failed photo. A skip the user chose to make has a
    /// checkbox (ticked = included in Review Remaining); the other rows keep
    /// the same left inset so the names stay in one column.
    @ViewBuilder private func skipRow(_ row: BatchModel.SkippedRow) -> some View {
        HStack(spacing: 8) {
            if row.isIntentionalSkip {
                BatchCheckbox(fileName: row.name, isOn: Binding(
                    get: { model.selectedResultRows.contains(row.source) },
                    set: { on in
                        if on { model.selectedResultRows.insert(row.source) }
                        else { model.selectedResultRows.remove(row.source) }
                    }))
                    .help("Tick to include this photo in Review Remaining.")
            } else {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, model.hasIntentionalSkips ? BatchLayout.doneCheckboxInset : 0)
            }
            Spacer(minLength: 8)
            Text(row.reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        // One element "name. reason"; a ticked row keeps its checkbox as a child.
        .accessibilityElement(children: row.isIntentionalSkip ? .contain : .combine)
    }

    /// The icon slot and the title; the title starts 30 pt in, so it lines
    /// up with the running title's text and the folder link.
    private func titleRow(icon: String, color: Color, title: String, summary: String? = nil) -> some View {
        HStack(alignment: .top, spacing: BatchLayout.doneIconGap) {
            Image(systemName: icon)
                .font(.system(size: BatchLayout.doneIconSize))
                .frame(height: BatchLayout.doneTitleLine)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            // The title stands apart (15 pt semibold); the summary
            // sentences are regular 13 pt secondary, 6 pt under it.
            VStack(alignment: .leading, spacing: BatchLayout.resultSummarySpacing) {
                Text(title).font(.system(size: BatchLayout.resultTitleSize, weight: .semibold))
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: BatchLayout.resultSummarySize))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The Output folder (or the folder changed in place) as a link:
    /// clicking it shows the files in Finder.
    /// "Shrike lost track of …" with the warning icon.
    @ViewBuilder private var backupLine: some View {
        if let line = model.backupNotice, !model.isUndone {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .accessibilityHidden(true)
                Text(verbatim: line)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var folderLink: some View {
        if let text = model.resultFolderText, let folder = model.resultFolder {
            Button(action: actions.showInFinder) {
                Label(text, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .padding(.leading, BatchLayout.doneIconSize + BatchLayout.doneIconGap)
            .help("Show in Finder")
            .accessibilityLabel("Show “\(folder.lastPathComponent)” in Finder")
        }
    }
}

/// The result side (running, done) is one centred column with its content
/// left-aligned, starting at a fixed distance from the top.
extension View {
    func batchColumn() -> some View {
        frame(maxWidth: BatchLayout.columnWidth, alignment: .leading)
            .padding(.horizontal, BatchLayout.columnMargin)
            .padding(.top, BatchLayout.columnTopInset)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The "W × H" columns (queue list and preview) share one
/// minimum width and a trailing edge, so the right edges line up row to row.
enum BatchLayout {
    /// The result title and the summary under it.
    static let resultTitleSize: CGFloat = 15
    static let resultSummarySize: CGFloat = 13
    static let resultSummarySpacing: CGFloat = 6
    static let dimensionsColumnWidth: CGFloat = 96
    /// The form column must fit beside the 280 pt queue pane at the minimum
    /// window width, also with Larger Interface (a wider row pushed the
    /// whole split off the left edge). Test: BatchColumnLayoutTests.
    static let qualitySliderWidth: CGFloat = 104
    static let outputFieldMaxWidth: CGFloat = 280
    static let columnWidth: CGFloat = 560
    static let columnMargin: CGFloat = 40
    static let columnTopInset: CGFloat = 56
    static let doneIconSize: CGFloat = 22
    /// Line height of the 15 pt title: the icon is centred on it, so the
    /// taller icon does not push the title down.
    static let doneTitleLine: CGFloat = 18
    static let doneIconGap: CGFloat = 8
    /// Leading space of the queue heading: the row names start here.
    static let queueHeadingInset: CGFloat = 16
    /// Done view: width of a skip row's checkbox box and its gap to the
    /// name, kept as a left inset on rows without one.
    static let doneCheckboxInset: CGFloat = 22
    /// The hint under the skip list lines up with the checkboxes' left edge.
    static let doneHintInset: CGFloat = 16
}

/// A borderless symbol button that names itself to assistive apps (title
/// and label = `name`), in the secondary colour of the queue header.
struct BatchIconButton: NSViewRepresentable {
    let symbol: String
    let name: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ sender: Any?) { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.fire(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled && context.environment.isEnabled   // follows a disabled form too
        button.toolTip = help
        Self.name(button, name)
    }

    /// Title and label on the button and on its cell (the cell is the
    /// element the AX API reads for an NSButton).
    static func name(_ button: NSButton, _ name: String) {
        button.setAccessibilityTitle(name)
        button.setAccessibilityLabel(name)
        button.cell?.setAccessibilityTitle(name)
        button.cell?.setAccessibilityLabel(name)
    }
}

/// A push button that names itself to assistive apps: the button and its
/// cell carry the visible title as accessibility title and label. SwiftUI's
/// own `Button` in this window reached assistive apps with no name.
struct BatchTextButton: NSViewRepresentable {
    enum Key { case none, defaultAction, cancel, commandPeriod }
    /// `.link`: borderless, link-coloured text (SwiftUI's `.link` style,
    /// which left the button unnamed for VoiceOver).
    enum Look { case push, link }
    let title: String
    let key: Key
    let isEnabled: Bool
    let help: String?
    let look: Look
    let action: () -> Void

    init(_ title: String, key: Key = .none, isEnabled: Bool = true, help: String? = nil,
         look: Look = .push, action: @escaping () -> Void) {
        self.title = title; self.key = key; self.isEnabled = isEnabled; self.help = help
        self.look = look; self.action = action
    }

    func makeCoordinator() -> BatchIconButton.Coordinator { .init(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = BatchKeyButton(title: title, target: context.coordinator,
                              action: #selector(BatchIconButton.Coordinator.fire(_:)))
        switch look {
        case .push:
            button.bezelStyle = .push
        case .link:
            button.isBordered = false
            button.contentTintColor = .linkColor
        }
        switch key {
        case .none: break
        case .defaultAction: button.keyEquivalent = "\r"
        case .cancel: button.keyEquivalent = "\u{1b}"
        case .commandPeriod: button.keyEquivalent = "."; button.keyEquivalentModifierMask = .command
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        if button.title != title { button.title = title; button.invalidateIntrinsicContentSize() }
        button.isEnabled = isEnabled && context.environment.isEnabled
        button.toolTip = help
        BatchIconButton.name(button, title)
    }
}

/// The result's Actions pull-down as an AppKit pop-up button (named, like
/// `BatchTextButton`); its items are ordinary menu items.
struct BatchActionsMenu: NSViewRepresentable {
    struct Item {
        let title: String
        let isEnabled: Bool
        let action: () -> Void
    }
    let title: String
    let items: [Item]

    final class Coordinator: NSObject {
        var items: [Item] = []
        @objc func fire(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].action()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.items = items
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")   // a pull-down shows item 0 as its title
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.fire(_:)), keyEquivalent: "")
            entry.target = context.coordinator
            entry.tag = index
            entry.isEnabled = item.isEnabled
            menu.addItem(entry)
        }
        button.menu = menu
        button.isEnabled = context.environment.isEnabled
        BatchIconButton.name(button, title)
    }
}
