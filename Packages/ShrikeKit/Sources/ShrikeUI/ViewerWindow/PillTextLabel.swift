//
//  PillTextLabel.swift
//  ShrikeUI
//
//  The position pill's text label (spec 25 §6.2). It asks for the width of
//  the whole text and takes what the layout gives it; `refit` then cuts the
//  file name to that width with `FileNameFit`, so the frame number and the
//  extension stay.
//

import AppKit

@MainActor
final class PillTextLabel: NSTextField {

    /// Horizontal slack between the label's width and its text: none, the
    /// pill is exactly as wide as its text.
    static let padding: CGFloat = 0

    /// True once the label has been laid out (before that its width means nothing).
    private(set) var hasLayout = false

    /// The full, uncut text: sets the width the label asks for.
    var fullText: NSAttributedString? {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// Called when the label's width changed or it was laid out.
    var refit: (() -> Void)?

    convenience init() {
        self.init(labelWithString: "")
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        guard let fullText else { return base }
        return NSSize(width: ceil(fullText.size().width) + Self.padding, height: base.height)
    }

    override func layout() {
        super.layout()
        hasLayout = true
        refit?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed, hasLayout { refit?() }
    }
}
