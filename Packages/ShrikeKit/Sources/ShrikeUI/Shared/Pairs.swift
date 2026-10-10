//
//  Pairs.swift
//  ShrikeUI
//
//  RAW+JPEG pairs and companions, the UI side. Grouping
//  itself is `ImageGrouping`; this file holds the copy and
//  the "pref changed" signal that makes open windows list again.
//

import Foundation
import ShrikeCore

public enum PairCopy {

    /// "Also: DSC_0042.ORF (24.1 MB)" under the file name in the
    /// inspector. Lists the RAW companions (not sidecars or the MOV);
    /// nil when the group has none. Reads file sizes from disk.
    public static func alsoLine(for group: ImageGroup) -> String? {
        let raws = group.rawURLs.filter { $0 != group.primary }
        guard !raws.isEmpty else { return nil }
        let parts = raws.map { url -> String in
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            guard let bytes else { return url.lastPathComponent }
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(url.lastPathComponent) (\(size))"
        }
        return "Also: " + parts.joined(separator: ", ")
    }
}

public extension Notification.Name {
    /// Settings ▸ General ▸ RAW+JPEG pairs changed: lists group again.
    static let shrikeGroupingDidChange = Notification.Name("ShrikeGroupingDidChange")
}

public enum PairsPreference {
    /// Writes `shrike.grouping.pairRAW` and tells open windows to list
    /// again.
    ///
    /// The notification is always posted on the main thread:
    /// `BrowserWindowController` observes it with a main-actor `@objc`
    /// selector, which NotificationCenter calls on the posting thread, and
    /// Swift 6 traps a main-actor method that runs anywhere else. (The
    /// settings binding that calls this is a nonisolated closure.)
    public static func set(showAsOneItem: Bool) {
        guard ImageGroupingPreference.isEnabled != showAsOneItem else { return }
        ImageGroupingPreference.isEnabled = showAsOneItem
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .shrikeGroupingDidChange, object: nil)
            }
        }
    }
}
