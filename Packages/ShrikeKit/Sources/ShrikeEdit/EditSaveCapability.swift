import CoreGraphics
import Foundation
import ImageIO

/// Header-only save safety. Container choice alone does not preserve
/// precision: several current tools produce 8-bit intermediate pixels.
public struct EditSaveCapability: Sendable {
    public let requiresCopy: Bool
    public let sourceBitsPerComponent: Int
    public let isHDR: Bool
    public let conversionDisclosure: String?
}

extension ImageExporter {
    public nonisolated static func capability(for url: URL, operations: [EditOperation],
                                               format: ExportFormat? = nil) -> EditSaveCapability {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return EditSaveCapability(requiresCopy: true, sourceBitsPerComponent: 0, isHDR: false,
            conversionDisclosure: "The original's precision could not be verified. Use Save Copy… to keep the original unchanged.") }
        let bits = properties[kCGImagePropertyDepth] as? Int ?? 8
        let profile = (properties[kCGImagePropertyProfileName] as? String ?? "").lowercased()
        let hdr = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            || profile.contains("2100") || profile.contains("hlg") || profile.contains("pq")
        let losesPrecision = operations.contains { operation in
            switch operation {
            case .crop: return false
            case .rotate(let degrees), .rotateAutoCrop(let degrees): return degrees.truncatingRemainder(dividingBy: 360) != 0
            case .rotate90(let quarters): return quarters % 4 != 0
            case .resize: return true
            case .colorAdjust(let value): return !value.isIdentity
            case .levels(let value): return !value.isIdentity
            }
        }
        let outputFormat = format ?? ExportFormat.inPlaceFormat(for: url)
        let losesContainerPrecision = bits > 8 && outputFormat != .png && outputFormat != .tiff
        let precisionCopy = hdr || (bits > 8 && (losesPrecision || losesContainerPrecision))
        let precisionText: String? = precisionCopy
            ? (hdr ? "This edit export may convert HDR to an 8-bit photo. Use Save Copy… to keep the HDR original."
                   : "These adjustments may convert the \(bits)-bit original to 8-bit pixels. Use Save Copy… to keep the original precision.")
            : nil
        // CMYK / grayscale photos are turned into RGB when an edit needs
        // pixels (COR-1 / COR-2). That changes the file, so say so and
        // keep the original: the save goes to a copy.
        let colorText = colorConversionDisclosure(model: properties[kCGImagePropertyColorModel] as? String,
                                                  operations: operations)
        let text = [precisionText, colorText].compactMap { $0 }.joined(separator: " ")
        return EditSaveCapability(requiresCopy: precisionCopy || colorText != nil, sourceBitsPerComponent: bits,
                                  isHDR: hdr, conversionDisclosure: text.isEmpty ? nil : text)
    }
}

/// The sentence for an edit that turns a CMYK or grayscale photo into RGB,
/// or nil when no colour conversion happens.
private func colorConversionDisclosure(model: String?, operations: [EditOperation]) -> String? {
    guard let model, model != (kCGImagePropertyColorModelRGB as String) else { return nil }
    let changes = operations.filter { operation in
        switch operation {
        case .crop: return false
        case .rotate(let degrees), .rotateAutoCrop(let degrees): return degrees.truncatingRemainder(dividingBy: 360) != 0
        case .rotate90(let quarters): return quarters % 4 != 0
        case .resize: return true
        case .colorAdjust(let value): return !value.isIdentity
        case .levels(let value): return !value.isIdentity
        }
    }
    guard !changes.isEmpty else { return nil }
    if model == (kCGImagePropertyColorModelGray as String) {
        // Resize and rotate keep gray; only the colour tools need RGB.
        let needsColour = changes.contains {
            if case .colorAdjust = $0 { return true }
            if case .levels = $0 { return true }
            return false
        }
        return needsColour ? "These edits will convert this grayscale photo to RGB colour. Use Save Copy… to keep the original." : nil
    }
    let name = model == (kCGImagePropertyColorModelCMYK as String) ? "CMYK" : "its colour model"
    return "These edits will convert this photo from \(name) to RGB. Use Save Copy… to keep the original."
}
