//
//  SaveAsAccessory.swift
//  ShrikeUI
//
//  The Save panel accessory (message and quality
//  control), 360 pt wide, 12 pt row gap:
//
//      <message, 11 pt secondaryLabelColor, max 2 lines>
//      Format:   [JPEG ▾]
//      Quality:  [───────●──] [ 92 ]     JPEG / HEIC only (hidden otherwise)
//      ☑ Keep metadata (EXIF, IPTC, XMP)
//      ☐ Remove location (GPS)
//
//  Values changed here are written back to the Editing prefs, so the
//  Settings tab and the panel never disagree.
//

import AppKit
import ShrikeCore
import ShrikeEdit
import UniformTypeIdentifiers

@MainActor
final class SaveAsAccessory: NSView {

    /// Formats the panel offers: JPEG, HEIC, PNG, TIFF, plus WebP / AVIF
    /// when the OS can encode them.
    static var offeredFormats: [ExportFormat] {
        [.jpeg, .heic, .png, .tiff] + [ExportFormat.webp, .avif].filter(\.isEncodable)
    }

    static func title(of format: ExportFormat) -> String {
        switch format {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }

    /// Quality applies to lossy formats only.
    static func showsQuality(_ format: ExportFormat) -> Bool {
        format == .jpeg || format == .heic
    }

    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let qualitySlider = NSSlider(value: 92, minValue: 60, maxValue: 100, target: nil, action: nil)
    let qualityField = NSTextField(string: "92")
    let keepMetadata = NSButton(checkboxWithTitle: "Keep metadata (EXIF, IPTC, XMP)", target: nil, action: nil)
    let removeLocation = NSButton(checkboxWithTitle: "Remove location (GPS)", target: nil, action: nil)
    private var qualityRow: NSView!
    private weak var panel: NSSavePanel?

    private(set) var format: ExportFormat
    var quality: Int { Int(qualitySlider.integerValue) }

    init(message: String?, format: ExportFormat, panel: NSSavePanel?) {
        self.format = Self.offeredFormats.contains(format) ? format : .jpeg
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 10))

        messageLabel.font = ChromeTypography.font(11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        messageLabel.preferredMaxLayoutWidth = 360

        for f in Self.offeredFormats { formatPopUp.addItem(withTitle: Self.title(of: f)) }
        formatPopUp.selectItem(at: Self.offeredFormats.firstIndex(of: self.format) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged(_:))

        qualitySlider.numberOfTickMarks = 0
        qualitySlider.target = self
        qualitySlider.action = #selector(qualitySliderChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qualityField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        qualityField.alignment = .right
        qualityField.target = self
        qualityField.action = #selector(qualityFieldChanged(_:))
        let formatter = NumberFormatter()
        formatter.minimum = 60
        formatter.maximum = 100
        formatter.allowsFloats = false
        qualityField.formatter = formatter

        keepMetadata.state = Prefs.editPreserveEXIFOnSave ? .on : .off
        keepMetadata.target = self
        keepMetadata.action = #selector(togglesChanged(_:))
        removeLocation.state = Prefs.editStripGPSOnSave ? .on : .off
        removeLocation.target = self
        removeLocation.action = #selector(togglesChanged(_:))

        let formatRow = Self.row("Format:", formatPopUp)
        qualityRow = Self.row("Quality:", qualitySlider, qualityField)
        // The checkboxes sit in the controls' column (audit on-screen L8: they touched the panel edge).
        let stack = NSStackView(views: [messageLabel, formatRow, qualityRow,
                                        Self.row("", keepMetadata), Self.row("", removeLocation)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 360),
        ])
        applyFormat()
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func row(_ label: String, _ views: NSView...) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [title] + views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// Test seam and panel wiring: picks `format` as if chosen in the menu.
    func select(_ format: ExportFormat) {
        guard let index = Self.offeredFormats.firstIndex(of: format) else { return }
        formatPopUp.selectItem(at: index)
        formatChanged(formatPopUp)
    }

    private func applyFormat() {
        qualityRow.isHidden = !Self.showsQuality(format)
        let value = format == .heic ? Prefs.editHEICQualityDefault : Prefs.editJPEGQualityDefault
        qualitySlider.integerValue = value
        qualityField.integerValue = value
        guard let panel else { return }
        panel.allowedContentTypes = [format.utType]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = stem + "." + format.fileExtension
    }

    @objc private func formatChanged(_ sender: Any?) {
        let index = formatPopUp.indexOfSelectedItem
        guard Self.offeredFormats.indices.contains(index) else { return }
        format = Self.offeredFormats[index]
        applyFormat()
    }

    @objc private func qualitySliderChanged(_ sender: Any?) {
        qualityField.integerValue = qualitySlider.integerValue
        storeQuality()
    }

    @objc private func qualityFieldChanged(_ sender: Any?) {
        let value = min(100, max(60, qualityField.integerValue))
        qualitySlider.integerValue = value
        qualityField.integerValue = value
        storeQuality()
    }

    private func storeQuality() {
        if format == .heic {
            Prefs.editHEICQualityDefault = qualitySlider.integerValue
        } else if format == .jpeg {
            Prefs.editJPEGQualityDefault = qualitySlider.integerValue
        }
    }

    @objc private func togglesChanged(_ sender: Any?) {
        Prefs.editPreserveEXIFOnSave = keepMetadata.state == .on
        Prefs.editStripGPSOnSave = removeLocation.state == .on
    }
}
