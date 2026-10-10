//
//  PhotoPasteboard.swift
//  ShrikeIO
//
//  Copy (⌘C) and drag-out pasteboard items. One `NSPasteboardItem` per group:
//
//    1. `public.file-url` of the primary (paste in Finder copies the file;
//       Mail and Messages attach it). Always first.
//    2. The original bytes under the file's own type when it is JPEG, PNG,
//       HEIC, TIFF or GIF.
//    3. `public.png` for every type except PNG, from a full-resolution,
//       orientation-applied decode (`OutputDecoder`).
//
//  2 and 3 are lazy (`NSPasteboardItemDataProvider`): nothing is read or
//  encoded until a paste asks for that type. The provider call blocks for
//  the read or the decode; it only runs at paste time.
//
//  `item(for:)` adds nothing private. Drag sources add
//  `PhotoPasteboard.groupIDsType` themselves.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore

@MainActor
public enum PhotoPasteboard {

    /// Private type drag sources add (the group identifiers of the source
    /// window's list). Never written by `item(for:)`.
    public static let groupIDsType = NSPasteboard.PasteboardType("app.shrike.group-ids")

    /// Original-byte types, by the file's content type.
    nonisolated static let byteTypes: [UTType] = [.jpeg, .png, .heic, .tiff, .gif]

    /// The pasteboard item for `group` (its primary file).
    public static func item(for group: ImageGroup) -> NSPasteboardItem {
        let url = group.primary
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        let original = originalType(of: url)
        var lazyTypes: [NSPasteboard.PasteboardType] = []
        if let original { lazyTypes.append(NSPasteboard.PasteboardType(original.identifier)) }
        if original != .png { lazyTypes.append(.png) }
        let provider = PhotoDataProvider(url: url, originalType: original)
        _ = item.setDataProvider(provider, forTypes: lazyTypes)
        return item
    }

    /// Replaces the contents of `pasteboard` with one item per group.
    public static func write(_ groups: [ImageGroup], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(groups.map { item(for: $0) })
    }

    /// The file's own type when it is one we put on the pasteboard as bytes.
    nonisolated static func originalType(of url: URL) -> UTType? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        return byteTypes.first { type.conforms(to: $0) }
    }

    // MARK: - Drag out

    /// A group carried by the private drag type, with the id of the window
    /// it was dragged from.
    public struct DraggedGroup: Sendable, Equatable {
        public let source: String
        public let group: ImageGroup
        public init(source: String, group: ImageGroup) {
            self.source = source
            self.group = group
        }
    }

    /// The drag item for `group`: the **primary** file URL (outside Shrike
    /// only the primary travels, so a RAW+JPEG pair sends the JPEG) plus
    /// the private type with the whole group (RAW, sidecars) and the
    /// source window's id, so an in-app drop moves or copies every file of
    /// the shot. No image bytes: nothing is read at drag time.
    public static func dragItem(for group: ImageGroup, source: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(group.primary.absoluteString, forType: .fileURL)
        item.setPropertyList(propertyList(for: group, source: source), forType: groupIDsType)
        return item
    }

    /// Every group the private type carries on `pasteboard` (empty for a
    /// drag from Finder or another app).
    public static func draggedGroups(on pasteboard: NSPasteboard) -> [DraggedGroup] {
        (pasteboard.pasteboardItems ?? []).compactMap { draggedGroup(from: $0) }
    }

    public static func draggedGroup(from item: NSPasteboardItem) -> DraggedGroup? {
        guard let plist = item.propertyList(forType: groupIDsType) as? [String: Any] else { return nil }
        return decode(plist)
    }

    /// The file URLs on `pasteboard`, in order.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    nonisolated static func propertyList(for group: ImageGroup, source: String) -> [String: Any] {
        [
            "source": source,
            "primary": group.primary.path,
            "primaryIsRAW": group.primaryIsRAW,
            "companions": group.companions.map { ["path": $0.url.path, "kind": kindName($0.kind)] },
        ]
    }

    nonisolated static func decode(_ plist: [String: Any]) -> DraggedGroup? {
        guard let source = plist["source"] as? String,
              let primary = plist["primary"] as? String else { return nil }
        let companions = (plist["companions"] as? [[String: String]] ?? []).compactMap { entry -> ImageGroup.Companion? in
            guard let path = entry["path"], let kind = entry["kind"].flatMap(kind(named:)) else { return nil }
            return ImageGroup.Companion(url: URL(fileURLWithPath: path), kind: kind)
        }
        let group = ImageGroup(primary: URL(fileURLWithPath: primary), companions: companions,
                               primaryIsRAW: plist["primaryIsRAW"] as? Bool ?? false)
        return DraggedGroup(source: source, group: group)
    }

    nonisolated private static func kindName(_ kind: ImageGroup.CompanionKind) -> String {
        switch kind {
        case .raw: return "raw"
        case .sidecar: return "sidecar"
        case .livePhotoMovie: return "livePhotoMovie"
        }
    }

    nonisolated private static func kind(named name: String) -> ImageGroup.CompanionKind? {
        switch name {
        case "raw": return .raw
        case "sidecar": return .sidecar
        case "livePhotoMovie": return .livePhotoMovie
        default: return nil
        }
    }

    /// Test hook: called with the file and the requested type every time a
    /// provider reads a file or decodes one (paste time only).
    /// `nonisolated(unsafe)`: set only by tests before any paste runs.
    nonisolated(unsafe) public static var readHook: (@Sendable (URL, NSPasteboard.PasteboardType) -> Void)?
}

/// Supplies the lazy types. Immutable, so it is `Sendable`; AppKit calls it
/// on whatever thread asked the pasteboard for data.
final class PhotoDataProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    let url: URL
    let originalType: UTType?

    init(url: URL, originalType: UTType?) {
        self.url = url
        self.originalType = originalType
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = data(for: type) else { return }
        item.setData(data, forType: type)
    }

    func data(for type: NSPasteboard.PasteboardType) -> Data? {
        if let originalType, type.rawValue == originalType.identifier {
            PhotoPasteboard.readHook?(url, type)
            return try? Data(contentsOf: url)
        }
        guard type == .png else { return nil }
        PhotoPasteboard.readHook?(url, type)
        guard let image = try? OutputDecoder.decodeSync(url: url) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString,
                                                          1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
