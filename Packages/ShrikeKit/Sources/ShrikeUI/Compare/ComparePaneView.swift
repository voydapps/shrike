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

    /// Only the footer text dims in an unfocused pane; the photo never does (spec 27 C1).
    static let unfocusedFooterAlpha: CGFloat = 0.6

    let imageView: MetalImageView
    let footer = HUDSurfaceView()
    let footerLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(labelWithString: "")
    var onKeep: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private let keep = NSButton(checkboxWithTitle: "Keep Photo", target: nil, action: nil)
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let navigationButtons = NSStackView()
    private var reference = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let focusRing = CompareFocusRingView()

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
        previous.setAccessibilityLabel("Previous candidate"); next.setAccessibilityLabel("Next candidate")
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
        keep.toolTip = "Keep this photo while changing candidates"
        keep.setAccessibilityLabel(reference ? "Keep Photo, Reference" : "Keep Photo")
        previous.isEnabled = !reference && canPrevious; next.isEnabled = !reference && canNext
        previous.toolTip = reference ? "Unpin to change this photo" : "Previous candidate"
        next.toolTip = reference ? "Unpin to change this photo" : "Next candidate"
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

    func showError(_ text: String?) {
        errorLabel.stringValue = text ?? ""
        errorLabel.isHidden = text == nil
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
