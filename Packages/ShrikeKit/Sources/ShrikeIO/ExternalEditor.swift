//
//  ExternalEditor.swift
//  ShrikeIO
//
//  User-configurable external editors: a
//  registry with customisable shortcuts rather than fixed
//  E / Alt+2 / Alt+3. Slot 0 maps to E (⌘E), slots 1–8 to ⌥2 … ⌥9.
//
//  * `ExternalEditor` stores both the bundle identifier and the last known
//    app location. If the app moved (e.g. an update installed it
//    elsewhere) we find it again by bundle identifier and remember the
//    new place; if it is gone, `open` throws `applicationNotFound` with
//    the editor's name so the UI can say so.
//  * Persistence: JSON under `ExternalEditorRegistry.defaultsKey`
//    (`shrike.editors.registry`). On first use the legacy
//    `shrike.editors.slots` list (`Prefs.externalEditors`, written by the
//    current Preferences tab) is imported once; empty "Unused"
//    placeholders are skipped.
//  * `ApplicationWorkspace` wraps the NSWorkspace calls so tests never
//    launch an app.
//  * Send RAW: an editor with `sendRAW` gets the RAW
//    file of a RAW+JPEG pair instead of the JPEG. `open(_: ImageGroup, …)`
//    applies it; `files(for:)` says which file an editor would get.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import ShrikeCore

// MARK: - Model

public struct ExternalEditor: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    /// Name shown in menus ("Open in Photoshop").
    public var displayName: String
    /// e.g. `com.adobe.Photoshop`. Used to find the app again if it moved.
    public var bundleIdentifier: String?
    /// Last known location of the `.app` bundle.
    public var applicationURL: URL?
    /// Open the RAW instead of the JPEG when the item has both
    /// ("Send RAW"). Default false; missing in older saved data = false.
    public var sendRAW: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        applicationURL: URL? = nil,
        sendRAW: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.sendRAW = sendRAW
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, applicationURL, sendRAW
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationURL = try c.decodeIfPresent(URL.self, forKey: .applicationURL)
        sendRAW = try c.decodeIfPresent(Bool.self, forKey: .sendRAW) ?? false
    }

    /// The file this editor gets for `group`: the RAW when `sendRAW` is on
    /// and the group has one, else the displayed (primary) file.
    public func file(for group: ImageGroup) -> URL {
        if sendRAW, let raw = group.rawURL { return raw }
        return group.primary
    }

    /// One file per group (see `file(for:)`), duplicates removed.
    public func files(for groups: [ImageGroup]) -> [URL] {
        var seen = Set<String>()
        return groups.map(file(for:)).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// An editor for the app at `appURL`, or `nil` when it isn't a usable
    /// application bundle (not a folder, no bundle identifier, not an
    /// app, or Shrike itself). Reads the bundle's Info.plist only; never
    /// launches anything. For the Settings tab's "+" panel.
    public static func validate(appURL: URL) -> ExternalEditor? {
        guard appURL.isFileURL else { return nil }
        let url = appURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
              bundleID != Bundle.main.bundleIdentifier,
              bundleID != "app.shrike"
        else { return nil }
        let isApp = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            .map { $0.conforms(to: .application) }
            ?? false
        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        guard isApp || packageType == "APPL" else { return nil }
        return ExternalEditor(applicationAt: url)
    }

    /// Builds an editor from an `.app` bundle on disk (name and bundle
    /// identifier read from the bundle).
    public init(applicationAt url: URL) {
        self.init(
            displayName: ExternalEditor.displayName(ofApplicationAt: url),
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
            applicationURL: url
        )
    }

    /// "Adobe Photoshop 2026" for `/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app`.
    public static func displayName(ofApplicationAt url: URL) -> String {
        if let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName, !name.isEmpty {
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// An app that can open a given file, offered when the user adds an editor.
public struct ExternalEditorCandidate: Sendable, Hashable {
    public let applicationURL: URL
    public let bundleIdentifier: String?
    public let displayName: String
    /// The system default app for the file.
    public let isDefault: Bool

    public init(applicationURL: URL, bundleIdentifier: String?, displayName: String, isDefault: Bool) {
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isDefault = isDefault
    }

    public var editor: ExternalEditor {
        ExternalEditor(displayName: displayName, bundleIdentifier: bundleIdentifier,
                       applicationURL: applicationURL)
    }
}

public enum ExternalEditorError: Error, Equatable, Sendable, LocalizedError {
    /// The app was deleted or cannot be found by path or bundle identifier.
    case applicationNotFound(name: String)
    /// A file to open no longer exists.
    case fileNotFound(URL)
    /// All nine slots are taken.
    case registryFull
    /// No editor in that slot.
    case emptySlot(Int)
    /// LaunchServices refused to open the files.
    case launchFailed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound(let name):
            return "“\(name)” can’t be found. It may have been moved or deleted. Choose it again in Settings ▸ External Editors."
        case .fileNotFound(let url):
            return "“\(url.lastPathComponent)” no longer exists."
        case .registryFull:
            return "You can add up to \(ExternalEditorRegistry.maxEditors) external editors."
        case .emptySlot(let slot):
            return "No external editor is set for slot \(slot + 1)."
        case .launchFailed(let name, let reason):
            return "“\(name)” couldn’t open the file. \(reason)"
        }
    }
}

// MARK: - Workspace seam

/// The NSWorkspace calls the registry needs. Tests substitute a fake so no
/// app is ever launched.
@MainActor
public protocol ApplicationWorkspace: AnyObject {
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func urlsForApplications(toOpen url: URL) -> [URL]
    func urlForApplication(toOpen url: URL) -> URL?
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws
}

@MainActor
public final class SystemApplicationWorkspace: ApplicationWorkspace {
    public init() {}

    public func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func urlsForApplications(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    public func urlForApplication(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    public func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL,
                                              configuration: configuration)
    }
}

// MARK: - Registry

/// Ordered list of up to nine external editors. Index = slot
/// (0 → E / ⌘E, 1 → ⌥2, … 8 → ⌥9). Main-actor only: it is driven by
/// menus, key handlers and the Settings tab.
@MainActor
public final class ExternalEditorRegistry {

    public nonisolated static let maxEditors = 9
    /// UserDefaults key for the registry. Needs adding to
    /// `Prefs.Key.allKeys` so "Reset all" clears it.
    public nonisolated static let defaultsKey = "shrike.editors.registry"
    /// Legacy key written by the current Preferences tab
    /// (`Prefs.externalEditors`). Imported once, never written.
    public nonisolated static let legacyDefaultsKey = "shrike.editors.slots"

    /// Posted (object = registry) after every change to `editors`.
    public nonisolated static let didChangeNotification = Notification.Name("ShrikeExternalEditorRegistryDidChange")

    public static let shared = ExternalEditorRegistry()

    public private(set) var editors: [ExternalEditor]

    private let defaults: UserDefaults
    private let workspace: any ApplicationWorkspace

    public init(
        defaults: UserDefaults = ShrikeDefaults.store,
        workspace: any ApplicationWorkspace = SystemApplicationWorkspace()
    ) {
        self.defaults = defaults
        self.workspace = workspace
        self.editors = Self.load(from: defaults)
    }

    // MARK: Slots

    /// Editor in `slot` (0-based), or nil.
    public func editor(inSlot slot: Int) -> ExternalEditor? {
        editors.indices.contains(slot) ? editors[slot] : nil
    }

    public func slot(of id: ExternalEditor.ID) -> Int? {
        editors.firstIndex { $0.id == id }
    }

    /// Appends an editor. Returns its slot. An app already in the list
    /// (same bundle identifier or path) is not added twice; its existing
    /// slot is returned.
    @discardableResult
    public func add(_ editor: ExternalEditor) throws -> Int {
        if let existing = editors.firstIndex(where: { Self.sameApplication($0, editor) }) {
            return existing
        }
        guard editors.count < Self.maxEditors else { throw ExternalEditorError.registryFull }
        editors.append(editor)
        didChange()
        return editors.count - 1
    }

    /// Replaces the editor in `slot` (or appends when `slot == count`).
    public func setEditor(_ editor: ExternalEditor, inSlot slot: Int) throws {
        guard slot >= 0, slot < Self.maxEditors else { throw ExternalEditorError.emptySlot(slot) }
        if slot < editors.count {
            editors[slot] = editor
        } else if slot == editors.count {
            editors.append(editor)
        } else {
            throw ExternalEditorError.emptySlot(slot)
        }
        didChange()
    }

    public func remove(id: ExternalEditor.ID) {
        let before = editors.count
        editors.removeAll { $0.id == id }
        if editors.count != before { didChange() }
    }

    /// Moves an editor to another slot; the others shift.
    public func move(fromSlot source: Int, toSlot destination: Int) {
        guard editors.indices.contains(source), editors.indices.contains(destination),
              source != destination else { return }
        let editor = editors.remove(at: source)
        editors.insert(editor, at: destination)
        didChange()
    }

    public func rename(id: ExternalEditor.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = slot(of: id), editors[index].displayName != trimmed else { return }
        editors[index].displayName = trimmed
        didChange()
    }

    public func removeAll() {
        guard !editors.isEmpty else { return }
        editors.removeAll()
        didChange()
    }

    // MARK: Discovery

    /// Apps that can open `fileURL`, the system default first, then by
    /// name. Shrike itself is left out.
    public func candidates(for fileURL: URL) -> [ExternalEditorCandidate] {
        let defaultApp = workspace.urlForApplication(toOpen: fileURL)?.standardizedFileURL
        let ownBundleID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [ExternalEditorCandidate] = []
        for appURL in workspace.urlsForApplications(toOpen: fileURL) {
            let standardized = appURL.standardizedFileURL
            let bundleID = Bundle(url: appURL)?.bundleIdentifier
            if let bundleID, bundleID == ownBundleID { continue }
            guard seen.insert(bundleID ?? standardized.path).inserted else { continue }
            result.append(ExternalEditorCandidate(
                applicationURL: appURL,
                bundleIdentifier: bundleID,
                displayName: ExternalEditor.displayName(ofApplicationAt: appURL),
                isDefault: standardized == defaultApp
            ))
        }
        return result.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Launch

    /// Where the editor's app is now. Tries the stored path, then the
    /// bundle identifier (and remembers a new location). Throws
    /// `applicationNotFound` when neither works.
    public func resolveApplicationURL(for editor: ExternalEditor) throws -> URL {
        if let url = editor.applicationURL, Self.isApplicationBundle(url),
           editor.bundleIdentifier == nil || Bundle(url: url)?.bundleIdentifier == editor.bundleIdentifier {
            return url
        }
        if let bundleID = editor.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleID),
           Self.isApplicationBundle(url) {
            if let index = slot(of: editor.id), editors[index].applicationURL != url {
                editors[index].applicationURL = url
                didChange()
            }
            return url
        }
        throw ExternalEditorError.applicationNotFound(name: editor.displayName)
    }

    /// True when `resolveApplicationURL` would succeed (menus grey out
    /// missing apps).
    public func isAvailable(_ editor: ExternalEditor) -> Bool {
        (try? resolveApplicationURL(for: editor)) != nil
    }

    /// Opens `urls` in the editor. Files are checked first so a stale
    /// selection gives a clear error instead of a LaunchServices one.
    public func open(_ urls: [URL], with editor: ExternalEditor) async throws {
        guard !urls.isEmpty else { return }
        if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw ExternalEditorError.fileNotFound(missing)
        }
        let appURL = try resolveApplicationURL(for: editor)
        do {
            try await workspace.open(urls, withApplicationAt: appURL)
        } catch {
            throw ExternalEditorError.launchFailed(name: editor.displayName,
                                                   reason: error.localizedDescription)
        }
    }

    /// Opens `urls` with the editor in `slot`.
    public func open(_ urls: [URL], slot: Int) async throws {
        guard let editor = editor(inSlot: slot) else { throw ExternalEditorError.emptySlot(slot) }
        try await open(urls, with: editor)
    }

    /// Opens an item: its RAW when the editor has Send RAW on and the item
    /// has one, else the displayed file. Companions are never sent.
    public func open(_ group: ImageGroup, with editor: ExternalEditor) async throws {
        try await open([editor.file(for: group)], with: editor)
    }

    /// Opens several items (one file each, see `open(_:with:)`). Labelled
    /// `groups:` so `open([], …)` stays unambiguous with the `[URL]` form.
    public func open(groups: [ImageGroup], with editor: ExternalEditor) async throws {
        try await open(editor.files(for: groups), with: editor)
    }

    /// Opens an item with the editor in `slot` (0 → ⌘E).
    public func open(_ group: ImageGroup, slot: Int) async throws {
        guard let editor = editor(inSlot: slot) else { throw ExternalEditorError.emptySlot(slot) }
        try await open(group, with: editor)
    }

    /// Opens several items with the editor in `slot`.
    public func open(groups: [ImageGroup], slot: Int) async throws {
        guard let editor = editor(inSlot: slot) else { throw ExternalEditorError.emptySlot(slot) }
        try await open(groups: groups, with: editor)
    }

    /// Turns Send RAW on or off for an editor (Settings tab checkbox).
    public func setSendRAW(_ on: Bool, for id: ExternalEditor.ID) {
        guard let index = slot(of: id), editors[index].sendRAW != on else { return }
        editors[index].sendRAW = on
        didChange()
    }

    // MARK: Persistence

    private func didChange() {
        if let data = try? JSONEncoder().encode(editors) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    static func load(from defaults: UserDefaults) -> [ExternalEditor] {
        if let data = defaults.data(forKey: defaultsKey) {
            let decoded = (try? JSONDecoder().decode([ExternalEditor].self, from: data)) ?? []
            return Array(decoded.prefix(maxEditors))
        }
        // One-time import of the legacy slot list.
        guard let data = defaults.data(forKey: legacyDefaultsKey),
              let slots = try? JSONDecoder().decode([ExternalEditorSlot].self, from: data)
        else { return [] }
        let imported = slots.compactMap(Self.editor(fromLegacy:)).prefix(maxEditors)
        return Array(imported)
    }

    /// Legacy slots hold either a path to an `.app` or a bundle identifier.
    static func editor(fromLegacy slot: ExternalEditorSlot) -> ExternalEditor? {
        let value = slot.bundleIdentifierOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }   // "Unused" placeholder
        if value.hasPrefix("/") {
            let url = URL(fileURLWithPath: value, isDirectory: true)
            return ExternalEditor(
                id: slot.id, displayName: slot.name,
                bundleIdentifier: Bundle(url: url)?.bundleIdentifier, applicationURL: url
            )
        }
        return ExternalEditor(id: slot.id, displayName: slot.name, bundleIdentifier: value)
    }

    // MARK: Helpers

    private static func sameApplication(_ a: ExternalEditor, _ b: ExternalEditor) -> Bool {
        if let idA = a.bundleIdentifier, let idB = b.bundleIdentifier { return idA == idB }
        if let urlA = a.applicationURL, let urlB = b.applicationURL {
            return urlA.standardizedFileURL == urlB.standardizedFileURL
        }
        return false
    }

    private static func isApplicationBundle(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
