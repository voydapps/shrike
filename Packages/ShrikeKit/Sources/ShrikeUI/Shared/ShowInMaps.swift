//
//  ShowInMaps.swift
//  ShrikeUI
//
//  Image ▸ Show in Maps: ⌃⌘M (Mac) / ⌃⇧M (FastStone) and
//  the inspectors' "Show in Maps" link. Opens
//  `https://maps.apple.com/?ll=<lat>,<lon>&q=<file name>`, coordinates
//  signed (south / west negative). No GPS: the menu item is disabled and
//  the key shows "This photo has no location."
//

import AppKit
import ShrikeCore
import ShrikeEdit

@MainActor
enum ShowInMaps {

    /// Opens a URL. Tests replace it, so Maps is never opened.
    static var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static let noLocation = "This photo has no location."
    static let linkTitle = "Show in Maps"

    static func url(for coordinate: PhotoInfo.Coordinate, file: URL) -> URL? {
        MapsLink.url(latitude: coordinate.latitude, longitude: coordinate.longitude,
                     fileName: file.lastPathComponent)
    }

    /// Opens Maps at `coordinate`. False when the coordinate is out of range.
    @discardableResult
    static func open(_ coordinate: PhotoInfo.Coordinate, file: URL) -> Bool {
        guard let url = url(for: coordinate, file: file) else { return false }
        openURL(url)
        return true
    }

    /// The file's GPS, read off the main thread (header only).
    nonisolated static func readLocation(of file: URL) async -> PhotoInfo.Coordinate? {
        (try? await PhotoInfo.read(file))?.gps
    }
}

/// What is known about one file's location: not read yet (no entry),
/// read with GPS, or read without.
struct KnownLocation: Equatable {
    let url: URL
    let coordinate: PhotoInfo.Coordinate?
}
