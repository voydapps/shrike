//
//  ContactSheetSheet.swift
//  ShrikeUI
//
//  File ▸ Export Contact Sheet… in the Browser: the
//  400 pt sheet (images, title, columns, paper, caption), the Save
//  panel, and the PDF made off the main thread by `ContactSheetRenderer`
//  with a progress toast. The choices are remembered in the print prefs.
//

import AppKit
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeEdit

/// What the sheet offers: all the listed images, or the selection.
struct ContactSheetScope: Equatable {
    let allCount: Int
    let folderName: String
    let selectedCount: Int

    var offersSelection: Bool { selectedCount > 0 }
    /// "All 180 in “Italy 2026”" ("All 180 images" with no folder).
    var allTitle: String {
        folderName.isEmpty ? "All \(allCount) images" : "All \(allCount) in “\(folderName)”"
    }
    /// "The 12 selected".
    var selectedTitle: String { "The \(selectedCount) selected" }
}

/// The sheet's answer.
struct ContactSheetRequest: Equatable {
    var options: ContactSheetOptions
    var selectedOnly: Bool
}

/// The sheet's controls ↔ the renderer's options; the copy.
enum ContactSheetForm {

    static let width: CGFloat = 400
    static let papers: [(title: String, value: ContactSheetPaper)] = [("A4", .a4), ("US Letter", .usLetter)]
    static let captions: [(title: String, value: ContactSheetCaption)] = [
        ("None", .none), ("File name", .fileName), ("File name and date", .fileNameAndDate),
    ]

    /// The options for the sheet's controls (columns clamped to 3–8).
    static func options(title: String, columns: Int, paperIndex: Int, captionIndex: Int) -> ContactSheetOptions {
        let paper = papers[min(max(0, paperIndex), papers.count - 1)].value
        let caption = captions[min(max(0, captionIndex), captions.count - 1)].value
        return ContactSheetOptions(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                   columns: columns, paper: paper, caption: caption)
    }

    /// "Italy 2026 contact sheet.pdf" ("Contact sheet.pdf" with no title).
    static func fileName(for title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "Contact sheet.pdf" : "\(clean) contact sheet.pdf"
    }

    /// "Making contact sheet… 40%".
    static func progressText(_ fraction: Double) -> String {
        "Making contact sheet… \(percent(fraction))%"
    }

    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }

    /// "Saved “Italy 2026 contact sheet.pdf”."
    static func savedText(_ fileName: String) -> String { "Saved “\(fileName)”." }

    static func failedText(_ fileName: String) -> String {
        "Couldn't save “\(fileName)”. Check that the folder can be written to."
    }
}

/// The 400 pt sheet. AppKit controls in a grid, as the other sheets.
@MainActor
final class ContactSheetSheet: NSObject, NSTextFieldDelegate {

    /// Tests answer here instead of a sheet (nil = Cancel).
    static var responderForTesting: ((ContactSheetScope, ContactSheetOptions) -> ContactSheetRequest?)?

    private let scope: ContactSheetScope
    private let initial: ContactSheetOptions
    private var panel: NSPanel?
    private let allRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let selectedRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let titleField = NSTextField()
    private let columnsField = NSTextField()
    private let stepper = NSStepper()
    private let paperPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let captionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var completion: ((ContactSheetRequest?) -> Void)?
    /// The sheet on screen (kept alive while it is up).
    private static var open: ContactSheetSheet?

    private init(scope: ContactSheetScope, initial: ContactSheetOptions) {
        self.scope = scope
        self.initial = initial
    }

    /// Shows the sheet on `window` (or answers from the test responder).
    static func present(on window: NSWindow?, scope: ContactSheetScope, initial: ContactSheetOptions,
                        completion: @escaping (ContactSheetRequest?) -> Void) {
        if let responder = responderForTesting {
            completion(responder(scope, initial))
            return
        }
        open?.finish(nil)
        let sheet = ContactSheetSheet(scope: scope, initial: initial)
        sheet.completion = completion
        open = sheet
        let panel = sheet.build()
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(sheet.titleField)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func build() -> NSPanel {
        allRadio.title = scope.allTitle
        selectedRadio.title = scope.selectedTitle
        allRadio.state = .on
        selectedRadio.state = .off
        for radio in [allRadio, selectedRadio] {
            radio.target = self
            radio.action = #selector(radioChanged(_:))
        }
        titleField.stringValue = initial.title
        titleField.placeholderString = "Contact sheet"
        titleField.setAccessibilityLabel("Title")
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let range = ContactSheetOptions.columnRange
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = initial.columns
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.setAccessibilityLabel("Columns")
        columnsField.integerValue = initial.columns
        columnsField.alignment = .right
        columnsField.delegate = self
        columnsField.target = self
        columnsField.action = #selector(columnsTyped)
        columnsField.setAccessibilityLabel("Columns")
        columnsField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let rangeNote = NSTextField(labelWithString: "\(range.lowerBound)–\(range.upperBound)")
        rangeNote.textColor = .secondaryLabelColor
        rangeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let columnsRow = NSStackView(views: [columnsField, stepper, rangeNote])
        columnsRow.spacing = 4
        columnsRow.setCustomSpacing(8, after: stepper)

        paperPopup.addItems(withTitles: ContactSheetForm.papers.map(\.title))
        paperPopup.selectItem(at: ContactSheetForm.papers.firstIndex { $0.value == initial.paper } ?? 0)
        paperPopup.setAccessibilityLabel("Paper")
        captionPopup.addItems(withTitles: ContactSheetForm.captions.map(\.title))
        captionPopup.selectItem(at: ContactSheetForm.captions.firstIndex { $0.value == initial.caption } ?? 1)
        captionPopup.setAccessibilityLabel("Caption")

        var rows: [[NSView]] = [[label("Images:"), allRadio]]
        if scope.offersSelection { rows.append([NSGridCell.emptyContentView, selectedRadio]) }
        rows += [
            [label("Title:"), titleField],
            [label("Columns:"), columnsRow],
            [label("Paper:"), paperPopup],
            [label("Caption:"), captionPopup],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let heading = NSTextField(labelWithString: "Contact Sheet")
        heading.font = .boldSystemFont(ofSize: 13)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let export = NSButton(title: "Export…", target: self, action: #selector(exportClicked))
        export.keyEquivalent = "\r"
        export.bezelColor = .controlAccentColor   // one accent
        let buttons = NSStackView(views: [cancel, export])
        buttons.spacing = 12

        let content = NSView()
        for v in [heading, grid, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: ContactSheetForm.width),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ContactSheetForm.width, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Contact Sheet"
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.defaultButtonCell = export.cell as? NSButtonCell
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    @objc private func radioChanged(_ sender: NSButton) {
        allRadio.state = sender === allRadio ? .on : .off
        selectedRadio.state = sender === selectedRadio ? .on : .off
    }

    @objc private func stepperChanged() { columnsField.integerValue = stepper.integerValue }

    /// A typed number in 3…8 moves the stepper at once.
    func controlTextDidChange(_ obj: Notification) {
        guard let n = Int(columnsField.stringValue.trimmingCharacters(in: .whitespaces)),
              ContactSheetOptions.columnRange.contains(n) else { return }
        stepper.integerValue = n
    }

    /// Commits the typed columns, clamped to 3…8.
    @objc private func columnsTyped() {
        let typed = columnsField.currentEditor()?.string ?? columnsField.stringValue
        let range = ContactSheetOptions.columnRange
        let n = min(max(Int(typed.trimmingCharacters(in: .whitespaces)) ?? stepper.integerValue,
                        range.lowerBound), range.upperBound)
        columnsField.integerValue = n
        stepper.integerValue = n
    }

    @objc private func cancelClicked() { finish(nil) }

    @objc private func exportClicked() {
        columnsTyped()
        let options = ContactSheetForm.options(
            title: titleField.stringValue, columns: stepper.integerValue,
            paperIndex: paperPopup.indexOfSelectedItem, captionIndex: captionPopup.indexOfSelectedItem)
        finish(ContactSheetRequest(options: options,
                                   selectedOnly: scope.offersSelection && selectedRadio.state == .on))
    }

    private func finish(_ request: ContactSheetRequest?) {
        if let panel {
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        }
        panel = nil
        let completion = self.completion
        self.completion = nil
        if Self.open === self { Self.open = nil }
        completion?(request)
    }

    // MARK: Test seams

    static func makeForTesting(scope: ContactSheetScope, initial: ContactSheetOptions,
                               completion: @escaping (ContactSheetRequest?) -> Void) -> ContactSheetSheet {
        let sheet = ContactSheetSheet(scope: scope, initial: initial)
        sheet.completion = completion
        _ = sheet.build()
        return sheet
    }
    var panelForTesting: NSPanel? { panel }
    var columnsFieldForTesting: NSTextField { columnsField }
    var stepperForTesting: NSStepper { stepper }
    var paperPopupForTesting: NSPopUpButton { paperPopup }
    var captionPopupForTesting: NSPopUpButton { captionPopup }
    var titleFieldForTesting: NSTextField { titleField }
    var allRadioForTesting: NSButton { allRadio }
    var selectedRadioForTesting: NSButton { selectedRadio }
    func selectRadioForTesting(_ selected: Bool) { radioChanged(selected ? selectedRadio : allRadio) }
    func stepForTesting() { stepperChanged() }
    func exportForTesting() { exportClicked() }
    func cancelForTesting() { cancelClicked() }
}

// MARK: - The Browser's flow

extension BrowserWindowController {

    /// Tests answer the Save panel here (file name → URL; nil = Cancel).
    static var contactSheetSaveResponderForTesting: ((String) -> URL?)?

    /// File ▸ Export Contact Sheet…: the sheet, the Save panel, the PDF.
    func showContactSheetSheet() {
        let all = contentController.visibleItems.map(\.group)
        guard !all.isEmpty else { return }
        let selected = contentController.selectedItems.map(\.group)
        let folder = currentFolder?.lastPathComponent ?? ""
        let scope = ContactSheetScope(allCount: all.count, folderName: folder, selectedCount: selected.count)
        let store = PrintSettingsStore.standard
        let initial = ContactSheetOptions(title: folder, settings: store.load())
        ContactSheetSheet.present(on: window, scope: scope, initial: initial) { [weak self] request in
            guard let self, let request else { return }
            store.update { $0.remember(request.options) }
            let groups = request.selectedOnly ? selected : all
            self.askContactSheetDestination(request.options.title) { [weak self] url in
                guard let self, let url else { return }
                self.exportContactSheet(groups, options: request.options, to: url)
            }
        }
    }

    /// The Save panel, as a sheet, starting in the listed folder.
    private func askContactSheetDestination(_ title: String, completion: @escaping @MainActor (URL?) -> Void) {
        let name = ContactSheetForm.fileName(for: title)
        if let responder = Self.contactSheetSaveResponderForTesting {
            completion(responder(name))
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        panel.isExtensionHidden = false
        if let folder = currentFolder { panel.directoryURL = folder }
        guard let window else {
            completion(panel.runModal() == .OK ? panel.url : nil)
            return
        }
        // Save panel completions run on the main thread (as FileTransfer).
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Makes the PDF off the main thread with a progress toast, then
    /// "Saved “…”." · Show. A second export cancels the first.
    func exportContactSheet(_ groups: [ImageGroup], options: ContactSheetOptions, to url: URL) {
        let cache = services.thumbnailCache
        let name = url.lastPathComponent
        contactSheetExport?.cancel()
        toast(ContactSheetForm.progressText(0), progress: 0)
        contactSheetExport = Task { @MainActor [weak self] in
            var shown = 0
            do {
                for try await fraction in ContactSheetRenderer.render(groups, options: options,
                                                                        thumbnails: cache, to: url) {
                    let percent = ContactSheetForm.percent(fraction)
                    guard percent != shown, !Task.isCancelled, let self else { continue }
                    shown = percent
                    self.toast(ContactSheetForm.progressText(fraction), progress: fraction)
                }
                guard !Task.isCancelled, let self else { return }
                self.toast(ContactSheetForm.savedText(name), actionTitle: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                self.contactSheetSavedForTesting?(url)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, let self else { return }
                self.toast(ContactSheetForm.failedText(name), kind: .error)
                self.contactSheetSavedForTesting?(nil)
            }
        }
    }

    /// Waits for the contact sheet being made (tests).
    func waitForContactSheet() async { await contactSheetExport?.value }
}
