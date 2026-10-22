//
//  ExactProgressBar.swift
//  ShrikeUI
//
//  A progress bar that shows its value at once. The system bar glides to a
//  new value over about a second, so beside a counter ("Copying 659 of 900")
//  it trailed it (the bar showed 59 % at 73 %). A busy bar with no value
//  (`fraction == nil`) still uses the system one.
//

import AppKit

@MainActor
final class ExactProgressBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let busy = NSProgressIndicator()

    /// 0...1, or nil while busy with no number.
    private(set) var fraction: Double?
    private var label = ""

    /// True on a surface that stays dark in the light appearance too (the
    /// transfer toast): the track is then light, not `labelColor`.
    var onDarkSurface = false {
        didSet { if onDarkSurface != oldValue { updateColors() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.cornerRadius = 3
        fill.cornerRadius = 3
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        busy.style = .bar
        busy.controlSize = .small
        busy.isIndeterminate = true
        busy.translatesAutoresizingMaskIntoConstraints = false
        busy.isHidden = true
        addSubview(busy)
        NSLayoutConstraint.activate([
            busy.leadingAnchor.constraint(equalTo: leadingAnchor),
            busy.trailingAnchor.constraint(equalTo: trailingAnchor),
            busy.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    /// Shows `fraction` (0...1) at once; nil = busy, no number.
    func set(fraction: Double?, label: String) {
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.label = label
        setAccessibilityLabel(label)
        if let value = self.fraction {
            busy.stopAnimation(nil)
            busy.isHidden = true
            setAccessibilityValue(NSNumber(value: value))
        } else {
            busy.isHidden = false
            busy.startAnimation(nil)
            setAccessibilityValue(nil)
        }
        track.isHidden = self.fraction == nil
        fill.isHidden = self.fraction == nil
        needsLayout = true
        layoutBars()
    }

    func stopBusy() { busy.stopAnimation(nil) }

    override func layout() {
        super.layout()
        layoutBars()
    }

    /// The width of the filled part, in points (tests).
    var filledWidthForTesting: CGFloat { fill.frame.width }

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h: CGFloat = 6
        let y = (bounds.height - h) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        fill.frame = CGRect(x: 0, y: y, width: bounds.width * CGFloat(fraction ?? 0), height: h)
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (onDarkSurface ? NSColor.white : NSColor.labelColor)
                .withAlphaComponent(onDarkSurface ? 0.25 : 0.15).cgColor
            fill.backgroundColor = ShrikeAccent.fill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}
