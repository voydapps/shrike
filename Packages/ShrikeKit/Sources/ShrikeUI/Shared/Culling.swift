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
public enum CullingCommitKind: Sendable, Equatable { case forward, undo, redo }

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

/// Writes only the requested field in one database transaction. File
/// attributes are best-effort mirrors; database failures reach the caller.
public struct CullingWriter: Sendable {
    public let store: MetadataStore
    public init(store: MetadataStore) { self.store = store }

    public func apply(
        _ field: CullingField, urls: [URL],
        compute: @Sendable ([URL: FileRecord]) -> [URL: FileRecord]
    ) async throws -> MetadataWriteResult {
        let previous = try await store.recordsStrict(for: urls)
        let desired = compute(previous)
        switch field {
        case .rating: return try await store.setRatings(desired.mapValues(\.rating))
        case .flag: return try await store.setFlags(desired.mapValues(\.flagged))
        }
    }
}

/// Undo entries are registered synchronously, but resolve their source
/// snapshot inside the ordered write queue. Even Undo then Redo in the
/// same event waits for the corresponding committed result.
@MainActor
public final class CullingUndo {
    private var previous: [URL: FileRecord]?
    private weak var manager: UndoManager?
    private init(manager: UndoManager?) { self.manager = manager }
    private static var lastWrite: Task<Void, Never>?
    static var beforeWriteForTesting: (@MainActor () async throws -> Void)?

    static func waitForPendingWrites() async {
        while let task = lastWrite {
            await task.value
            if lastWrite == task { return }
        }
    }

    public static func failureMessage(_ field: CullingField, error: any Error) -> String {
        "Couldn't save \(field == .rating ? "rating" : "flag"): \(error.localizedDescription)"
    }

    public static func perform(
        _ field: CullingField, urls: [URL], store: MetadataStore, undoManager: UndoManager?,
        compute: @escaping @Sendable ([URL: FileRecord]) -> [URL: FileRecord],
        onChange: @escaping @MainActor @Sendable ([URL: FileRecord]) -> Void,
        onFailure: @escaping @MainActor @Sendable (any Error) -> Void = { Culling.announce($0.localizedDescription) },
        onCommit: @escaping @MainActor @Sendable (MetadataWriteResult, CullingCommitKind) -> Void = { _, _ in }
    ) {
        schedule(field, urls: urls, store: store, undoManager: undoManager,
                 restoreFrom: nil, compute: compute, onChange: onChange, onFailure: onFailure, onCommit: onCommit, kind: .forward)
    }

    private static func schedule(
        _ field: CullingField, urls: [URL], store: MetadataStore, undoManager: UndoManager?,
        restoreFrom: CullingUndo?,
        compute: @escaping @Sendable ([URL: FileRecord]) -> [URL: FileRecord],
        onChange: @escaping @MainActor @Sendable ([URL: FileRecord]) -> Void,
        onFailure: @escaping @MainActor @Sendable (any Error) -> Void,
        onCommit: @escaping @MainActor @Sendable (MetadataWriteResult, CullingCommitKind) -> Void,
        kind: CullingCommitKind
    ) {
        guard !urls.isEmpty else { return }
        let step = CullingUndo(manager: undoManager)
        let before = lastWrite
        lastWrite = Task { @MainActor in
            await before?.value
            // A failed predecessor has no committed change to invert.
            let restore = restoreFrom?.previous
            if restoreFrom != nil && restore == nil {
                step.manager?.removeAllActions(withTarget: step)
                return
            }
            do {
                try await beforeWriteForTesting?()
                FolderWatcherRegistry.shared.ignore(paths: urls, for: .seconds(2))
                let result = try await CullingWriter(store: store).apply(field, urls: urls) { current in
                    restore ?? compute(current)
                }
                step.previous = result.previous
                onChange(result.new)
                onCommit(result, kind)
                let mixed = field == .rating ? Set(result.new.values.map(\.rating)).count > 1
                                             : Set(result.new.values.map(\.flagged)).count > 1
                if mixed {
                    Culling.announce(field == .rating ? "Ratings restored" : "Flags restored")
                } else if let record = result.new[urls[0]] {
                    Culling.announce(field == .rating ? Culling.ratingAnnouncement(record.rating)
                                                     : Culling.flagAnnouncement(record.flagged))
                }
            } catch {
                step.manager?.removeAllActions(withTarget: step)
                onFailure(error)
            }
        }
        undoManager?.registerUndo(withTarget: step) { [step] _ in
            MainActor.assumeIsolated {
                schedule(field, urls: urls, store: store, undoManager: step.manager,
                         restoreFrom: step, compute: compute, onChange: onChange, onFailure: onFailure,
                         onCommit: onCommit, kind: kind == .undo ? .redo : .undo)
            }
        }
        undoManager?.setActionName(Culling.actionName(field))
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
