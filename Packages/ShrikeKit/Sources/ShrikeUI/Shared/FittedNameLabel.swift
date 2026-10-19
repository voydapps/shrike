//
//  FittedNameLabel.swift
//  ShrikeUI
//
//  A one-line file name label that cuts the name with `FileNameFit`
//  (spec 25 §6.2) instead of the system's middle truncation: the frame
//  number and the extension stay. It asks for the width of the full name
//  and takes whatever the layout gives it.
//

import AppKit

@MainActor
final class FittedNameLabel: NSTextField {

    /// Horizontal slack a label cell keeps around its text.
    private static let padding: CGFloat = 4

    var fullName: String = "" {
        didSet {
            guard fullName != oldValue else { return }
            invalidateIntrinsicContentSize()
            refit()
        }
    }

    override var font: NSFont? {
        didSet { invalidateIntrinsicContentSize(); refit() }
    }

    convenience init() {
        self.init(labelWithString: "")
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(width(of: fullName)) + Self.padding, height: base.height)
    }

    override func layout() {
        super.layout()
        refit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { refit() }
    }

    private func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font ?? ChromeTypography.font(12)]).width
    }

    /// The text as it fits now (tests read this through `stringValue`).
    func refit() {
        let available = bounds.width - Self.padding
        let text: String
        if bounds.width <= 0 {
            text = fullName
        } else {
            text = FileNameFit.fit(fullName) { [self] in width(of: $0) <= available }
        }
        if stringValue != text { stringValue = text }
    }
}
