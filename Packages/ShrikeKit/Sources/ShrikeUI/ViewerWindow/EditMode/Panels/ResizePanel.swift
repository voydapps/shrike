//
//  ResizePanel.swift
//  ShrikeUI
//
//  Right-rail Resize tool panel. Spec
//  W/H fields (linked by default), percent entry, prevent-upscale,
//  interpolation popup, Apply.
//

import AppKit
import ShrikeEdit

@MainActor
final class ResizePanel: NSView {

    // MARK: - Public

    /// Fired when Apply is clicked with the currently-configured `ResizeSpec`.
    /// The source pixel size of the current image is required to resolve
    /// percent → px; it is passed into `applyWithSourceSize(_:)`.
    var onApply: ((ResizeSpec) -> Void)?

    /// Fired whenever any field changes so the controller can render
    /// a live draft preview. `ResizeSpec` is built against the caller-
    /// provided `sourcePixelSize`.
    var onSpecChanged: ((ResizeSpec) -> Void)?

    /// Tracked pixel size of the source the panel is resizing. The
    /// controller sets this on entry and on every op that changes the
    /// intermediate image. Default (0, 0) is a sentinel "unknown" —
    /// the panel guards against div-by-zero.
    var sourcePixelSize: CGSize = .zero {
        didSet {
            if sourcePixelSize.width > 0 && sourcePixelSize.height > 0 &&
                widthField.stringValue.isEmpty {
                setDimensionsFromSource()
            }
            updatePreviewLabel()
        }
    }

    // MARK: - State

    private(set) var maintainAspect: Bool = true
    private(set) var preventUpscale: Bool = true
    private(set) var interpolation: Interpolation = .lanczos

    // MARK: - Subviews

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let percentField = NSTextField()
    private let maintainCheckbox = NSButton(
        checkboxWithTitle: "Maintain aspect",
        target: nil,
        action: nil
    )
    private let preventUpscaleCheckbox = NSButton(
        checkboxWithTitle: "Don't upscale",
        target: nil,
        action: nil
    )
    private let interpPopup = NSPopUpButton()
    private let previewLabel = NSTextField(labelWithString: "—")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for f in [widthField, heightField, percentField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            f.alignment = .right
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.target = self
        }
        widthField.action = #selector(handleWidthEdit(_:))
        heightField.action = #selector(handleHeightEdit(_:))
        percentField.action = #selector(handlePercentEdit(_:))

        maintainCheckbox.translatesAutoresizingMaskIntoConstraints = false
        maintainCheckbox.state = .on
        maintainCheckbox.target = self
        maintainCheckbox.action = #selector(handleMaintainToggle(_:))

        preventUpscaleCheckbox.translatesAutoresizingMaskIntoConstraints = false
        preventUpscaleCheckbox.state = .on
        preventUpscaleCheckbox.target = self
        preventUpscaleCheckbox.action = #selector(handlePreventUpscaleToggle(_:))

        interpPopup.translatesAutoresizingMaskIntoConstraints = false
        interpPopup.addItem(withTitle: "Lanczos")
        interpPopup.addItem(withTitle: "Bicubic")
        interpPopup.addItem(withTitle: "Bilinear")
        interpPopup.addItem(withTitle: "Nearest")
        interpPopup.selectItem(at: 0)
        interpPopup.target = self
        interpPopup.action = #selector(handleInterpChange(_:))

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.useAccentFill()   // one accent
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.target = self
        applyButton.action = #selector(handleApply(_:))

        let widthRow = labelled("W", field: widthField)
        let heightRow = labelled("H", field: heightField)
        let percentRow = labelled("%", field: percentField)

        let stack = NSStackView(views: [
            sectionLabel("New size"),
            widthRow, heightRow,
            sectionLabel("Or"),
            percentRow,
            maintainCheckbox,
            preventUpscaleCheckbox,
            sectionLabel("Resample"),
            interpPopup,
            sectionLabel("Preview"),
            previewLabel,
            applyButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            widthField.widthAnchor.constraint(equalToConstant: 80),
            heightField.widthAnchor.constraint(equalToConstant: 80),
            percentField.widthAnchor.constraint(equalToConstant: 60),
            interpPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func labelled(_ text: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Actions

    @objc private func handleWidthEdit(_ sender: NSTextField) {
        guard let w = Int(sender.stringValue), w > 0 else { return }
        if maintainAspect,
           sourcePixelSize.width > 0, sourcePixelSize.height > 0 {
            let ratio = Double(sourcePixelSize.height) / Double(sourcePixelSize.width)
            let h = max(1, Int((Double(w) * ratio).rounded()))
            heightField.stringValue = String(h)
        }
        syncPercentFromDims()
        updatePreviewLabel()
        emitSpec()
    }

    @objc private func handleHeightEdit(_ sender: NSTextField) {
        guard let h = Int(sender.stringValue), h > 0 else { return }
        if maintainAspect,
           sourcePixelSize.width > 0, sourcePixelSize.height > 0 {
            let ratio = Double(sourcePixelSize.width) / Double(sourcePixelSize.height)
            let w = max(1, Int((Double(h) * ratio).rounded()))
            widthField.stringValue = String(w)
        }
        syncPercentFromDims()
        updatePreviewLabel()
        emitSpec()
    }

    @objc private func handlePercentEdit(_ sender: NSTextField) {
        guard let pct = Double(sender.stringValue), pct > 0 else { return }
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else { return }
        let w = max(1, Int((Double(sourcePixelSize.width) * pct / 100.0).rounded()))
        let h = max(1, Int((Double(sourcePixelSize.height) * pct / 100.0).rounded()))
        widthField.stringValue = String(w)
        heightField.stringValue = String(h)
        updatePreviewLabel()
        emitSpec()
    }

    @objc private func handleMaintainToggle(_ sender: NSButton) {
        maintainAspect = (sender.state == .on)
        if maintainAspect {
            // Snap height to aspect based on current width.
            handleWidthEdit(widthField)
        }
    }

    @objc private func handlePreventUpscaleToggle(_ sender: NSButton) {
        preventUpscale = (sender.state == .on)
        emitSpec()
    }

    @objc private func handleInterpChange(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 0: interpolation = .lanczos
        case 1: interpolation = .bicubic
        case 2: interpolation = .bilinear
        case 3: interpolation = .nearest
        default: interpolation = .lanczos
        }
        emitSpec()
    }

    @objc private func handleApply(_ sender: NSButton) {
        if let spec = currentSpec() {
            onApply?(spec)
        }
    }

    // MARK: - Helpers

    private func setDimensionsFromSource() {
        widthField.stringValue = String(Int(sourcePixelSize.width))
        heightField.stringValue = String(Int(sourcePixelSize.height))
        percentField.stringValue = "100"
    }

    private func syncPercentFromDims() {
        guard sourcePixelSize.width > 0 else { return }
        let w = Double(widthField.integerValue)
        let pct = (w / Double(sourcePixelSize.width)) * 100.0
        percentField.stringValue = String(format: "%.1f", pct)
    }

    private func updatePreviewLabel() {
        let sw = Int(sourcePixelSize.width)
        let sh = Int(sourcePixelSize.height)
        let tw = widthField.integerValue
        let th = heightField.integerValue
        guard sw > 0, sh > 0 else {
            previewLabel.stringValue = "—"
            return
        }
        if tw > 0, th > 0 {
            previewLabel.stringValue = "\(sw)×\(sh) → \(tw)×\(th)"
        } else {
            previewLabel.stringValue = "\(sw)×\(sh)"
        }
    }

    private func emitSpec() {
        guard let spec = currentSpec() else { return }
        onSpecChanged?(spec)
    }

    /// Build a `ResizeSpec` from the current field values. Returns nil
    /// when either W or H is missing / non-positive — the live-preview
    /// path treats that as "don't render yet".
    func currentSpec() -> ResizeSpec? {
        let w = widthField.integerValue
        let h = heightField.integerValue
        guard w > 0, h > 0 else { return nil }
        return ResizeSpec(
            width: w,
            height: h,
            interpolation: interpolation,
            preventUpscale: preventUpscale
        )
    }

    // MARK: - Test seams

    internal var _widthField: NSTextField { widthField }
    internal var _heightField: NSTextField { heightField }
    internal var _percentField: NSTextField { percentField }
    internal var _interpPopup: NSPopUpButton { interpPopup }
    internal var _applyButton: NSButton { applyButton }
    internal var _maintainCheckbox: NSButton { maintainCheckbox }

    /// Pure round-trip helper — tests use this to confirm the popup
    /// index ↔ `Interpolation` mapping.
    static func interpolation(forPopupIndex index: Int) -> Interpolation {
        switch index {
        case 0: return .lanczos
        case 1: return .bicubic
        case 2: return .bilinear
        case 3: return .nearest
        default: return .lanczos
        }
    }

    static func popupIndex(for interpolation: Interpolation) -> Int {
        switch interpolation {
        case .lanczos:  return 0
        case .bicubic:  return 1
        case .bilinear: return 2
        case .nearest:  return 3
        }
    }
}
