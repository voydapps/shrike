//
//  PhotoInfo.swift
//  ShrikeCore
//
//  The EXIF summary behind the inspector, Compare,
//  batch-rename tokens and Show in Maps. Header read only:
//  `CGImageSourceCopyPropertiesAtIndex` with `ShouldCache = false`, no
//  pixel decode — cheap enough to run on every navigation.
//
//  GPS is signed by its Ref (bug fix): ImageIO reports positive
//  magnitudes plus "N"/"S"/"E"/"W"; south and west become negative.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoInfoError: Error, Sendable, Equatable {
    /// ImageIO can't open the file as an image.
    case cannotOpen
}

public struct PhotoInfo: Sendable, Hashable {

    public struct Coordinate: Sendable, Hashable {
        /// Degrees, south negative.
        public var latitude: Double
        /// Degrees, west negative.
        public var longitude: Double
        /// Metres, below sea level negative.
        public var altitude: Double?

        public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }

    /// Width as displayed (EXIF orientation 5–8 swaps width and height).
    public var pixelWidth: Int?
    /// Height as displayed.
    public var pixelHeight: Int?
    /// `pixelWidth` × `pixelHeight` as displayed.
    public var pixelSize: CGSize? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
    /// EXIF orientation 1…8, if present.
    public var orientation: Int?
    /// UTType identifier ImageIO reports, e.g. `public.jpeg`.
    public var typeIdentifier: String?
    /// Short type label for the inspector: "JPEG", "HEIC", "NEF".
    public var typeName: String?
    /// Embedded ICC profile name, e.g. "Display P3".
    public var colorProfileName: String?
    /// DateTimeOriginal. With `dateTakenOffsetSeconds` it is the exact
    /// moment; without, it was read as local wall-clock time.
    public var dateTaken: Date?
    /// OffsetTimeOriginal in seconds east of UTC, when present.
    public var dateTakenOffsetSeconds: Int?
    public var make: String?
    public var model: String?
    public var lens: String?
    /// f-number.
    public var aperture: Double?
    /// Exposure time in seconds.
    public var shutter: Double?
    public var iso: Int?
    /// Focal length in mm.
    public var focal: Double?
    /// 35 mm equivalent focal length in mm.
    public var focal35: Double?
    /// EV.
    public var exposureBias: Double?
    public var flashFired: Bool?
    public var whiteBalanceAuto: Bool?
    public var gps: Coordinate?
    public var dpi: Double?
    /// Images in the container (1 for a plain JPEG).
    public var frameCount: Int

    public init(frameCount: Int = 1) {
        self.frameCount = frameCount
    }

    /// Make + Model, with Make dropped when Model already starts with it
    /// ("Canon" + "Canon EOS R5" → "Canon EOS R5").
    public var camera: String? {
        let mk = make?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let md = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (mk, md) {
        case let (mk?, md?):
            let first = mk.split(separator: " ").first.map(String.init) ?? mk
            return md.lowercased().hasPrefix(first.lowercased()) ? md : "\(mk) \(md)"
        case let (mk?, nil): return mk
        case let (nil, md?): return md
        default: return nil
        }
    }

    /// Time zone the capture date should be shown in: the recorded offset,
    /// else the current zone (wall-clock time as the camera wrote it).
    public var dateTakenTimeZone: TimeZone {
        dateTakenOffsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
    }

    // MARK: - Reading

    /// Read the header of `url` off the caller's actor.
    public static func read(_ url: URL) async throws -> PhotoInfo {
        try readSync(url)
    }

    /// Synchronous read (batch rename previews, tests).
    public static func readSync(_ url: URL) throws -> PhotoInfo {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache) else {
            throw PhotoInfoError.cannotOpen
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any]
        else { throw PhotoInfoError.cannotOpen }
        let type = CGImageSourceGetType(src) as String?
        var info = parse(properties: props, typeIdentifier: type, frameCount: count)
        if info.typeName == nil {
            info.typeName = url.pathExtension.nilIfEmpty?.uppercased()
        }
        return info
    }

    /// Build from an ImageIO property dictionary (tests use this directly).
    public static func parse(properties raw: [CFString: Any], typeIdentifier: String?,
                             frameCount: Int = 1) -> PhotoInfo {
        let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = raw[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let aux = raw[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var info = PhotoInfo(frameCount: max(1, frameCount))
        info.typeIdentifier = typeIdentifier
        info.typeName = typeIdentifier.flatMap { UTType($0) }.flatMap(Self.shortName)

        let orientation = number(raw[kCGImagePropertyOrientation]).map { Int($0) }
            ?? number(tiff[kCGImagePropertyTIFFOrientation]).map { Int($0) }
        info.orientation = orientation
        if let w = number(raw[kCGImagePropertyPixelWidth]),
           let h = number(raw[kCGImagePropertyPixelHeight]) {
            let swap = (5...8).contains(orientation ?? 1)
            info.pixelWidth = Int(swap ? h : w)
            info.pixelHeight = Int(swap ? w : h)
        }
        info.colorProfileName = (raw[kCGImagePropertyProfileName] as? String)?.nilIfEmpty
        info.dpi = number(raw[kCGImagePropertyDPIWidth])

        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
                .flatMap(Self.offsetSeconds)
            info.dateTakenOffsetSeconds = offset
            info.dateTaken = Self.exifDate(s, offsetSeconds: offset)
        }

        info.make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed.nilIfEmpty
        info.model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed.nilIfEmpty
        info.lens = ((exif[kCGImagePropertyExifLensModel] as? String)
                     ?? (aux[kCGImagePropertyExifAuxLensModel] as? String))?.trimmed.nilIfEmpty
        info.aperture = number(exif[kCGImagePropertyExifFNumber]).flatMap(positive)
        info.shutter = number(exif[kCGImagePropertyExifExposureTime]).flatMap(positive)
        if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let first = arr.first.flatMap(number) {
            info.iso = Int(first)
        }
        info.focal = number(exif[kCGImagePropertyExifFocalLength]).flatMap(positive)
        info.focal35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).flatMap(positive)
        info.exposureBias = number(exif[kCGImagePropertyExifExposureBiasValue])
        if let flash = number(exif[kCGImagePropertyExifFlash]) {
            info.flashFired = (Int(flash) & 1) == 1
        }
        if let wb = number(exif[kCGImagePropertyExifWhiteBalance]) {
            info.whiteBalanceAuto = Int(wb) == 0
        }

        if let lat = number(gps[kCGImagePropertyGPSLatitude]),
           let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
            var alt = number(gps[kCGImagePropertyGPSAltitude])
            if let a = alt, number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { alt = -abs(a) }
            info.gps = Coordinate(latitude: signed(lat, negativeRef: "S", ref: latRef),
                                  longitude: signed(lon, negativeRef: "W", ref: lonRef),
                                  altitude: alt)
        }
        return info
    }

    // MARK: - Helpers

    /// Magnitude signed by its Ref. No Ref: keep the value's own sign.
    static func signed(_ value: Double, negativeRef: String, ref: String?) -> Double {
        guard let ref, !ref.isEmpty else { return value }
        return ref.hasPrefix(negativeRef) ? -abs(value) : abs(value)
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func positive(_ v: Double) -> Double? { v > 0 ? v : nil }

    private static func shortName(_ type: UTType) -> String? {
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        if type.conforms(to: .tiff) && !type.conforms(to: .rawImage) { return "TIFF" }
        return type.preferredFilenameExtension?.uppercased()
    }

    /// "+02:00" / "-05:30" / "Z" → seconds east of UTC.
    static func offsetSeconds(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "Z" { return 0 }
        guard t.count == 6, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let parts = t.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              h <= 14, m < 60 else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    /// "yyyy:MM:dd HH:mm:ss" in the given offset, else the current zone.
    static func exifDate(_ s: String, offsetSeconds: Int?) -> Date? {
        let digits = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 6, digits[0] > 0 else { return nil }
        var c = DateComponents()
        c.year = digits[0]; c.month = digits[1]; c.day = digits[2]
        c.hour = digits[3]; c.minute = digits[4]; c.second = digits[5]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        guard let month = c.month, (1...12).contains(month),
              let day = c.day, (1...31).contains(day) else { return nil }
        return cal.date(from: c)
    }
}

// MARK: - Display formats

extension PhotoInfo {
    public enum Format {
        /// "ƒ/2.8", "ƒ/8"
        public static func aperture(_ f: Double) -> String {
            "ƒ/" + trim(f, maxDecimals: 1)
        }

        /// "1/250 s" below 0.3 s, else "2.5 s" / "30 s".
        public static func shutter(_ seconds: Double) -> String {
            if seconds < 0.3 {
                return "1/\(Int((1 / seconds).rounded())) s"
            }
            return trim(seconds, maxDecimals: 1) + " s"
        }

        /// "25 mm" or "25 mm (50 mm equiv.)".
        public static func focal(_ mm: Double, equivalent: Double? = nil) -> String {
            let base = trim(mm, maxDecimals: 1) + " mm"
            guard let eq = equivalent, abs(eq - mm) >= 0.5 else { return base }
            return base + " (\(Int(eq.rounded())) mm equiv.)"
        }

        /// "−0.7 EV" (Unicode minus), "+0.3 EV", "0 EV".
        public static func exposureBias(_ ev: Double) -> String {
            let r = (ev * 10).rounded() / 10
            if r == 0 { return "0 EV" }
            let mag = String(format: "%.1f", abs(r))
            return (r < 0 ? "\u{2212}" : "+") + mag + " EV"
        }

        /// "45.4371° N, 12.3327° E".
        public static func coordinate(_ c: Coordinate) -> String {
            let lat = String(format: "%.4f° %@", abs(c.latitude), c.latitude < 0 ? "S" : "N")
            let lon = String(format: "%.4f° %@", abs(c.longitude), c.longitude < 0 ? "W" : "E")
            return lat + ", " + lon
        }

        /// "6000 × 4000 (24.0 MP)".
        public static func dimensions(_ size: CGSize) -> String {
            let w = Int(size.width), h = Int(size.height)
            let mp = Double(w * h) / 1_000_000
            return "\(w) × \(h) (" + String(format: "%.1f", mp) + " MP)"
        }

        private static func trim(_ v: Double, maxDecimals: Int) -> String {
            let s = String(format: "%.\(maxDecimals)f", v)
            guard s.contains(".") else { return s }
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
}
