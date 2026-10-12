//
//  RotatePanel.swift
//  ShrikeUI
//
//  Right-side Rotate tool panel. Spec
//  Quick ±90° / 180° buttons plus a ±45° free-rotate slider with auto-crop
//  toggle.
//
//  Live preview model:
//    * Slider is `.isContinuous = true`. Continuous events fire
//      `onAngleChanged` with a `.draft` quality hint — the controller
//      routes that through `EditRenderer.render(recipe:from:qualityHint:)`
//      against a downsampled source for live feedback.
//    * On mouseUp, the panel fires `onAngleCommitted` with `.full`; the
//      controller re-renders at full-res and (when Apply is clicked)
//      appends a `.rotate(degrees:)` op.
//    * A 500 ms idle timer after the last continuous event also flushes
//      to `.full`, like the coalescer.
//

import AppKit
import ShrikeEdit

@MainActor
final class RotatePanel: NSView {

    // MARK: - Public hooks

    /// Fired when the user clicks one of the quick buttons. The panel
    /// dispatches the op immediately; the controller collapses the
    /// parameter panel after processing.
    var onQuickRotate: ((Int) -> Void)?          // quarters
    /// Fired during a free-rotate drag (`.draft` hint).
    var onAngleChanged: ((Double) -> Void)?
    /// Fired on drag-end or after the 500 ms idle (`.full` hint).
    var onAngleCommitted: ((Double) -> Void)?
    /// Fired when the slider reset to 0.
    var onReset: (() -> Void)?
    /// Fired when the user clicks Apply.
    /// Fired when the auto-crop toggle flips.
    var onAutoCropChanged: ((Bool) -> Void)?

    // MARK: - State

    private var idleCommitTask: Task<Void, Never>?
    /// Idle debounce interval for live-preview coalescing. 500 ms
    /// matches the spec. Exposed for tests via the static accessor below.
    static let idleCommitDelay: TimeInterval = 0.500

    /// Current slider angle in degrees, clamped to ±45°
    private(set) var angle: Double = 0

    // MARK: - Subviews

    private let quickCCW = NSButton(title: "↺ 90°", target: nil, action: nil)
    private let quickHalf = NSButton(title: "180°", target: nil, action: nil)
    private let quickCW = NSButton(title: "↻ 90°", target: nil, action: nil)
    private let angleSlider = NSSlider()
    private let angleLabel = NSTextField(labelWithString: "0.0°")
    private let autoCropCheckbox = NSButton(
        checkboxWithTitle: "Auto-crop corners",
        target: nil,
        action: nil
    )
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for btn in [quickCCW, quickHalf, quickCW] {
            btn.bezelStyle = .rounded
            btn.translatesAutoresizingMaskIntoConstraints = false
        }
        quickCCW.target = self; quickCCW.action = #selector(handleCCW(_:))
        quickHalf.target = self; quickHalf.action = #selector(handleHalf(_:))
        quickCW.target = self;   quickCW.action = #selector(handleCW(_:))

        let quickRow = NSStackView(views: [quickCCW, quickHalf, quickCW])
        quickRow.orientation = .horizontal
        quickRow.distribution = .fillEqually
        quickRow.spacing = 6
        quickRow.translatesAutoresizingMaskIntoConstraints = false

        angleSlider.translatesAutoresizingMaskIntoConstraints = false
        angleSlider.minValue = -45
        angleSlider.maxValue = 45
        angleSlider.doubleValue = 0
        angleSlider.isContinuous = true
        angleSlider.target = self
        angleSlider.action = #selector(handleAngleSlider(_:))

        angleLabel.translatesAutoresizingMaskIntoConstraints = false
        angleLabel.alignment = .center
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        autoCropCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCropCheckbox.state = .on
        autoCropCheckbox.target = self
        autoCropCheckbox.action = #selector(handleAutoCropToggle(_:))

        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.target = self
        resetButton.action = #selector(handleReset(_:))

        angleSlider.setAccessibilityLabel("Rotation angle, degrees")

        let stack = NSStackView(views: [
            sectionLabel("Quick"),
            quickRow,
            sectionLabel("Fine"),
            angleSlider,
            angleLabel,
            autoCropCheckbox,
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
            quickRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            angleSlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            angleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    // MARK: - Actions

    @objc private func handleCCW(_ sender: NSButton)  { onQuickRotate?(-1) }
    @objc private func handleHalf(_ sender: NSButton) { onQuickRotate?(2) }
    @objc private func handleCW(_ sender: NSButton)   { onQuickRotate?(1) }

    @objc private func handleAngleSlider(_ sender: NSSlider) {
        angle = max(-45, min(45, sender.doubleValue))
        angleLabel.stringValue = String(format: "%.1f°", angle)
        angleSlider.setAccessibilityValueDescription(String(format: "%.1f degrees", angle))
        onAngleChanged?(angle)

        // 500 ms idle-commit — matches the coalescer rule.
        idleCommitTask?.cancel()
        let latest = angle
        idleCommitTask = Task { [weak self] in
            let ns = UInt64(Self.idleCommitDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                // Only commit if the user hasn't since re-entered the
                // drag (slider has the same angle as when the timer
                // fired; the timer is cancelled on every new event).
                if self.angle == latest {
                    self.onAngleCommitted?(latest)
                }
            }
        }
    }

    @objc private func handleAutoCropToggle(_ sender: NSButton) {
        onAutoCropChanged?(sender.state == .on)
    }

    @objc private func handleReset(_ sender: NSButton) {
        idleCommitTask?.cancel()
        angle = 0
        angleSlider.doubleValue = 0
        angleLabel.stringValue = "0.0°"
        onReset?()
    }


    // MARK: - Public setters

    func setAngle(_ degrees: Double) {
        angle = max(-45, min(45, degrees))
        angleSlider.doubleValue = angle
        angleLabel.stringValue = String(format: "%.1f°", angle)
        angleSlider.setAccessibilityValueDescription(String(format: "%.1f degrees", angle))
    }

    func setAutoCrop(_ enabled: Bool) {
        autoCropCheckbox.state = enabled ? .on : .off
    }

    // MARK: - Test seams

    internal var _angleSlider: NSSlider { angleSlider }
    internal var _quickCW: NSButton { quickCW }
    internal var _quickCCW: NSButton { quickCCW }
    internal var _quickHalf: NSButton { quickHalf }
    internal var _autoCropCheckbox: NSButton { autoCropCheckbox }
}
