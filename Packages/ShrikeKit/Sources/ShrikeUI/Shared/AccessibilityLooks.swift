//
//  AccessibilityLooks.swift
//  ShrikeUI
//
//  "Reduce transparency" and "Differentiate without
//  color". Every decision is a pure function of the setting; the views read
//  `ReduceTransparency.isOn` and ask these functions what to draw.
//

import AppKit

/// The one place Shrike asks whether Reduce Transparency is on. Read each
/// time (the user can switch it while Shrike runs); tests set
/// `overrideForTesting`.
@MainActor
enum ReduceTransparency {

    /// Tests: forces the setting on or off; nil reads the system.
    static var overrideForTesting: Bool?

    static var isOn: Bool {
        overrideForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    // MARK: Decisions (pure)

    /// A HUD surface draws the opaque fill when its owner asked for it or
    /// the setting is on.
    static func hudUsesOpaqueFill(callerOpaque: Bool, reduce: Bool) -> Bool {
        callerOpaque || reduce
    }

    /// With the setting on a HUD gets the 1 pt `separatorColor` border (the
    /// same border Increase Contrast already draws in a window).
    static func hudUsesSeparatorBorder(increaseContrast: Bool, reduce: Bool) -> Bool {
        increaseContrast || reduce
    }

    /// The preview badge keeps its orange; only its see-through goes.
    static func previewBadgeAlpha(reduce: Bool) -> CGFloat { reduce ? 1 : 0.85 }

    /// The revealed title bar / toolbar band: solid under the setting.
    static func titlebarScrimAlpha(reduce: Bool) -> CGFloat { reduce ? 1 : 0.85 }

    /// The dim outside the crop frame stays translucent (the user must see
    /// what is cut off) and gets darker.
    static func cropDimAlpha(reduce: Bool) -> CGFloat { reduce ? 0.7 : 0.5 }

    /// Crop frame lines. Normal: one 1 pt white line. Under the setting: a
    /// 2 pt white line with a 1 pt black line outside it.
    struct CropFrameLines: Equatable {
        var whiteWidth: CGFloat
        var blackOutsideWidth: CGFloat?
    }

    static func cropFrameLines(reduce: Bool) -> CropFrameLines {
        reduce ? CropFrameLines(whiteWidth: 2, blackOutsideWidth: 1)
               : CropFrameLines(whiteWidth: 1, blackOutsideWidth: nil)
    }
}

/// How an error shows in Rename and Go to Folder, always
/// (not only under a setting): icon + red words + a 1.5 pt red border.
enum ErrorLook {
    static let iconPointSize: CGFloat = 12
    static let fieldBorderWidth: CGFloat = 1.5
    static let iconSymbolName = "exclamationmark.triangle.fill"

    /// VoiceOver hears a message when it appears or changes, not on every
    /// keystroke that leaves it as it was.
    static func shouldAnnounce(old: String?, new: String?) -> Bool {
        guard let new, !new.isEmpty else { return false }
        return new != old
    }
}

/// The error line under a field: the warning icon, then the message in red.
@MainActor
final class ErrorMessageView: NSStackView {

    private let icon = NSImageView()
    let label: NSTextField

    /// `nil` hides the line. Setting a message shows it.
    private(set) var message: String?
    /// The field's help text while there is no error.
    var normalHelp: String?

    init(font: NSFont = ChromeTypography.font(11)) {
        label = NSTextField(wrappingLabelWithString: "")
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 4
        icon.image = NSImage(systemSymbolName: ErrorLook.iconSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ErrorLook.iconPointSize, weight: .regular))
        icon.contentTintColor = .systemRed
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        label.font = font
        label.textColor = .systemRed
        label.isSelectable = false
        addArrangedSubview(icon)
        addArrangedSubview(label)
        isHidden = true
        label.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows or hides the line. `field` gets the red border and the
    /// message as its help text; the message is announced when it is new.
    func set(_ text: String?, for field: NSTextField, reannounce: Bool = false) {
        let text = (text?.isEmpty ?? true) ? nil : text
        let old = message
        message = text
        if let text { label.stringValue = text }
        label.isHidden = text == nil
        isHidden = text == nil
        field.setErrorBorder(text != nil)
        field.setAccessibilityHelp(text ?? normalHelp)
        if let text {
            if reannounce || ErrorLook.shouldAnnounce(old: old, new: text) {
                NSAccessibility.post(element: field, notification: .announcementRequested,
                                     userInfo: [.announcement: text,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }
}

extension NSTextField {
    /// The 1.5 pt `systemRed` border of a field with an error.
    func setErrorBorder(_ on: Bool) {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = on ? 5 : 0
        layer.borderWidth = on ? ErrorLook.fieldBorderWidth : 0
        layer.borderColor = on ? NSColor.systemRed.cgColor : nil
    }

    /// True while the red error border is on (tests).
    var hasErrorBorder: Bool {
        layer?.borderWidth == ErrorLook.fieldBorderWidth
    }
}
