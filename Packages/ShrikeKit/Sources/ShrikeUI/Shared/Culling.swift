//
//  Culling.swift
//  ShrikeUI
//
//  Rating and flag: saved at once for every image member
//  of a group (JPEG and RAW; sidecars and movies are not rated), one undo
//  step per key press, whatever the selection size. No toast: the pill
//  and the cells show the change, VoiceOver announces it.
//

import AppKit
import ShrikeCore
import ShrikeIO

/// Which field a culling change writes.
public enum CullingField: Sendable, Hashable {
    case rating
    case flag
}

public enum Culling {

    /// The files a rating or flag is written to: the primary and any RAW
    /// companion. Sidecars (`.xmp`, `.aae`) and Live Photo movies are not
    /// rated.
    public static func imageURLs(of group: ImageGroup) -> [URL] {
        var urls = [group.primary]
        for raw in group.rawURLs where !urls.contains(raw) { urls.append(raw) }
        return urls
    }

    public static func imageURLs(of groups: [ImageGroup]) -> [URL] {
        groups.flatMap { imageURLs(of: $0) }
    }

    /// "Rated 3 stars" / "Rated 1 star" / "Rating cleared".
    public static func ratingAnnouncement(_ stars: Int) -> String {
        switch stars {
        case ...0: return "Rating cleared"
        case 1: return "Rated 1 star"
        default: return "Rated \(min(5, stars)) stars"
        }
    }

    /// "Flagged" / "Flag removed".
    public static func flagAnnouncement(_ flagged: Bool) -> String {
        flagged ? "Flagged" : "Flag removed"
    }

    /// Undo menu name: "Undo Rating" / "Undo Flag".
    public static func actionName(_ field: CullingField) -> String {
        field == .rating ? "Rating" : "Flag"
    }

    @MainActor
    public static func announce(_ text: String) {
        guard let element = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    /// New values for a rating press: every URL gets `stars`. Pressing the
    /// current rating again keeps it (FastStone; only `0` clears).
    public static func ratingValues(_ stars: Int, urls: [URL], previous: [URL: FileRecord]) -> [URL: FileRecord] {
        let clamped = max(0, min(5, stars))
        var out: [URL: FileRecord] = [:]
        for url in urls {
            var record = previous[url] ?? FileRecord()
            record.rating = clamped
            out[url] = record
        }
        return out
    }

    /// New values for a flag toggle: if any target is unflagged, flag all;
    /// otherwise remove the flag from all. `leaders` decides (the primary
    /// files), so a RAW companion's stale flag never flips the result.
    public static func toggledFlagValues(urls: [URL], leaders: [URL], previous: [URL: FileRecord]) -> [URL: FileRecord] {
        let anyUnflagged = leaders.contains { !(previous[$0]?.flagged ?? false) }
        var out: [URL: FileRecord] = [:]
        for url in urls {
            var record = previous[url] ?? FileRecord()
            record.flagged = anyUnflagged
            out[url] = record
        }
        return out
    }
}

/// Reads the current values, computes the new ones, writes them in one
/// transaction per distinct value. Returns (previous, new).
public struct CullingWriter: Sendable {

    public let store: MetadataStore

    public init(store: MetadataStore) { self.store = store }

    public func apply(
        _ field: CullingField, urls: [URL],
        compute: @Sendable ([URL: FileRecord]) -> [URL: FileRecord]
    ) async -> (previous: [URL: FileRecord], new: [URL: FileRecord]) {
        guard !urls.isEmpty else { return ([:], [:]) }
        let previous = await store.records(for: urls)
        let new = compute(previous)
        switch field {
        case .rating:
            var byValue: [Int: [URL]] = [:]
            for (url, record) in new { byValue[record.rating, default: []].append(url) }
            for (value, targets) in byValue { try? await store.setRating(value, for: targets) }
        case .flag:
            var byValue: [Bool: [URL]] = [:]
            for (url, record) in new { byValue[record.flagged, default: []].append(url) }
            for (value, targets) in byValue { try? await store.setFlag(value, for: targets) }
        }
        return (previous, new)
    }
}

/// One undo step per culling press, with redo. The undo
/// entry is registered at once (so ⌘Z right after the key works); it
/// restores the values read just before the write.
@MainActor
public final class CullingUndo {

    private var previous: [URL: FileRecord] = [:]
    private weak var manager: UndoManager?

    private init(manager: UndoManager?) { self.manager = manager }

    /// The last culling write in flight. Writes run one after another in
    /// the order of the presses: each one reads the
    /// values it changes after the one before has saved. Two presses a
    /// few ms apart (flag, then a rating) used to read the same old
    /// record, and the second one's result put the old flag back on
    /// screen.
    private static var lastWrite: Task<Void, Never>?

    /// Waits until every culling write started so far has saved (tests).
    static func waitForPendingWrites() async {
        while let task = lastWrite {
            await task.value
            if lastWrite == task { return }
        }
    }

    /// Writes `field` for `urls`. `onChange` runs with the new values once
    /// they are saved, and again after each undo / redo.
    public static func perform(
        _ field: CullingField, urls: [URL], store: MetadataStore, undoManager: UndoManager?,
        compute: @escaping @Sendable ([URL: FileRecord]) -> [URL: FileRecord],
        onChange: @escaping @MainActor @Sendable ([URL: FileRecord]) -> Void
    ) {
        guard !urls.isEmpty else { return }
        let step = CullingUndo(manager: undoManager)
        let writer = CullingWriter(store: store)
        let before = lastWrite
        lastWrite = Task { @MainActor in
            await before?.value
            // The rating and flag are mirrored in the
            // files' extended attributes, and the folder watchers saw that
            // write as a changed file: the Browser dropped the thumbnails
            // and listed the folder again (the whole grid blinked).
            FolderWatcherRegistry.shared.ignore(paths: urls, for: .seconds(2))
            let result = await writer.apply(field, urls: urls, compute: compute)
            step.previous = result.previous
            onChange(result.new)
        }
        guard let undoManager else { return }
        // NSUndoManager does not retain its target: the handler holds
        // `step` strongly so the entry keeps it alive.
        undoManager.registerUndo(withTarget: step) { [step] _ in
            MainActor.assumeIsolated {
                // Values not read yet (⌘Z within the same few ms): nothing
                // was written either, so there is nothing to restore.
                let restore = step.previous
                let ordered = urls.filter { restore[$0] != nil }
                perform(field, urls: ordered, store: store, undoManager: step.manager,
                        compute: { _ in restore }, onChange: onChange)
            }
        }
        undoManager.setActionName(Culling.actionName(field))
    }
}

/// Keeps a slow batched read from replacing newer writes.
/// A window reads the saved values of its whole list in one go;
/// a rating, flag or tag change that lands while that read is in flight
/// is newer than what the read returns, so the read must not replace it.
///
/// Take a token when the read starts, note every write as it lands, then
/// `merge` the read: URLs written after the token keep their current
/// value, every other URL takes the read value.
struct LateReadGuard {
    private var serial = 0
    private var writtenAt: [URL: Int] = [:]

    /// The token of a read that starts now.
    func begin() -> Int { serial }

    /// Values for `urls` were just written (and applied).
    mutating func noteWrite<S: Sequence>(_ urls: S) where S.Element == URL {
        serial &+= 1
        for url in urls { writtenAt[url] = serial }
    }

    /// `read`, except that URLs written after `token` keep `current`.
    func merge<Value>(read: [URL: Value], current: [URL: Value], since token: Int) -> [URL: Value] {
        var out = read
        for (url, at) in writtenAt where at > token { out[url] = current[url] }
        return out
    }
}
