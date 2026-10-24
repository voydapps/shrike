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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BatchQueuePane(model: model, actions: actions)
                    .disabled(model.reviewingRemaining)
                    .frame(width: 280)
                Divider()
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.reviewingRemaining {
                        Text("Review remaining work. Completed steps will not run again. To change the selection or operations, choose Run Another Batch.").textSelection(.enabled)
                        HStack { Button("Back to Results") { model.cancelRemainingReview() }; Button("Run Another Batch") { model.runAnother() } }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What Will Happen").font(.headline)
                        Text(model.consequenceSummary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        ForEach(model.conversionDisclosures, id: \.self) { disclosure in Text(disclosure).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    }
                    BatchPreviewBox(model: model)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                                .opacity(model.templateError == nil ? 0 : 1)
                        )
                    Button("Tokens…") { showsTokens.toggle() }
                        .help("Insert a name token")
                        .popover(isPresented: $showsTokens, arrowEdge: .bottom) {
                            BatchTokenPopover { token in
                                inserter.insert(token) { model.form.template += $0 }
                            }
                        }
                }
                .disabled(!model.form.renameOn)
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
        if let text = model.inPlaceText {
            Text(text).foregroundStyle(.secondary)
        } else if model.form.writesToFolder {
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
        } else {
            Text("—").foregroundStyle(.secondary)
        }
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
                    .foregroundStyle(model.templateError == nil ? Color.secondary : Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 12)
            Button("Cancel", action: actions.cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.reviewingRemaining ? "Retry \(model.queue.count) Remaining \(model.queue.count == 1 ? "Photo" : "Photos")" : BatchModel.Copy.runButton(model.queue.count)) {
                let event = BatchReturnPolicy.currentEvent
                let window = BatchReturnPolicy.currentWindow
                if BatchReturnPolicy.returnShouldOnlyCommitField(event: event, firstResponder: window?.firstResponder) {
                    window?.makeFirstResponder(nil)   // Return commits the value; the next Return runs
                } else {
                    model.run()
                }
            }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
                .help("Run the batch (Return or ⌘Return)")
                // Return is the real default button; ⌘Return keeps working
                // (a button holds one shortcut, so a hidden twin carries it).
                .background(
                    Button("") { if model.canRun { model.run() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                )
        }
    }
}

/// Return in a text field commits the typed value first (a size, a template);
/// it must not also start a batch that rewrites files. Mouse clicks and Return
/// with no field being edited run as usual.
enum BatchReturnPolicy {
    /// Tests: stands in for `NSApp.currentEvent`, which a direct
    /// `performKeyEquivalent` call does not set.
    nonisolated(unsafe) static var currentEventForTesting: NSEvent?
    /// Tests: the window an unshown test window cannot report through the event.
    nonisolated(unsafe) static weak var windowForTesting: NSWindow?
    @MainActor static var currentWindow: NSWindow? { windowForTesting ?? currentEvent?.window ?? NSApp.keyWindow }
    @MainActor static var currentEvent: NSEvent? { currentEventForTesting ?? NSApp.currentEvent }
    @MainActor static func returnShouldOnlyCommitField(event: NSEvent?, firstResponder: NSResponder?) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              !event.modifierFlags.contains(.command),
              let text = firstResponder as? NSText, text.isFieldEditor else { return false }
        return true
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
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: actions.addItems) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Add Images…")
                    .accessibilityLabel("Add Images")
                Button { model.removeSelected() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(model.selection.isEmpty)
                    .help("Remove from Queue")
                    .accessibilityLabel("Remove from Queue")
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
                        BatchPreviewRowView(row: row)
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

    var body: some View {
        HStack(spacing: 6) {
            if row.nameClash {
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
                Text(skip.message).foregroundStyle(.secondary).lineLimit(1)
            } else {
                if row.nameClash {
                    Text(BatchModel.Copy.nameClash).foregroundStyle(.secondary)
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
                                .help("Insert \(token)")
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
        field.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
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
                Button(model.isStopping ? "Stopping…" : "Stop Batch") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.isStopping)
                    .help("No new photos start. Photos already finished are kept. (⌘.)")
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
                Menu("Actions") {
                    Button("Copy Log", action: actions.copyLog)
                    Button("Show Completed Files", action: actions.showInFinder).disabled(model.doneURLs.isEmpty)
                    Button("Open Completed in Shrike", action: actions.openInShrike).disabled(model.doneFolders.isEmpty)
                    Button("Run Another Batch") { model.runAnother() }
                }
                Spacer()
                if model.canReviewRemaining {
                    Button("Review Remaining…") { model.reviewRemaining() }
                }
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Everything went through: a check before the summary, the folder
    /// under it, in the same column and at the same top as the running view.
    private var calm: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow(icon: "checkmark.circle.fill", color: Color(nsColor: .systemGreen), text: model.summary)
            folderLink
        }
        .batchColumn()
    }

    /// Some items were skipped or failed: the summary, the folder, then
    /// one row per item with its reason.
    private var withReasons: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow(icon: model.result?.doneCount == 0 ? "xmark.circle" : "exclamationmark.triangle",
                     color: Color(nsColor: .secondaryLabelColor), text: model.resultTitle + "\n" + model.summary)
            folderLink
            List(selection: $model.selectedResultRows) {
                ForEach(model.skippedRows, id: \.source) { row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .tag(row.source)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: model.skippedRows.count > 8))
            .frame(minHeight: 100, maxHeight: 320)
            if model.hasIntentionalSkips {
                Text("Select intentional skips to include them in Review Remaining.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .batchColumn()
    }

    /// The icon slot and the title; the title starts 30 pt in, so it lines
    /// up with the running title's text and the folder link.
    private func titleRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: BatchLayout.doneIconGap) {
            Image(systemName: icon)
                .font(.system(size: BatchLayout.doneIconSize))
                .frame(height: BatchLayout.doneTitleLine)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 15, weight: .semibold))
        }
    }

    /// The Output folder (or the folder changed in place) as a link:
    /// clicking it shows the files in Finder.
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
}
