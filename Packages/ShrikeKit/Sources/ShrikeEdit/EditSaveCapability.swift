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
            conversionDisclosure: "The original's precision could not be verified. Save a copy to keep the original unchanged.") }
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
        let copy = hdr || (bits > 8 && (losesPrecision || losesContainerPrecision))
        let disclosure: String? = copy
            ? (hdr ? "This edit export may convert HDR to an 8-bit image. Save a copy to keep the HDR original."
                   : "These adjustments may convert the \(bits)-bit original to 8-bit pixels. Save a copy to keep the original precision.")
            : nil
        return EditSaveCapability(requiresCopy: copy, sourceBitsPerComponent: bits, isHDR: hdr,
                                  conversionDisclosure: disclosure)
    }
}
