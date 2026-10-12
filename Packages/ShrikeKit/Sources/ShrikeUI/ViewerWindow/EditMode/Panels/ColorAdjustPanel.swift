//
//  ColorAdjustPanel.swift
//  ShrikeUI
//
//  Right-side Color Adjust tool panel. Spec
//  Three sliders (Brightness / Contrast / Saturation) covering
//  -1.0 … +1.0 with 0 = identity. Continuous events drive the live-preview
//  path (draft quality); drag-end / 16 ms idle flushes to full.
//
//  Live preview model:
//    * Each slider is `.isContinuous = true`. Continuous events fire
//      `onParamsChanged` with the current `ColorAdjustParams`; the
//      controller treats these as `.draft` quality and collapses to one
//      render per 16 ms via the latest-wins generation counter.
//    * A 16 ms idle timer after the last continuous event flushes
//      `onParamsCommitted` with `.full`. Clicking Apply also flushes.
//    * Double-clicking a slider's numeric label resets just that slider
//      to 0; "Reset all" resets all three but does NOT remove the op from
//      the recipe — the user may still want it for future Apply clicks.
//

import AppKit
import ShrikeEdit

@MainActor
final class ColorAdjustPanel: NSView {

    // MARK: - Public hooks

    /// Fired on every continuous slider tick with the current params.
    /// Controller routes through `EditRenderer.render(recipe:from:qualityHint: .draft)`.
    var onParamsChanged: ((ColorAdjustParams) -> Void)?

    /// Fired on drag-end / 16 ms idle / Apply click, with the committed
    /// params. Controller renders at `.full` quality and appends-or-
    /// replaces the `.colorAdjust` op on the recipe.
    var onParamsCommitted: ((ColorAdjustParams) -> Void)?

    /// Fired when a slider drag ends (mouse up) or a discrete change
    /// lands (a label double-click): the change is one undo step.
    var onEditEnded: ((ColorAdjustParams) -> Void)?

    /// Fired when "Reset all" is clicked. Controller resets all three
    /// sliders to 0 but leaves the op in place (a subsequent continuous
    /// tick or Apply will update it to identity).
    var onResetAll: (() -> Void)?

    /// Fired when Apply is clicked. Controller finalises the op and
    /// collapses the panel.

    // MARK: - State

    private(set) var params = ColorAdjustParams.identity

    private var idleCommitTask: Task<Void, Never>?
    /// 16 ms ≈ 1 vsync. Matches the coalescer target.
    static let idleCommitDelay: TimeInterval = 0.016

    // MARK: - Subviews

    private let brightnessSlider = NSSlider()
    private let contrastSlider   = NSSlider()
    private let saturationSlider = NSSlider()
    /// Hue, −180°…+180°, after Saturation.
    private let hueSlider = NSSlider()

    private let brightnessValueLabel = NSTextField(labelWithString: "0.00")
    private let contrastValueLabel   = NSTextField(labelWithString: "0.00")
    private let saturationValueLabel = NSTextField(labelWithString: "0.00")
    private let hueValueLabel = NSTextField(labelWithString: "0°")

    /// Test seam: Brightness, Contrast, Saturation, Hue.
    var slidersForTesting: [NSSlider] { [brightnessSlider, contrastSlider, saturationSlider, hueSlider] }

    private let resetAllButton = NSButton(title: "Reset all", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for slider in [brightnessSlider, contrastSlider, saturationSlider, hueSlider] {
            // "±" sliders: the fill runs from 0 (the centre) to the knob.
            // Set before the range: a new cell
            // starts from its own defaults.
            slider.cell = CentredFillSliderCell()
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.minValue = -1.0
            slider.maxValue = 1.0
            slider.doubleValue = 0
            slider.isContinuous = true
            slider.target = self
        }
        hueSlider.minValue = ColorAdjustTool.hueRange.lowerBound
        hueSlider.maxValue = ColorAdjustTool.hueRange.upperBound
        brightnessSlider.action = #selector(handleBrightnessSlider(_:))
        contrastSlider.action   = #selector(handleContrastSlider(_:))
        saturationSlider.action = #selector(handleSaturationSlider(_:))
        hueSlider.action        = #selector(handleHueSlider(_:))
        hueSlider.setAccessibilityLabel("Hue")
        brightnessSlider.setAccessibilityLabel("Brightness")
        contrastSlider.setAccessibilityLabel("Contrast")
        saturationSlider.setAccessibilityLabel("Saturation")

        for label in [brightnessValueLabel, contrastValueLabel, saturationValueLabel, hueValueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }

        // Double-click-to-reset on each value label.
        attachDoubleClickReset(to: brightnessValueLabel,
                               selector: #selector(resetBrightness))
        attachDoubleClickReset(to: contrastValueLabel,
                               selector: #selector(resetContrast))
        attachDoubleClickReset(to: saturationValueLabel,
                               selector: #selector(resetSaturation))
        attachDoubleClickReset(to: hueValueLabel,
                               selector: #selector(resetHue))

        resetAllButton.translatesAutoresizingMaskIntoConstraints = false
        resetAllButton.bezelStyle = .rounded
        resetAllButton.target = self
        resetAllButton.action = #selector(handleResetAll(_:))

        let brightnessGroup = makeGroup(
            title: "Brightness", slider: brightnessSlider, label: brightnessValueLabel
        )
        let contrastGroup = makeGroup(
            title: "Contrast", slider: contrastSlider, label: contrastValueLabel
        )
        let saturationGroup = makeGroup(
            title: "Saturation", slider: saturationSlider, label: saturationValueLabel
        )
        let hueGroup = makeGroup(
            title: "Hue", slider: hueSlider, label: hueValueLabel
        )

        let stack = NSStackView(views: [
            brightnessGroup,
            contrastGroup,
            saturationGroup,
            hueGroup,
            resetAllButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            brightnessGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contrastGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saturationGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hueGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetAllButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeGroup(title: String,
                           slider: NSSlider,
                           label: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let group = NSStackView(views: [titleLabel, slider, label])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        group.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalTo: group.widthAnchor),
            label.widthAnchor.constraint(equalTo: group.widthAnchor),
        ])
        return group
    }

    private func attachDoubleClickReset(to label: NSTextField,
                                        selector: Selector) {
        let click = NSClickGestureRecognizer(target: self, action: selector)
        click.numberOfClicksRequired = 2
        label.addGestureRecognizer(click)
    }

    // MARK: - Actions

    @objc private func handleBrightnessSlider(_ sender: NSSlider) {
        params.brightness = clamp(sender.doubleValue)
        refreshLabel(brightnessValueLabel, value: params.brightness)
        fireDraftAndScheduleCommit()
    }

    @objc private func handleContrastSlider(_ sender: NSSlider) {
        params.contrast = clamp(sender.doubleValue)
        refreshLabel(contrastValueLabel, value: params.contrast)
        fireDraftAndScheduleCommit()
    }

    @objc private func handleSaturationSlider(_ sender: NSSlider) {
        params.saturation = clamp(sender.doubleValue)
        refreshLabel(saturationValueLabel, value: params.saturation)
        fireDraftAndScheduleCommit()
    }

    @objc private func handleHueSlider(_ sender: NSSlider) {
        let range = ColorAdjustTool.hueRange
        let v = min(max(sender.doubleValue, range.lowerBound), range.upperBound)
        params.hue = v == 0 ? nil : v
        refreshHueLabel(v)
        fireDraftAndScheduleCommit()
    }

    @objc private func resetHue() {
        params.hue = nil
        hueSlider.doubleValue = 0
        refreshHueLabel(0)
        fireDiscreteChange()
    }

    private func refreshHueLabel(_ degrees: Double) {
        hueValueLabel.stringValue = degrees == 0 ? "0°" : String(format: "%+.0f°", degrees)
    }

    @objc private func resetBrightness() {
        params.brightness = 0
        brightnessSlider.doubleValue = 0
        refreshLabel(brightnessValueLabel, value: 0)
        fireDiscreteChange()
    }

    @objc private func resetContrast() {
        params.contrast = 0
        contrastSlider.doubleValue = 0
        refreshLabel(contrastValueLabel, value: 0)
        fireDiscreteChange()
    }

    @objc private func resetSaturation() {
        params.saturation = 0
        saturationSlider.doubleValue = 0
        refreshLabel(saturationValueLabel, value: 0)
        fireDiscreteChange()
    }

    @objc private func handleResetAll(_ sender: NSButton) {
        idleCommitTask?.cancel()
        params = .identity
        brightnessSlider.doubleValue = 0
        contrastSlider.doubleValue = 0
        saturationSlider.doubleValue = 0
        hueSlider.doubleValue = 0
        refreshLabel(brightnessValueLabel, value: 0)
        refreshLabel(contrastValueLabel, value: 0)
        refreshLabel(saturationValueLabel, value: 0)
        refreshHueLabel(0)
        onResetAll?()
        // One undo step back to identity (whole-state colour ops: ⌘Z
        // brings the old values back).
        onParamsCommitted?(params)
        onEditEnded?(params)
    }


    /// A change that is not a drag (label double-click): one undo step.
    private func fireDiscreteChange() {
        idleCommitTask?.cancel()
        onParamsChanged?(params)
        onEditEnded?(params)
    }

    // MARK: - Helpers

    private func clamp(_ v: Double) -> Double {
        max(-1.0, min(1.0, v))
    }

    private func refreshLabel(_ label: NSTextField, value: Double) {
        label.stringValue = String(format: "%+.2f", value)
    }

    /// Fire `onParamsChanged` for draft preview, then arm the 16 ms idle
    /// timer that will flush `onParamsCommitted` if no new slider event
    /// arrives. Every call cancels the prior task (standard debounce).
    private func fireDraftAndScheduleCommit() {
        // Mouse up ends the drag at once; the 500 ms idle
        // in the controller covers keyboard and accessibility changes.
        if NSApp?.currentEvent?.type == .leftMouseUp {
            idleCommitTask?.cancel()
            onParamsChanged?(params)
            onEditEnded?(params)
            return
        }
        onParamsChanged?(params)

        idleCommitTask?.cancel()
        let latest = params
        idleCommitTask = Task { [weak self] in
            let ns = UInt64(Self.idleCommitDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                if self.params == latest {
                    self.onParamsCommitted?(latest)
                }
            }
        }
    }

    // MARK: - Public setters

    /// Drive the panel from external state (e.g. re-entering a tool with
    /// an existing `.colorAdjust` op on the recipe).
    func setParams(_ p: ColorAdjustParams) {
        params = p
        brightnessSlider.doubleValue = p.brightness
        contrastSlider.doubleValue   = p.contrast
        saturationSlider.doubleValue = p.saturation
        hueSlider.doubleValue        = p.hue ?? 0
        refreshLabel(brightnessValueLabel, value: p.brightness)
        refreshLabel(contrastValueLabel,   value: p.contrast)
        refreshLabel(saturationValueLabel, value: p.saturation)
        refreshHueLabel(p.hue ?? 0)
    }

    // MARK: - Test seams

    internal var _brightnessSlider: NSSlider { brightnessSlider }
    internal var _contrastSlider:   NSSlider { contrastSlider }
    internal var _saturationSlider: NSSlider { saturationSlider }
    internal var _hueSlider:        NSSlider { hueSlider }
    internal var _hueValueLabel:    NSTextField { hueValueLabel }
    internal var _resetAllButton:   NSButton { resetAllButton }
    internal var _brightnessValueLabel: NSTextField { brightnessValueLabel }
    internal var _contrastValueLabel:   NSTextField { contrastValueLabel }
    internal var _saturationValueLabel: NSTextField { saturationValueLabel }
}

// MARK: - Centred fill

/// A slider whose value runs from − to +, with 0 in the middle. The
/// accent fill runs from the 0 point to the knob, never from the left
/// end, so "no change" reads as an empty track.
final class CentredFillSliderCell: NSSliderCell {

    /// The value the fill starts from.
    var origin: Double = 0

    /// The fill's x span on a track whose knob centre travels over
    /// `travel`, for `value` in `minValue...maxValue`.
    static func fillSpan(value: Double, origin: Double, minValue: Double, maxValue: Double,
                         travel: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        let range = maxValue - minValue
        guard range > 0 else { return travel.lowerBound...travel.lowerBound }
        func x(_ v: Double) -> CGFloat {
            let t = CGFloat((min(max(v, minValue), maxValue) - minValue) / range)
            return travel.lowerBound + t * (travel.upperBound - travel.lowerBound)
        }
        let a = x(origin), b = x(value)
        return min(a, b)...max(a, b)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let thickness: CGFloat = controlSize == .regular ? 4 : 3
        let bar = NSRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bar, xRadius: thickness / 2, yRadius: thickness / 2).fill()

        let knob = knobRect(flipped: flipped)
        let half = knob.width / 2
        let travel = (rect.minX + half)...max(rect.minX + half, rect.maxX - half)
        let span = Self.fillSpan(value: doubleValue, origin: origin, minValue: minValue,
                                 maxValue: maxValue, travel: travel)
        guard span.upperBound - span.lowerBound > 0.5 else { return }
        let fill = NSRect(x: span.lowerBound, y: bar.minY,
                          width: span.upperBound - span.lowerBound, height: thickness)
        (isEnabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}
