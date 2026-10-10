//
//  ComparePaneView.swift
//  ShrikeUI
//
//  One Compare pane: the viewer's `MetalImageView` on the
//  viewer black, a 24 pt footer on overlay material, the 2 pt focus
//  border in `controlAccentColor`, and the centred error line.
//

import AppKit
import ShrikeCore
import ShrikeRendering

@MainActor
final class ComparePaneView: NSView {

    let imageView: MetalImageView
    let footer = HUDSurfaceView()
    let footerLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(labelWithString: "")
    private let focusRing = CompareFocusRingView()

    var isFocused = false {
        didSet {
            focusRing.isHidden = !isFocused
            setAccessibilitySelected(isFocused)
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
        footerLabel.font = .systemFont(ofSize: CompareFooter.fontSize)
        footerLabel.textColor = .labelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.maximumNumberOfLines = 1
        footerLabel.cell?.truncatesLastVisibleLine = true
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            // The outer panes' footers run into the window's rounded
            // bottom corners.
            footerLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: WindowCornerInset.side),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor,
                                                  constant: -WindowCornerInset.side),
            footerLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(footer)

        errorLabel.font = .systemFont(ofSize: 13)
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
    func setFooter(_ text: String) {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: CompareFooter.fontSize),
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

/// The 2 pt inner border of the focused pane. Its colour follows the
/// accent colour and the appearance.
@MainActor
final class CompareFocusRingView: NSView {

    static let width: CGFloat = 2

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
            layer?.borderColor = NSColor.controlAccentColor.resolvedCGColor(for: effectiveAppearance)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
