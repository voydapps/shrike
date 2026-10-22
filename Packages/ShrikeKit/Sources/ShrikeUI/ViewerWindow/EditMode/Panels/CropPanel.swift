//
//  CropPanel.swift
//  ShrikeUI
//
//  Right-side Crop tool panel. Spec
//  Controls the aspect picker, W/H numeric fields, thirds / golden grid
//  toggles, and Apply / Reset buttons. The on-canvas overlay (crop rect
//  with 8 handles) lives in `CropOverlayView.swift`; this file emits the
//  rect it currently wants via `onRectChanged`.
//

import AppKit
import ShrikeEdit

@MainActor
final class CropPanel: NSView, NSTextFieldDelegate {

    // MARK: - Types

    /// Aspect presets `freeform` is the unlocked entry; every
    /// other case constrains the rect to a specific ratio. `value`
    /// returns W/H for locked presets, `nil` for freeform.
    enum Aspect: Int, CaseIterable {
        case freeform
        case original
        case square
        case threeByTwo
        case fourByThree
        case sixteenByNine
        case golden

        var title: String {
            switch self {
            case .freeform:      return "Freeform"
            case .original:      return "Original"
            case .square:        return "1:1"
            case .threeByTwo:    return "3:2"
            case .fourByThree:   return "4:3"
            case .sixteenByNine: return "16:9"
            case .golden:        return "Golden (1.618)"
            }
        }

        /// Returns `width/height`. `nil` = freeform. `original` is
        /// resolved against the source image at the panel layer.
        var ratio: Double? {
            switch self {
            case .freeform:      return nil
            case .original:      return nil
            case .square:        return 1.0
            case .threeByTwo:    return 3.0 / 2.0
            case .fourByThree:   return 4.0 / 3.0
            case .sixteenByNine: return 16.0 / 9.0
            case .golden:        return 1.6180339887
            }
        }
    }

    // MARK: - Public

    /// Fired when the Apply button is clicked. The panel owner builds
    /// the `CropRect` from the overlay (which already tracks the
    /// user's on-canvas rect).
    var onApply: (() -> Void)?
    /// Fired when the Reset button is clicked.
    var onReset: (() -> Void)?
    /// Fired when the aspect picker selection changes.
    var onAspectChanged: ((Aspect) -> Void)?
    /// Fired when the user types a new W or H value.
    var onDimensionsEdited: ((Int?, Int?, Axis) -> Void)?
    var onDraftChanged: (() -> Void)?
    private var editedDimension: Axis?
    var dimensionDraft: (width: Int?, height: Int?, side: Axis)? {
        editedDimension.map { (Int(widthField.stringValue), Int(heightField.stringValue), $0) }
    }
    func controlTextDidBeginEditing(_ notification: Notification) { trackDimensionDraft(notification) }
    func controlTextDidChange(_ notification: Notification) { trackDimensionDraft(notification) }
    func controlTextDidEndEditing(_ notification: Notification) {
        editedDimension = nil
        onDraftChanged?()
    }
    private func trackDimensionDraft(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === widthField || field === heightField else { return }
        editedDimension = field === widthField ? .width : .height
        onDraftChanged?()
    }
    /// Fired when thirds-grid toggle flips.
    var onShowThirdsChanged: ((Bool) -> Void)?
    /// Fired when golden-grid toggle flips.
    var onShowGoldenChanged: ((Bool) -> Void)?

    // MARK: - State

    private(set) var aspect: Aspect = .freeform {
        didSet {
            aspectPopup.selectItem(at: aspect.rawValue)
        }
    }

    // MARK: - Subviews

    private let aspectPopup = NSPopUpButton()
    private let widthField = PanelTextField()
    private let heightField = PanelTextField()
    private let thirdsCheckbox = NSButton(checkboxWithTitle: "Thirds grid",
                                          target: nil,
                                          action: nil)
    private let goldenCheckbox = NSButton(checkboxWithTitle: "Golden grid",
                                          target: nil,
                                          action: nil)
    private let resetButton = NSButton(title: "Reset Crop",
                                       target: nil,
                                       action: nil)
    private let applyButton = NSButton(title: "Apply Crop",
                                       target: nil,
                                       action: nil)

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() {
        for control in [aspectPopup, thirdsCheckbox, goldenCheckbox, resetButton, applyButton] { ChromeTypography.initializeNativeFont(control) }
        let aspectLabel = sectionLabel("Aspect")

        aspectPopup.translatesAutoresizingMaskIntoConstraints = false
        for preset in Aspect.allCases {
            aspectPopup.addItem(withTitle: preset.title)
        }
        aspectPopup.selectItem(at: 0)
        aspectPopup.target = self
        aspectPopup.action = #selector(handleAspect(_:))

        let widthLabel = fieldLabel("W")
        let heightLabel = fieldLabel("H")
        configureNumericField(widthField)
        configureNumericField(heightField)
        widthField.target = self
        widthField.action = #selector(handleDimensionEdit(_:))
        heightField.target = self
        heightField.action = #selector(handleDimensionEdit(_:))

        thirdsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        thirdsCheckbox.target = self
        thirdsCheckbox.action = #selector(handleThirdsToggle(_:))

        goldenCheckbox.translatesAutoresizingMaskIntoConstraints = false
        goldenCheckbox.target = self
        goldenCheckbox.action = #selector(handleGoldenToggle(_:))

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(handleReset(_:))

        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.bezelStyle = .rounded
        // Plain bezel, no key equivalent: Done is the one accent and the one Return (spec 25 §3.1).
        applyButton.target = self
        applyButton.action = #selector(handleApply(_:))
        widthField.setAccessibilityLabel("Crop width, pixels")
        heightField.setAccessibilityLabel("Crop height, pixels")
        aspectPopup.setAccessibilityLabel("Aspect ratio")

        let widthRow = NSStackView(views: [widthLabel, widthField])
        widthRow.orientation = .horizontal
        widthRow.spacing = 6
        widthRow.translatesAutoresizingMaskIntoConstraints = false

        let heightRow = NSStackView(views: [heightLabel, heightField])
        heightRow.orientation = .horizontal
        heightRow.spacing = 6
        heightRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            aspectLabel,
            aspectPopup,
            widthRow,
            heightRow,
            thirdsCheckbox,
            goldenCheckbox,
            applyButton,
            resetButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            widthField.widthAnchor.constraint(equalToConstant: EditLayout.numericFieldWidth),
            heightField.widthAnchor.constraint(equalToConstant: EditLayout.numericFieldWidth),
            aspectPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeTypography.font(12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeTypography.font(12, weight: .regular)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: EditLayout.fieldLabelColumnWidth).isActive = true
        return label
    }

    private func configureNumericField(_ field: PanelTextField) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        // Resolve numeric geometry on ordinary focus changes as well as Return.
        field.commitsOnFocusLoss = true
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: ChromeTypography.size(12), weight: .regular)
        field.placeholderString = "px"
    }

    // MARK: - Actions

    @objc private func handleAspect(_ sender: NSPopUpButton) {
        guard let preset = Aspect(rawValue: sender.indexOfSelectedItem) else { return }
        aspect = preset
        onAspectChanged?(preset)
    }

    @objc private func handleDimensionEdit(_ sender: NSTextField) {
        let w = Int(widthField.stringValue)
        let h = Int(heightField.stringValue)
        editedDimension = nil
        onDimensionsEdited?(w, h, sender === widthField ? .width : .height)
        onDraftChanged?()
    }

    @objc private func handleThirdsToggle(_ sender: NSButton) {
        onShowThirdsChanged?(sender.state == .on)
    }

    @objc private func handleGoldenToggle(_ sender: NSButton) {
        onShowGoldenChanged?(sender.state == .on)
    }

    @objc private func handleReset(_ sender: NSButton) {
        onReset?()
    }

    @objc private func handleApply(_ sender: NSButton) {
        onApply?()
    }

    // MARK: - Public setters

    func setDimensions(width: Int, height: Int) {
        editedDimension = nil
        widthField.stringValue = String(width)
        heightField.stringValue = String(height)
        onDraftChanged?()
    }

    func setAspect(_ preset: Aspect) {
        aspect = preset
    }

    // MARK: - Test seams

    internal var _aspectPopup: NSPopUpButton { aspectPopup }
    internal var _widthField: NSTextField { widthField }
    internal var _heightField: NSTextField { heightField }
    internal var _applyButton: NSButton { applyButton }
    internal var _resetButton: NSButton { resetButton }
    internal var _thirdsCheckbox: NSButton { thirdsCheckbox }
    internal var _goldenCheckbox: NSButton { goldenCheckbox }

    /// Pure aspect-math helper — given a locked `ratio`, an input rect
    /// side that the user just typed, and which side they edited,
    /// return the complementary side. Extracted so
    /// `EditToolPanelsTests` can exercise the math without instantiating
    /// an NSView.
    static func complement(
        ratio: Double,
        edited editedValue: Int,
        editedSide: Axis
    ) -> Int {
        guard ratio > 0 else { return editedValue }
        switch editedSide {
        case .width:
            return max(1, Int((Double(editedValue) / ratio).rounded()))
        case .height:
            return max(1, Int((Double(editedValue) * ratio).rounded()))
        }
    }

    enum Axis { case width, height }
}
