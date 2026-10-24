//
//  ResizePanel.swift
//  ShrikeUI
//
//  Right-side Resize tool panel. Spec
//  W/H fields (linked by default), percent entry, prevent-upscale,
//  interpolation popup, Apply.
//

import AppKit
import ShrikeEdit

@MainActor
final class ResizePanel: NSView, NSTextFieldDelegate {

    // MARK: - Public

    /// Fired when Apply is clicked with the currently-configured `ResizeSpec`.
    /// The source pixel size of the current image is required to resolve
    /// percent → px; it is passed into `applyWithSourceSize(_:)`.
    var onApply: ((ResizeSpec) -> Void)?

    /// Fired whenever any field changes so the controller can render
    /// a live draft preview. `ResizeSpec` is built against the caller-
    /// provided `sourcePixelSize`.
    var onSpecChanged: ((ResizeSpec) -> Void)?
    /// Includes focused invalid/empty drafts without committing their field actions.
    var onDraftChanged: (() -> Void)?
    private enum DraftField { case width, height, percent }
    private var editedField: DraftField?
    func controlTextDidBeginEditing(_ notification: Notification) { trackDraftField(notification) }
    func controlTextDidChange(_ notification: Notification) { trackDraftField(notification) }
    func controlTextDidEndEditing(_ notification: Notification) {
        editedField = nil
        onDraftChanged?()
    }
    private func trackDraftField(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === widthField { editedField = .width }
        else if field === heightField { editedField = .height }
        else if field === percentField { editedField = .percent }
        else { return }
        onDraftChanged?()
    }

    /// Tracked pixel size of the source the panel is resizing. The
    /// controller sets this on entry and on every op that changes the
    /// intermediate image. Default (0, 0) is a sentinel "unknown" —
    /// the panel guards against div-by-zero.
    var sourcePixelSize: CGSize = .zero {
        didSet {
            // A clean panel follows restored geometry (Undo/Redo/Reset).
            // An unapplied target belongs to the user, even when an older
            // render is only now reporting the new source dimensions.
            let wasClean = widthField.integerValue == Int(oldValue.width)
                && heightField.integerValue == Int(oldValue.height)
            if sourcePixelSize.width > 0 && sourcePixelSize.height > 0 &&
                (widthField.stringValue.isEmpty || wasClean) {
                setDimensionsFromSource()
            }
            updatePreviewLabel()
        }
    }

    struct Draft {
        let width: String
        let height: String
        let percent: String
    }
    var draft: Draft { Draft(width: widthField.stringValue, height: heightField.stringValue, percent: percentField.stringValue) }
    func restoreDraft(_ draft: Draft) {
        widthField.stringValue = draft.width
        heightField.stringValue = draft.height
        percentField.stringValue = draft.percent
        updatePreviewLabel()
    }

    // MARK: - State

    private(set) var maintainAspect: Bool = true
    private(set) var preventUpscale: Bool = true
    private(set) var interpolation: Interpolation = .lanczos

    // MARK: - Subviews

    private let widthField = PanelTextField()
    private let heightField = PanelTextField()
    private let percentField = PanelTextField()
    private let percentSuffix = NSTextField(labelWithString: "%")
    private var percentFieldWidth: NSLayoutConstraint?
    private let maintainCheckbox = NSButton(
        checkboxWithTitle: "Maintain aspect",
        target: nil,
        action: nil
    )
    private let preventUpscaleCheckbox = NSButton(
        checkboxWithTitle: "Don't enlarge",
        target: nil,
        action: nil
    )
    private let interpPopup = NSPopUpButton()
    private let previewLabel = NSTextField(labelWithString: "—")
    private let applyButton = NSButton(title: "Apply Resize", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for control in [maintainCheckbox, preventUpscaleCheckbox, interpPopup, applyButton, resetButton] { ChromeTypography.initializeNativeFont(control) }
        // Numeric overflow belongs to AppKit's native horizontal field editor.
        percentField.cell?.isScrollable = true
        percentField.cell?.usesSingleLineMode = true
        percentField.cell?.wraps = false
        percentField.cell?.lineBreakMode = .byClipping
        for f in [widthField, heightField, percentField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            f.alignment = .right
            f.font = .monospacedDigitSystemFont(ofSize: ChromeTypography.size(12), weight: .regular)
            f.target = self
            f.delegate = self
            // Tab and click-away resolve the same draft as Return, without
            // accepting a resize operation into history.
            f.commitsOnFocusLoss = true
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
        previewLabel.font = ChromeTypography.font(12)
        previewLabel.textColor = .secondaryLabelColor

        applyButton.bezelStyle = .rounded
        // Plain bezel, no key equivalent: Done is the one accent and the one Return (spec 25 §3.1).
        applyButton.isEnabled = false
        widthField.setAccessibilityLabel("Resize width, pixels")
        heightField.setAccessibilityLabel("Resize height, pixels")
        percentField.setAccessibilityLabel("Resize percent")
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.target = self
        applyButton.action = #selector(handleApply(_:))

        let widthRow = labelled("Width", field: widthField)
        let heightRow = labelled("Height", field: heightField)
        let percentRow = labelled("Scale", field: percentField)
        // Keep the decorative unit outside the native numeric field (spec 16 §3.3).
        let suffix = percentSuffix
        suffix.font = ChromeTypography.font(12)
        suffix.textColor = .secondaryLabelColor
        suffix.translatesAutoresizingMaskIntoConstraints = false
        suffix.setAccessibilityElement(false)
        suffix.isSelectable = false
        suffix.setContentHuggingPriority(.required, for: .horizontal)
        suffix.setContentCompressionResistancePriority(.required, for: .horizontal)
        percentRow.addArrangedSubview(suffix)
        percentRow.setCustomSpacing(8, after: percentField)
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.target = self
        resetButton.action = #selector(handleReset(_:))

        let stack = NSStackView(views: [
            sectionLabel("New size"),
            widthRow, heightRow,
            percentRow,
            maintainCheckbox,
            preventUpscaleCheckbox,
            sectionLabel("Resample"),
            interpPopup,
            sectionLabel("Preview"),
            previewLabel,
            applyButton,
            resetButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let percentWidth = percentField.widthAnchor.constraint(equalToConstant: max(EditLayout.numericFieldWidth, minimumPercentWidth))
        percentFieldWidth = percentWidth
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            widthField.widthAnchor.constraint(equalToConstant: EditLayout.numericFieldWidth),
            heightField.widthAnchor.constraint(equalToConstant: EditLayout.numericFieldWidth),
            percentWidth,
            interpPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private var minimumPercentWidth: CGFloat {
        let font = percentField.font ?? .monospacedDigitSystemFont(ofSize: ChromeTypography.size(12), weight: .regular)
        let common = ("100.0" as NSString).size(withAttributes: [.font: font]).width
        let probe = NSRect(x: 0, y: 0, width: 120, height: 28)
        let text = percentField.cell?.drawingRect(forBounds: probe) ?? probe
        return ceil(max(0, probe.width - text.width) + common + 2)
    }

    override func layout() {
        if let width = percentFieldWidth {
            let measured = max(EditLayout.numericFieldWidth, minimumPercentWidth)
            if width.constant != measured { width.constant = measured }
        }
        super.layout()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = ChromeTypography.font(12, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private let resetButton = NSButton(title: "Reset Resize", target: nil, action: nil)

    private func labelled(_ text: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeTypography.font(12)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: EditLayout.fieldLabelColumnWidth).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Actions

    /// The same resolution is used by a real field commit and the primary-caption projection.
    /// Reading it never changes the field editor or the linked controls.
    private func dimensions(afterEditing field: DraftField?) -> (width: Int, height: Int)? {
        let width = Int(widthField.stringValue), height = Int(heightField.stringValue)
        func pixels(_ value: Double) -> Int? {
            guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
            return max(1, Int(value.rounded()))
        }
        switch field {
        case .width:
            guard let width, width > 0 else { return nil }
            if maintainAspect, sourcePixelSize.width > 0, sourcePixelSize.height > 0 {
                guard let height = pixels(Double(width) * Double(sourcePixelSize.height / sourcePixelSize.width)) else { return nil }
                return (width, height)
            }
        case .height:
            guard let height, height > 0 else { return nil }
            if maintainAspect, sourcePixelSize.width > 0, sourcePixelSize.height > 0 {
                guard let width = pixels(Double(height) * Double(sourcePixelSize.width / sourcePixelSize.height)) else { return nil }
                return (width, height)
            }
        case .percent:
            guard let percent = Double(percentField.stringValue), percent.isFinite, percent > 0,
                  sourcePixelSize.width > 0, sourcePixelSize.height > 0,
                  let width = pixels(Double(sourcePixelSize.width) * percent / 100),
                  let height = pixels(Double(sourcePixelSize.height) * percent / 100) else { return nil }
            return (width, height)
        case nil: break
        }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    @objc private func handleWidthEdit(_ sender: NSTextField) {
        editedField = nil
        guard let dimensions = dimensions(afterEditing: .width) else { onDraftChanged?(); return }
        if maintainAspect { heightField.stringValue = String(dimensions.height) }
        syncPercentFromDims()
        updatePreviewLabel()
        emitSpec()
    }

    @objc private func handleHeightEdit(_ sender: NSTextField) {
        editedField = nil
        guard let dimensions = dimensions(afterEditing: .height) else { onDraftChanged?(); return }
        if maintainAspect { widthField.stringValue = String(dimensions.width) }
        syncPercentFromDims()
        updatePreviewLabel()
        emitSpec()
    }

    @objc private func handlePercentEdit(_ sender: NSTextField) {
        editedField = nil
        guard let dimensions = dimensions(afterEditing: .percent) else { onDraftChanged?(); return }
        widthField.stringValue = String(dimensions.width)
        heightField.stringValue = String(dimensions.height)
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
        updatePreviewLabel()
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
        if let spec = pendingSpec {
            onApply?(spec)
        }
    }

    // MARK: - Helpers

    private func setDimensionsFromSource() {
        editedField = nil
        widthField.stringValue = String(Int(sourcePixelSize.width))
        heightField.stringValue = String(Int(sourcePixelSize.height))
        percentField.stringValue = "100"
    }

    func acceptAppliedSize(_ size: CGSize) {
        sourcePixelSize = size
        setDimensionsFromSource()
        updatePreviewLabel()
    }

    private func syncPercentFromDims() {
        guard sourcePixelSize.width > 0 else { return }
        let w = Double(widthField.integerValue)
        let pct = (w / Double(sourcePixelSize.width)) * 100.0
        percentField.stringValue = String(format: "%.1f", pct)
    }

    /// Preserve the typed request, but offer Apply only for an effective change.
    /// Preview and eligibility share the renderer's authoritative clamping rules.
    var pendingSpec: ResizeSpec? {
        guard let spec = currentSpec() else { return nil }
        guard let output = effectiveSize(for: spec), output != sourcePixelSize else { return nil }
        return spec
    }

    private func effectiveSize(for spec: ResizeSpec) -> CGSize? {
        EditRenderer.outputPixelSize(from: sourcePixelSize, operations: [.resize(spec)])
    }

    /// "New size: 5184 × 3456 px", or "Same size as the current image." (spec 27 P3-8c).
    static func previewText(source: CGSize, width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Same size as the current photo." }
        if width == Int(source.width), height == Int(source.height) { return "Same size as the current photo." }
        return "New size: \(width) × \(height) px"
    }

    @objc private func handleReset(_ sender: NSButton) {
        setDimensionsFromSource()
        updatePreviewLabel()
        emitSpec()
    }

    var _resetButton: NSButton { resetButton }

    private func updatePreviewLabel() {
        defer { onDraftChanged?() }
        applyButton.isEnabled = pendingSpec != nil
        let sw = Int(sourcePixelSize.width)
        let sh = Int(sourcePixelSize.height)
        let output = currentSpec().flatMap { effectiveSize(for: $0) }
        let tw = output.map { Int($0.width) } ?? 0
        let th = output.map { Int($0.height) } ?? 0
        guard sw > 0, sh > 0 else {
            previewLabel.stringValue = "—"
            return
        }
        previewLabel.stringValue = Self.previewText(source: CGSize(width: sw, height: sh), width: tw, height: th)
    }

    private func emitSpec() {
        guard let spec = currentSpec() else { return }
        onSpecChanged?(spec)
    }

    /// Build a `ResizeSpec` from the current field values. Returns nil
    /// when either W or H is missing / non-positive — the live-preview
    /// path treats that as "don't render yet".
    func currentSpec() -> ResizeSpec? {
        spec(afterEditing: nil)
    }

    var projectedSpec: ResizeSpec? { spec(afterEditing: editedField) }

    private func spec(afterEditing field: DraftField?) -> ResizeSpec? {
        guard let dimensions = dimensions(afterEditing: field) else { return nil }
        return ResizeSpec(width: dimensions.width, height: dimensions.height,
                          interpolation: interpolation, preventUpscale: preventUpscale)
    }

    // MARK: - Test seams

    internal var _widthField: NSTextField { widthField }
    internal var _heightField: NSTextField { heightField }
    internal var _percentField: NSTextField { percentField }
    internal var _interpPopup: NSPopUpButton { interpPopup }
    internal var _applyButton: NSButton { applyButton }
    internal var _maintainCheckbox: NSButton { maintainCheckbox }
    internal var _preventUpscaleCheckbox: NSButton { preventUpscaleCheckbox }
    internal var _previewLabel: NSTextField { previewLabel }

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
