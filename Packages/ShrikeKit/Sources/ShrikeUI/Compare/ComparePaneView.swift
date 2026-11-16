//
//  ComparePaneView.swift
//  ShrikeUI
//
//  One Compare pane: the viewer's `MetalImageView` on the
//  viewer black, a 24 pt footer on overlay material, the 2 pt focus
//  border in `ShrikeAccent.mark`, and the centred error line.
//

import AppKit
import ShrikeCore
import ShrikeRendering

@MainActor
final class ComparePaneView: NSView {

    /// Only the footer text dims in an unfocused pane; the photo never does.
    static let unfocusedFooterAlpha: CGFloat = 0.6

    let imageView: MetalImageView
    let footer = HUDSurfaceView()
    let footerLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(labelWithString: "")
    var onKeep: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private let keep = NSButton(checkboxWithTitle: "Keep photo", target: nil, action: nil)
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let navigationButtons = NSStackView()
    private var reference = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let focusRing = CompareFocusRingView()
    /// The pane's own zoom, always visible at its bottom-right.
    let zoomPill = CompareZoomPillView()

    var isFocused = false {
        didSet {
            focusRing.isHidden = !isFocused
            footerLabel.alphaValue = isFocused ? 1 : Self.unfocusedFooterAlpha
            setAccessibilitySelected(isFocused)
            refreshActions()
        }
    }

    override init(frame frameRect: NSRect) {
        imageView = MetalImageView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.autoresizingMask = [.width, .height]
        imageView.canvasColor = .black
        addSubview(imageView)

        // A solid strip, flush to the cell bottom, no radius.
        footer.setShowsMaterial(false)
        footer.frame = NSRect(x: 0, y: 0, width: frameRect.width, height: CompareFooter.height)
        footer.autoresizingMask = [.width, .maxYMargin]
        footerLabel.font = ChromeTypography.font(CompareFooter.fontSize)
        footerLabel.textColor = .labelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.maximumNumberOfLines = 1
        footerLabel.cell?.truncatesLastVisibleLine = true
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLabel)
        keep.target = self; keep.action = #selector(keepClicked)
        previous.target = self; previous.action = #selector(previousClicked)
        next.target = self; next.action = #selector(nextClicked)
        previous.setAccessibilityLabel("Previous photo"); next.setAccessibilityLabel("Next photo")
        navigationButtons.orientation = .horizontal; navigationButtons.spacing = 4
        for button in [previous, keep, next] {
            button.font = ChromeTypography.font(12)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: ChromeTypography.targetHeight).isActive = true
            navigationButtons.addArrangedSubview(button)
        }
        footer.addSubview(navigationButtons); navigationButtons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([navigationButtons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
            navigationButtons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        footer.frame.size.height = ChromeTypography.targetHeight + 8
        refreshActions()
        NSLayoutConstraint.activate([
            // The outer panes' footers run into the window's rounded
            // bottom corners.
            footerLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: WindowCornerInset.side),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: navigationButtons.leadingAnchor, constant: -8),
            footerLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(footer)

        errorLabel.font = ChromeTypography.font(13)
        errorLabel.textColor = .white
        errorLabel.alignment = .center
        errorLabel.lineBreakMode = .byTruncatingMiddle
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])

        zoomPill.isHidden = true   // no photo, no percentage
        zoomPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomPill)
        NSLayoutConstraint.activate([
            zoomPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CompareZoomPill.inset),
            zoomPill.bottomAnchor.constraint(equalTo: bottomAnchor,
                                             constant: -(footer.frame.height + CompareZoomPill.inset)),
        ])

        focusRing.frame = bounds
        focusRing.autoresizingMask = [.width, .height]
        focusRing.isHidden = true
        addSubview(focusRing)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Footer text with the stars and flag in their badge colours.
    func setFooter(_ text: String, name: String? = nil) {
        footerFullText = text
        footerName = name
        footer.toolTip = name
        refitFooter()
    }

    private var footerFullText = ""
    private var footerName: String?

    override func layout() {
        super.layout()
        refitFooter()
        refreshZoomPill()   // a resize at Fit changes the percentage without a zoom callback
    }

    /// Shows the photo's pixel percent (`pixelScale`: 100 % = one source
    /// pixel per screen pixel, never the texture zoom); hidden with no photo.
    func refreshZoomPill() {
        let scale = CompareZoomPill.shownScale(hasImage: imageView.image != nil, pixelScale: imageView.pixelScale)
        zoomPill.isHidden = scale == nil
        if let scale { zoomPill.setPixelScale(scale) }
    }

    /// The name is cut with `FileNameFit` so the rest of the footer stays whole.
    private func refitFooter() {
        var text = footerFullText
        let available = footer.bounds.width - 2 * WindowCornerInset.side - navigationButtons.fittingSize.width - 8
        if let name = footerName, !name.isEmpty, text.hasPrefix(name), available > 0 {
            let suffix = String(text.dropFirst(name.count))
            let font = ChromeTypography.font(CompareFooter.fontSize)
            let fitted = FileNameFit.fit(name) {
                (($0 + suffix) as NSString).size(withAttributes: [.font: font]).width <= available
            }
            text = fitted + suffix
        }
        if text == renderedFooterText, !text.isEmpty { return }
        renderedFooterText = text
        applyFooterText(text)
    }

    private var renderedFooterText = ""

    private func applyFooterText(_ text: String) {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: ChromeTypography.font(CompareFooter.fontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: "★", options: [], range: search)
            guard r.location != NSNotFound else { break }
            attributed.addAttribute(.foregroundColor, value: Badges.ratingColor, range: r)
            search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        let flag = ns.range(of: "⚑")
        if flag.location != NSNotFound {
            attributed.addAttribute(.foregroundColor, value: Badges.flagColor, range: flag)
        }
        footerLabel.attributedStringValue = attributed
        setAccessibilityLabel(text)
    }

    func setReference(_ reference: Bool, canPrevious: Bool, canNext: Bool) {
        self.reference = reference; keep.state = reference ? .on : .off
        keep.toolTip = "Keep this photo here. The arrow keys change only the other panes."
        keep.setAccessibilityLabel("Keep photo")
        previous.isEnabled = !reference && canPrevious; next.isEnabled = !reference && canNext
        previous.toolTip = reference ? "Uncheck Keep photo to change this photo" : "Previous photo"
        next.toolTip = reference ? "Uncheck Keep photo to change this photo" : "Next photo"
        refreshActions()
    }
    private func refreshActions() { navigationButtons.isHidden = !(reference || hovered || isFocused) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshActions() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshActions() }
    @objc private func keepClicked() { onKeep?() }
    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }

    var footerAlphaForTesting: CGFloat { footerLabel.alphaValue }
    #if DEBUG
    var paneControlsForTesting: [NSButton] { [previous, keep, next] }
    #endif

    func showError(_ text: String?) {
        errorLabel.stringValue = text ?? ""
        errorLabel.isHidden = text == nil
        refreshZoomPill()
    }

    /// The footer and the border never take clicks: they go to the image.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === focusRing || hit === errorLabel { return imageView }
        return hit
    }
}

/// The 3 pt inner border of the focused pane. Its colour follows the
/// accent colour and the appearance.
@MainActor
final class CompareFocusRingView: NSView {

    static let width: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = Self.width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = Self.width
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = ShrikeAccent.mark.resolvedCGColor(for: effectiveAppearance)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Compare pane's zoom pill. Pure parts.
enum CompareZoomPill {
    static let inset: CGFloat = 8
    static let fontSize: CGFloat = 11

    static func percent(pixelScale: Double) -> Int { Int((pixelScale * 100).rounded()) }

    /// `24 %` (the app writes a space before %).
    static func text(pixelScale: Double) -> String { "\(percent(pixelScale: pixelScale)) %" }

    /// `Zoom 24 percent`, as the photo view says it.
    static func spoken(pixelScale: Double) -> String {
        PhotoViewAccessibility.value(pixelScale: pixelScale, isPreview: false)
    }

    /// The scale to show, or nil (hidden) when the pane has no photo.
    static func shownScale(hasImage: Bool, pixelScale: Double) -> Double? {
        hasImage && pixelScale.isFinite && pixelScale > 0 ? pixelScale : nil
    }
}

/// The pill: the viewer zoom HUD's look (`HUDSurfaceView`, capsule; opaque
/// under Reduce transparency through the surface itself), 11 pt digits.
@MainActor
final class CompareZoomPillView: HUDSurfaceView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)   // the pill speaks for it
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPixelScale(_ scale: Double) {
        label.font = NSFont.monospacedDigitSystemFont(ofSize: ChromeTypography.size(CompareZoomPill.fontSize), weight: .regular)
        let text = CompareZoomPill.text(pixelScale: scale)
        if label.stringValue != text { label.stringValue = text }
        setAccessibilityLabel(CompareZoomPill.spoken(pixelScale: scale))
    }

    var text: String { label.stringValue }
    #if DEBUG
    var fontForTesting: NSFont? { label.font }
    #endif

    // Clicks go to the photo underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
