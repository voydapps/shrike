//
//  ImageSource.swift
//  ShrikeCore
//
//  Abstract image source protocol.
//  Every decodable thing Shrike can show is an `ImageSource`: file on disk,
//  file from a security-scoped bookmark, entry in a ZIP, iCloud file that
//  may need materialization. Today only `FileImageSource` exists; others
//  (bookmarked, archive, iCloud) grow from this protocol.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - ExifSummary

/// Subset of EXIF we surface to the inspector/UI. Populated from
/// `CGImageSourceCopyPropertiesAtIndex` — raw ImageIO numbers normalised to
/// common units (seconds, mm, real numbers) so the UI doesn't re-parse.
public struct ExifSummary: Sendable, Codable, Hashable {
    public let dateTimeOriginal: Date?
    public let cameraMake: String?
    public let cameraModel: String?
    public let lensModel: String?
    public let fNumber: Double?
    public let shutterSpeedSeconds: Double?
    public let iso: Int?
    public let focalLengthMM: Double?
    public let latitude: Double?
    public let longitude: Double?

    public init(
        dateTimeOriginal: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        fNumber: Double? = nil,
        shutterSpeedSeconds: Double? = nil,
        iso: Int? = nil,
        focalLengthMM: Double? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.dateTimeOriginal = dateTimeOriginal
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.fNumber = fNumber
        self.shutterSpeedSeconds = shutterSpeedSeconds
        self.iso = iso
        self.focalLengthMM = focalLengthMM
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - ImageProperties

/// Dimension + colour + EXIF payload returned by `loadProperties`.
/// `CGImageSourceCopyPropertiesAtIndex` reads the file header only
/// ("Dimension-only path", 2-4 ms).
public struct ImageProperties: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let orientation: CGImagePropertyOrientation
    public let colorSpaceName: String?
    public let bitDepth: Int?
    public let hasAlpha: Bool
    public let exif: ExifSummary?
    public let utType: UTType
    public let fileSize: Int64

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: CGImagePropertyOrientation,
        colorSpaceName: String?,
        bitDepth: Int?,
        hasAlpha: Bool,
        exif: ExifSummary?,
        utType: UTType,
        fileSize: Int64
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.colorSpaceName = colorSpaceName
        self.bitDepth = bitDepth
        self.hasAlpha = hasAlpha
        self.exif = exif
        self.utType = utType
        self.fileSize = fileSize
    }
}

// MARK: - Errors

/// Narrow error space shared by every source implementation.
public enum ImageSourceError: Error, Sendable {
    /// The URL could not be opened at all (permissions, missing file, etc.).
    case cannotOpen
    /// `CGImageSource` opened but refused to decode (truncated / malformed).
    case corrupt
    /// File format isn't something we (or ImageIO) can read.
    case unsupported
    /// iCloud placeholder — caller should trigger a download and retry.
    case needsDownload
}

// MARK: - ImageSource protocol

/// Abstract source that can produce a `CGImage` and its header properties.
///
/// `Sendable` + `Hashable` so decode pipelines can key caches and dispatch
/// results across actor boundaries safely.
public protocol ImageSource: Sendable, Hashable {
    var id: String { get }
    var displayName: String { get }
    var fileSize: Int64? { get }
    var mtime: Date? { get }

    /// Decode the full image, optionally downsampled to `maxPixelSize`
    /// (long edge in pixels). Thumbnails should pass a small `maxPixelSize`
    /// so ImageIO decodes at target resolution (much cheaper than decoding
    /// full and scaling). Pass `nil` for full-resolution.
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage

    /// Read EXIF / dimensions / ICC / UTI without decoding pixels.
    func loadProperties() async throws -> ImageProperties

    /// Return the **container's embedded preview** — the small JPEG that
    /// camera firmware writes alongside the full-res image so the body's
    /// LCD can show "instant" review. For an Olympus 5184×3888 JPG that
    /// is typically a 1920×1440 sub-image returned in 10-30 ms (vs the
    /// 80-200 ms cold full-res decode through ImageIO).
    ///
    /// Returns `nil` (not `throws`) when the container has no embedded
    /// preview — small camera-out JPEGs, our own test fixtures, or
    /// formats that don't support previews. The viewer treats `nil` as
    /// "no fast preview path available, fall through to the thumbnail
    /// cache bridge."
    ///
    /// Implementations must NEVER fall back to a fresh thumbnail decode
    /// (`kCGImageSourceCreateThumbnailFromImageIfAbsent: false`) — the
    /// caller is paying for this method specifically because it's
    /// ~10× cheaper than a fresh decode. Falling back would erase the
    /// perf win the call exists to deliver.
    func loadEmbeddedPreview() async throws -> CGImage?
}

// MARK: - Default implementation

public extension ImageSource {
    /// Default: no embedded preview. Synthetic / network sources adopt
    /// this until they grow their own fast-preview path. `FileImageSource`
    /// overrides with the real ImageIO read.
    func loadEmbeddedPreview() async throws -> CGImage? { nil }
}
