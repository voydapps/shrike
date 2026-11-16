//
//  EditQuietLink.swift
//  ShrikeUI
//
//  `Reset Crop` / `Reset Resize` as a quiet text link under Apply:
//  no border, 12 pt, secondary label colour, centred, underline on hover.
//  The title stays a plain string with `font`, so Larger Text scales it like the
//  panel's other text (ChromeTypography reads and writes `font` only).
//

import AppKit

@MainActor
final class EditQuietLinkButton: NSButton {
    /// Called after the panel's `initializeNativeFont`: the link's own 12 pt base.
    func styleAsQuietLink() {
        isBordered = false
        bezelStyle = .inline
        font = ChromeTypography.font(12)
        contentTintColor = .secondaryLabelColor
        alignment = .center
    }

    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            if isHovered, let font {
                let plain = title
                attributedTitle = NSAttributedString(string: plain, attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .paragraphStyle: Self.centred,
                ])
            } else {
                let plain = title
                title = plain   // back to the plain title: font + tint again
            }
        }
    }
    private static let centred: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.alignment = .center; return p
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    /// Test seam: the hover look without a pointer.
    func setHoveredForTesting(_ hovered: Bool) { isHovered = hovered }
}
