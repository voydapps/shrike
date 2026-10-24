//
//  SlideshowSheet.swift
//  ShrikeUI
//
//  The slideshow config sheet: 420 pt
//  wide, padding 20. Show (all / selected), Each image (stepper 1–60),
//  Transition, Order, Fit, Loop; Cancel / Start (default).
//

import AppKit
import ShrikeCore

/// The sheet's answer.
struct SlideshowRequest: Equatable {
    var settings: SlideshowSettings
    /// True: only the Browser's selected images.
    var selectedOnly: Bool
}

/// "Each image": whole seconds 1–60. Letters and a third
/// digit are refused while typing; a value out of range is clamped when
/// the field commits (no "invalid value" alert blocking Return).
final class SlideshowIntervalFormatter: Formatter {
    static let range = 1...60

    override func string(for obj: Any?) -> String? {
        if let n = obj as? NSNumber { return "\(n.intValue)" }
        return obj as? String
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = NSNumber(value: Self.clamp(string))
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                       newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.count <= 2 && partialString.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Empty or 0 → 1; above 60 → 60.
    static func clamp(_ string: String) -> Int {
        let n = Int(string.trimmingCharacters(in: .whitespaces)) ?? range.lowerBound
        return min(max(n, range.lowerBound), range.upperBound)
    }
}

@MainActor
final class SlideshowSheet: NSObject, NSTextFieldDelegate {

    /// Tests answer here instead of a sheet (nil = Cancel).
    static var responderForTesting: ((SlideshowScope, SlideshowSettings) -> SlideshowRequest?)?

    private let scope: SlideshowScope
    private var settings: SlideshowSettings
    private var panel: NSPanel?
    private let allRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let selectedRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let intervalField = NSTextField()
    private let stepper = NSStepper()
    private let transitionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loopBox = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private var completion: ((SlideshowRequest?) -> Void)?
    private static var open: SlideshowSheet?

    private init(scope: SlideshowScope, settings: SlideshowSettings) {
        self.scope = scope
        self.settings = settings
    }

    /// Shows the sheet on `window` (or answers from the test responder).
    static func present(on window: NSWindow?, scope: SlideshowScope,
                        completion: @escaping (SlideshowRequest?) -> Void) {
        let settings = SlideshowSettings.fromPrefs()
        if let responder = responderForTesting {
            completion(responder(scope, settings))
            return
        }
        let sheet = SlideshowSheet(scope: scope, settings: settings)
        sheet.completion = completion
        open = sheet
        let panel = sheet.build()
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func build() -> NSPanel {
        allRadio.title = scope.allTitle
        allRadio.state = scope.defaultsToSelection ? .off : .on
        selectedRadio.state = scope.defaultsToSelection ? .on : .off
        selectedRadio.title = scope.selectedTitle
        for radio in [allRadio, selectedRadio] {
            radio.target = self
            radio.action = #selector(radioChanged(_:))
        }
        stepper.minValue = 1
        stepper.maxValue = 60
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = settings.intervalSec
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        intervalField.integerValue = settings.intervalSec
        intervalField.alignment = .right
        intervalField.formatter = SlideshowIntervalFormatter()
        intervalField.delegate = self
        intervalField.target = self
        intervalField.action = #selector(fieldChanged)
        intervalField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        intervalField.setAccessibilityLabel("Seconds per photo")
        let intervalRow = NSStackView(views: [intervalField, stepper, NSTextField(labelWithString: "seconds")])
        intervalRow.spacing = 4

        transitionPopup.addItems(withTitles: SlideshowTransition.allCases.map(\.title))
        transitionPopup.selectItem(withTitle: settings.transition.title)
        orderPopup.addItems(withTitles: ["In order", "Random"])
        orderPopup.selectItem(at: settings.random ? 1 : 0)
        fitPopup.addItems(withTitles: ["Fit to screen", "Fill screen (crop)"])
        fitPopup.selectItem(at: settings.fill ? 1 : 0)
        loopBox.state = settings.loop ? .on : .off

        var rows: [[NSView]] = [[label("Show:"), allRadio]]
        if scope.offersSelection { rows.append([NSGridCell.emptyContentView, selectedRadio]) }
        rows += [
            [label("Each photo:"), intervalRow],
            [label("Transition:"), transitionPopup],
            [label("Order:"), orderPopup],
            [label("Fit:"), fitPopup],
            [NSGridCell.emptyContentView, loopBox],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let title = NSTextField(labelWithString: "Slideshow")
        title.font = .boldSystemFont(ofSize: 13)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let start = NSButton(title: "Start", target: self, action: #selector(startClicked))
        start.keyEquivalent = "\r"
        start.useAccentFill()   // one accent
        startButton = start
        let buttons = NSStackView(views: [cancel, start])
        buttons.spacing = 12

        let content = NSView()
        for v in [title, grid, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 420),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Slideshow"
        panel.contentView = content
        panel.defaultButtonCell = start.cell as? NSButtonCell
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    @objc private func radioChanged(_ sender: NSButton) {
        allRadio.state = sender === allRadio ? .on : .off
        selectedRadio.state = sender === selectedRadio ? .on : .off
    }

    private var startButton: NSButton?

    @objc private func stepperChanged() { intervalField.integerValue = stepper.integerValue }
    @objc private func fieldChanged() {
        let typed = intervalField.currentEditor()?.string ?? intervalField.stringValue
        let n = SlideshowIntervalFormatter.clamp(typed)
        intervalField.integerValue = n
        stepper.integerValue = n
    }

    /// Return while typing in "Each image" presses Start (the default
    /// button), with the typed value.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === intervalField,
              commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let n = SlideshowIntervalFormatter.clamp(textView.string)
        intervalField.integerValue = n
        stepper.integerValue = n
        startClicked()
        return true
    }

    // MARK: Test seams

    /// Builds the sheet's panel without showing it.
    static func makeForTesting(scope: SlideshowScope, settings: SlideshowSettings,
                               completion: @escaping (SlideshowRequest?) -> Void) -> SlideshowSheet {
        let sheet = SlideshowSheet(scope: scope, settings: settings)
        sheet.completion = completion
        _ = sheet.build()
        return sheet
    }
    var allRadioForTesting: NSButton { allRadio }
    var selectedRadioForTesting: NSButton { selectedRadio }
    var intervalFieldForTesting: NSTextField { intervalField }
    var stepperForTesting: NSStepper { stepper }
    var panelForTesting: NSPanel? { panel }

    @objc private func cancelClicked() { finish(nil) }

    @objc private func startClicked() {
        fieldChanged()
        settings.intervalSec = stepper.integerValue
        settings.transition = SlideshowTransition.allCases[max(0, transitionPopup.indexOfSelectedItem)]
        settings.random = orderPopup.indexOfSelectedItem == 1
        settings.fill = fitPopup.indexOfSelectedItem == 1
        settings.loop = loopBox.state == .on
        settings.save()
        finish(SlideshowRequest(settings: settings,
                                selectedOnly: scope.offersSelection && selectedRadio.state == .on))
    }

    private func finish(_ request: SlideshowRequest?) {
        if let panel {
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        }
        panel = nil
        let completion = self.completion
        self.completion = nil
        Self.open = nil
        completion?(request)
    }
}
