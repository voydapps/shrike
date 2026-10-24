//
//  ExportMetadata.swift
//  ShrikeEdit
//
//  What survives a save (audit FS-4) and what "Remove location" removes
//  (FS-5). The four property dictionaries alone (Exif, TIFF, GPS, IPTC)
//  dropped every XMP field that has no IPTC twin (colour labels, develop
//  settings, custom namespaces) and the camera maker notes. The exporter
//  now also passes the source's XMP (`CGImageMetadata`) and the maker-note
//  dictionaries, and merges them into the new file.
//
//  Orientation is removed from the XMP copy (the pixels are already
//  turned; the file says 1). "Remove location" removes the GPS
//  coordinates AND the place text: IPTC and XMP city, state, country,
//  country code, sub-location and the street-level location structures.
//

import Foundation
import ImageIO

enum ExportMetadata {

    /// Dictionaries to copy besides Exif / TIFF / GPS / IPTC: maker notes
    /// (`{MakerApple}` holds the Live Photo link) and `{ExifAux}`.
    static func extraDictionaries(from properties: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for (key, value) in properties {
            let name = key as String
            if name.hasPrefix("{Maker") || name == (kCGImagePropertyExifAuxDictionary as String) { out[key] = value }
        }
        return out
    }

    /// IPTC keys that name a place.
    static var iptcPlaceKeys: [CFString] { [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
    ] }

    /// `iptc` without place text.
    static func removingPlaceText(fromIPTC iptc: [CFString: Any]) -> [CFString: Any] {
        var out = iptc
        for key in iptcPlaceKeys { out.removeValue(forKey: key) }
        return out
    }

    /// A mutable copy of the source's XMP for the new file: no orientation
    /// tag; with `removeLocation` also no GPS and no place tags. Nil when the
    /// source has no readable metadata.
    static func metadata(from source: URL, removeLocation: Bool) -> CGMutableImageMetadata? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let copy = CGImageMetadataCreateMutableCopy(original) else { return nil }
        // The pixels are already upright.
        CGImageMetadataRemoveTagWithPath(copy, nil, "tiff:Orientation" as CFString)
        // The size of the new picture, not the old one.
        CGImageMetadataRemoveTagWithPath(copy, nil, "exif:PixelXDimension" as CFString)
        CGImageMetadataRemoveTagWithPath(copy, nil, "exif:PixelYDimension" as CFString)
        guard removeLocation else { return copy }
        for case let tag as CGImageMetadataTag in (CGImageMetadataCopyTags(copy) as? [Any]) ?? [] {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            if isLocationTag(prefix: prefix, name: name) {
                CGImageMetadataRemoveTagWithPath(copy, nil, "\(prefix):\(name)" as CFString)
            }
        }
        return copy
    }

    /// GPS coordinates and the XMP place fields.
    static func isLocationTag(prefix: String, name: String) -> Bool {
        if name.hasPrefix("GPS") { return true }                           // exif:GPSLatitude, …
        switch prefix {
        case "photoshop": return ["City", "State", "Country"].contains(name)
        case "Iptc4xmpCore": return name == "Location" || name == "CountryCode"
        case "Iptc4xmpExt": return name.hasPrefix("Location")              // LocationShown / LocationCreated
        default: return false
        }
    }
}
