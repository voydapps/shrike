//
//  InspectorPaneView.swift
//  ShrikeUI
//
//  Right-pane inspector for the browser window. SwiftUI, hosted inside the
//  browser window via `NSHostingView`. Displays preview, file info, EXIF,
//  rating, flag, and tags for the currently selected item(s).
//
//  Multi-select: shows "—" placeholder for fields whose values diverge across
//  the selection. Rating / flag changes apply to the whole selection.
//
//  and
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ShrikeCore

// MARK: - Model

/// Immutable view-model for the inspector. The host view controller
/// recomputes this whenever the selection changes.
public struct InspectorState: Sendable, Equatable {

    /// Number of items in the current selection. 0 means "no selection".
    public var count: Int
    /// Unique common display name, or nil when diverging / empty.
    public var commonName: String?
    /// "Also: DSC_0042.ORF (24.1 MB)" for a pair.
    public var alsoLine: String?
    /// Primary preview URL (first item in selection).
    public var previewURL: URL?
    /// Shared rating, or nil when values diverge.
    public var commonRating: Int?
    /// Shared flag, or nil when values diverge.
    public var commonFlag: Bool?
    /// Union of tags across the selection.
    public var tagsUnion: [String]
    /// Tags shared by every item in the selection — displayed as the
    /// "common" set; the difference against union is rendered dim.
    public var tagsCommon: [String]
    /// Selected file size in bytes, when common.
    public var commonFileSize: Int64?
    /// 2+ selected: the sizes added up, the number the status bar shows.
    /// Nil for 0 or 1 item.
    public var totalFileSize: Int64?
    /// Selected UT type, when common.
    public var commonType: UTType?
    /// Pixel dims, when common.
    public var commonWidth: Int?
    public var commonHeight: Int?
    /// Modification date, when common.
    public var commonDate: Date?
    /// Capture rows of a single item, filled once its
    /// header has been read.
    public var capture: [InspectorRow] = []
    /// "33.8600° S, 151.2100° E" for a single item with GPS.
    public var location: String?
    /// The GPS behind `location` (the "Show in Maps" link).
    public var coordinate: PhotoInfo.Coordinate?
    /// With nothing selected: "252 images" under the folder's name
    /// (`commonName`). Nil shows "No selection".
    public var folderSummary: String?
    /// With nothing selected: the folder's path, for the "Path" row.
    public var folderPath: String?

    public init(
        count: Int = 0,
        commonName: String? = nil,
        previewURL: URL? = nil,
        commonRating: Int? = nil,
        commonFlag: Bool? = nil,
        tagsUnion: [String] = [],
        tagsCommon: [String] = [],
        commonFileSize: Int64? = nil,
        commonType: UTType? = nil,
        commonWidth: Int? = nil,
        commonHeight: Int? = nil,
        commonDate: Date? = nil
    ) {
        self.count = count
        self.commonName = commonName
        self.previewURL = previewURL
        self.commonRating = commonRating
        self.commonFlag = commonFlag
        self.tagsUnion = tagsUnion
        self.tagsCommon = tagsCommon
        self.commonFileSize = commonFileSize
        self.commonType = commonType
        self.commonWidth = commonWidth
        self.commonHeight = commonHeight
        self.commonDate = commonDate
    }

    public static let empty = InspectorState()

    /// Nothing selected: the folder's name and image count,
    /// never the first photo, and no rating, flag or tag controls.
    public static func folder(name: String, visible: Int, total: Int, path: String? = nil) -> InspectorState {
        var s = InspectorState()
        s.commonName = name
        s.folderPath = path
        s.folderSummary = WindowTitles.browserSubtitle(visible: visible, total: total)
        return s
    }

    /// The header line for 2+ items.
    public static func multipleHeader(_ count: Int) -> String { "\(count) items selected" }

    /// Pure reducer — collapses a list of items into the state required by
    /// the inspector, applying the "— when divergent" rule across mutable
    /// fields. Unit-tested.
    public static func reduce(_ items: [BrowserItem]) -> InspectorState {
        guard let first = items.first else { return .empty }
        var s = InspectorState()
        s.count = items.count
        s.previewURL = first.url

        func common<T: Equatable>(_ path: (BrowserItem) -> T) -> T? {
            let values = items.map(path)
            guard let f = values.first else { return nil }
            return values.allSatisfy { $0 == f } ? f : nil
        }

        s.commonName = items.count == 1 ? first.displayName : common { $0.displayName }
        s.alsoLine = items.count == 1 ? PairCopy.alsoLine(for: first.group) : nil
        s.commonRating = common { $0.rating }
        s.commonFlag = common { $0.isFlagged }
        s.commonFileSize = common { $0.fileSize }
        if items.count > 1 { s.totalFileSize = items.reduce(Int64(0)) { $0 + $1.fileSize } }
        s.commonType = common { $0.utType }
        // `common` returns T? where T is the path's value type — for an
        // optional property this becomes T? of an Optional, which we flatten
        // with `??` so a divergent selection cleanly reads `nil`.
        s.commonWidth = common { $0.pixelWidth } ?? nil
        s.commonHeight = common { $0.pixelHeight } ?? nil
        s.commonDate = common { $0.modificationDate }

        let unionSet = items.reduce(into: Set<String>()) { $0.formUnion($1.tags) }
        s.tagsUnion = unionSet.sorted()
        if items.isEmpty {
            s.tagsCommon = []
        } else {
            var common = Set(items[0].tags)
            for item in items.dropFirst() {
                common.formIntersection(item.tags)
            }
            s.tagsCommon = common.sorted()
        }
        return s
    }
}

// MARK: - Host

@MainActor
public final class InspectorPaneController: NSViewController {

    /// Callbacks to the surrounding window controller.
    public var onRate: ((Int) -> Void)?
    public var onFlag: ((Bool) -> Void)?
    /// A tag chip's ⓧ: remove that tag from the selection.
    public var onRemoveTag: ((String) -> Void)?
    /// The "+" chip: open the Tags popover anchored on `anchor` (the
    /// inspector's Tags row).
    public var onAddTag: ((NSView) -> Void)?

    /// The Tags row, where the popover opened from the inspector anchors.
    private(set) weak var tagsRowAnchor: NSView?

    private let stateBox = InspectorStateBox()

    /// Gives the grid's in-memory thumbnail lookup.
    /// Called on the main thread; the lookup it returns runs off it.
    var panelLookups: (@MainActor () -> InspectorPreviewImageView.Lookups?)? {
        get { stateBox.panelLookups }
        set { stateBox.panelLookups = newValue }
    }

    public override func loadView() {
        let host = NSHostingView(rootView: InspectorRoot(
            state: stateBox,
            onRate: { [weak self] in self?.onRate?($0) },
            onFlag: { [weak self] in self?.onFlag?($0) },
            onRemoveTag: { [weak self] in self?.onRemoveTag?($0) },
            onAddTag: { [weak self] in self?.addTagTapped() },
            registerTagsAnchor: { [weak self] in self?.tagsRowAnchor = $0 }
        ).tint(Color(nsColor: .controlAccentColor)))
        host.translatesAutoresizingMaskIntoConstraints = false
        // A hosting view turns its SwiftUI ideal/min size into
        // constraints by default, and those pushed through the split view
        // to the window (1072 → 1507 pt on the first click, taller on
        // fast clicks). The split decides the pane's size.
        host.sizingOptions = []
        // The pane's width comes from the split view, never from
        // its content (a photo once pushed the rows off the left edge).
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The pane starts below the toolbar (the window's safe area): no
        // photo or row sits under the toolbar controls.
        let root = NSView()
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        hostView = host
        view = root
    }

    private weak var hostView: NSView?

    /// Test seam: the SwiftUI host (its frame and fitting size).
    var hostViewForTesting: NSView? { hostView }

    /// Shows `state`. The same state again publishes nothing (a rating
    /// re-sends the whole state; SwiftUI need not diff it twice).
    public func update(_ state: InspectorState) {
        guard state != stateBox.state else { return }
        stateBox.state = state
        publishCount += 1
        onPublishForTesting?(state)
    }

    /// States published so far (tests: one per click).
    private(set) var publishCount = 0
    /// Test seam: every published state.
    var onPublishForTesting: ((InspectorState) -> Void)?

    /// Test seam: what the pane shows now.
    var stateForTesting: InspectorState { stateBox.state }

    /// Test seam: the File rows alone, to render under another locale
    /// (pixel sizes are plain digits).
    static func fileInfoSectionForTesting(_ state: InspectorState) -> AnyView {
        AnyView(FileInfoSection(state: state))
    }

    /// `state` for one photo whose header read is slow:
    /// the Capture and Location rows the pane shows now, values blank, so
    /// the section keeps its place until the read fills it in.
    func keepingCaptureShape(_ state: InspectorState) -> InspectorState {
        let shown = stateBox.state
        guard state.count == 1, shown.count == 1 else { return state }
        var kept = state
        kept.capture = shown.capture.map { InspectorRow($0.label, " ") }
        kept.location = shown.location == nil ? nil : " "
        kept.coordinate = nil
        return kept
    }

    /// The "+" chip: anchors on the Tags row (the whole pane before the
    /// row has been laid out).
    func addTagTapped() {
        onAddTag?(tagsRowAnchor ?? view)
    }
}

/// `ObservableObject` bridge so SwiftUI picks up AppKit-driven state.
@MainActor
final class InspectorStateBox: ObservableObject {
    @Published var state: InspectorState = .empty
    /// Not published: read when the preview updates.
    var panelLookups: (@MainActor () -> InspectorPreviewImageView.Lookups?)?
}

// MARK: - SwiftUI

private struct InspectorRoot: View {

    @ObservedObject var state: InspectorStateBox
    let onRate: (Int) -> Void
    let onFlag: (Bool) -> Void
    let onRemoveTag: (String) -> Void
    let onAddTag: () -> Void
    let registerTagsAnchor: (NSView) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.state.count == 0, state.state.folderSummary != nil {
                    FolderHeaderSection(state: state.state)
                } else {
                    PreviewSection(state: state.state, panelLookups: state.panelLookups)
                }
                // Nothing selected: no file rows and no controls, so a
                // star click can never rate a photo that is not selected.
                if state.state.count > 0 {
                    Divider()
                    FileInfoSection(state: state.state)
                    Divider()
                    // The EXIF rows are for one item only.
                    if state.state.count == 1, !state.state.capture.isEmpty || state.state.location != nil {
                        CaptureSection(state: state.state)
                        Divider()
                    }
                    RatingSection(state: state.state, onRate: onRate, onFlag: onFlag)
                    Divider()
                    TagsSection(state: state.state, onRemoveTag: onRemoveTag, onAddTag: onAddTag,
                                registerAnchor: registerTagsAnchor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 220, maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// A folder with nothing selected is a 64 pt header and a
/// short "Folder" section, not a 212 pt box with one glyph in it.
private struct FolderHeaderSection: View {
    let state: InspectorState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.commonName ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = state.folderSummary {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 64)
            Text("Folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let path = state.folderPath {
                row("Path", path, selectable: true)
            }
            if let summary = state.folderSummary {
                row("Items", summary, selectable: false)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String, selectable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if selectable {
                Text(value)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct PreviewSection: View {
    let state: InspectorState
    let panelLookups: (@MainActor () -> InspectorPreviewImageView.Lookups?)?
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.4))
                if let url = state.previewURL {
                    PreviewImageView(url: url, lookups: panelLookups?())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: state.folderSummary != nil ? "folder" : "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)

            if state.count == 0, let summary = state.folderSummary {
                Text(state.commonName ?? "")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.count == 0 {
                Text("No selection")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if state.count > 1 {
                Text(InspectorState.multipleHeader(state.count))
                    .font(.callout.weight(.medium))
            } else if let name = state.commonName {
                // Fixed heights (two name lines, one "Also" line, used or
                // not): the rows below never move between two photos.
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                // "Also: DSC_0042.ORF (24.1 MB)".
                Text(state.alsoLine ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// The preview photo, aspect-fit inside the 180 pt box.
private struct PreviewImageView: NSViewRepresentable {
    let url: URL
    let lookups: InspectorPreviewImageView.Lookups?
    func makeNSView(context: Context) -> InspectorPreviewImageView {
        let v = InspectorPreviewImageView()
        v.show(url, lookups: lookups)
        return v
    }
    func updateNSView(_ nsView: InspectorPreviewImageView, context: Context) {
        nsView.show(url, lookups: lookups)
    }
}

/// An image view with no size of its own: the box sizes it. A plain
/// `NSImageView` asks for the photo's full pixel size (5184 × 3888), which
/// made the pane as wide as the photo and pushed the rows off the left
/// edge. The picture is an ImageIO thumbnail read off the main thread
/// (about 2x the box, never a full decode); a result for an older
/// selection is dropped.
///
/// A new photo never blanks the box, and a sharp picture is never
/// replaced by a blurry one when that can be avoided:
/// - The sharp picture is in memory (read ahead for the next and the
///   previous photo): it is shown at once, in the same frame.
/// - It is not: the PREVIOUS sharp picture stays for up to `standInDelay`
///   (150 ms). A fast read lands inside that time with no swap at all.
///   A slow one first shows the grid's small thumbnail as a stand-in
///   (when it is in memory), then the sharp picture, with no fade.
/// - With no sharp picture to hold (the first photo, or the last one was
///   itself a stand-in) the stand-in shows without the wait.
final class InspectorPreviewImageView: NSImageView {

    /// The grid's thumbnail of a file when it is in memory (no decode),
    /// or nil. Runs off the main thread.
    typealias QuickThumbnail = @Sendable (URL) -> CGImage?

    /// Where the pictures come from. Nil members fall back: no stand-in,
    /// no memory lookup, a plain ImageIO read.
    struct Lookups: Sendable {
        /// The small stand-in (the grid's or the strip's thumbnail).
        var quick: QuickThumbnail?
        /// The sharp picture, only if it is in memory (no decode).
        var cachedSharp: QuickThumbnail?
        /// The sharp picture, from the cache or a fresh read.
        var loadSharp: (@Sendable (URL) async -> CGImage?)?

        init(quick: QuickThumbnail? = nil, cachedSharp: QuickThumbnail? = nil,
             loadSharp: (@Sendable (URL) async -> CGImage?)? = nil) {
            self.quick = quick
            self.cachedSharp = cachedSharp
            self.loadSharp = loadSharp
        }
    }

    /// Longest side of the preview read, in pixels (2x a 360 pt pane).
    static let maxPixelSize = 720
    /// How long the previous sharp picture is held before the stand-in shows.
    static let defaultStandInDelay: Duration = .milliseconds(150)
    var standInDelay: Duration = InspectorPreviewImageView.defaultStandInDelay
    private(set) var shownURL: URL?
    /// The photo whose sharp picture is on screen.
    private(set) var sharpURL: URL?
    /// The picture on screen is a sharp one (maybe of an earlier photo).
    private var sharpOnScreen = false
    private var loadTask: Task<Void, Never>?
    private var sharpTask: Task<CGImage?, Never>?
    private(set) var standInTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.init(1), for: axis)
            setContentCompressionResistancePriority(.init(1), for: axis)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// True when the picture on screen is the sharp one of `shownURL`.
    var isShowingSharp: Bool { shownURL != nil && sharpURL == shownURL && image != nil }

    func show(_ url: URL, lookups: Lookups? = nil) {
        guard url != shownURL else { return }
        // A sharp picture (of this or an earlier photo) is on screen: hold it.
        let holding = sharpOnScreen && image != nil
        shownURL = url
        loadTask?.cancel()
        sharpTask?.cancel()
        standInTask?.cancel()
        loadTask = nil
        sharpTask = nil
        standInTask = nil

        // In memory: this frame, nothing to wait for.
        if let cg = lookups?.cachedSharp?(url) {
            showSharp(cg, for: url)
            return
        }

        let size = Self.maxPixelSize
        let quick = lookups?.quick
        let loadSharp = lookups?.loadSharp
        let sharp = Task.detached(priority: .userInitiated) { () -> CGImage? in
            if let loadSharp { return await loadSharp(url) }
            return Self.thumbnail(url, maxPixelSize: size)
        }
        sharpTask = sharp
        let delay: Duration = holding ? standInDelay : .zero
        // After the hold, a stand-in replaces the old picture (unless the
        // sharp one got there first).
        standInTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.shownURL == url, self.sharpURL != url,
                  let quick else { return }
            let cg = await Task.detached(priority: .userInitiated) { quick(url) }.value
            guard !Task.isCancelled, self.shownURL == url, self.sharpURL != url, let cg else { return }
            self.image = NSImage(cgImage: cg, size: .zero)
            self.sharpOnScreen = false
            self.quickShows += 1
        }
        loadTask = Task { @MainActor [weak self] in
            let cg = await sharp.value
            guard let self, !Task.isCancelled, self.shownURL == url else { return }
            if let cg {
                self.showSharp(cg, for: url)
            } else {
                // Not an image we can read: the stand-in if there is one,
                // never the last photo.
                await self.standInTask?.value
                guard !Task.isCancelled, self.shownURL == url else { return }
                if self.quickShownURL != url { self.image = nil; self.sharpOnScreen = false }
            }
        }
    }

    private var quickShownURL: URL?

    private func showSharp(_ cg: CGImage, for url: URL) {
        standInTask?.cancel()
        sharpURL = url
        sharpOnScreen = true
        image = NSImage(cgImage: cg, size: .zero)
    }

    /// Waits for the current read (tests).
    func waitForLoad() async {
        await loadTask?.value
        await standInTask?.value
    }

    /// Times the stand-in thumbnail was shown (tests).
    private(set) var quickShows = 0 {
        didSet { quickShownURL = shownURL }
    }

    /// Times the picture went blank while a photo was shown (tests).
    private(set) var blankings = 0

    override var image: NSImage? {
        didSet { if image == nil, oldValue != nil { blankings += 1 } }
    }

    /// Test seam: the preview view inside a hosting view.
    static func find(in root: NSView) -> InspectorPreviewImageView? {
        if let found = root as? InspectorPreviewImageView { return found }
        for sub in root.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    nonisolated static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct FileInfoSection: View {
    let state: InspectorState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Type")
                        .foregroundStyle(.secondary)
                    Text(Self.typeLabel(state.commonType))
                }
                GridRow {
                    Text("Dimensions")
                        .foregroundStyle(.secondary)
                    if let w = state.commonWidth, let h = state.commonHeight {
                        Text(verbatim: "\(w) × \(h)")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(state.totalFileSize == nil ? "Size" : "Total size")
                        .foregroundStyle(.secondary)
                    if let total = state.totalFileSize {
                        // The status bar's number and form.
                        Text(BrowserBottomBar.bytes(total))
                    } else if let size = state.commonFileSize {
                        Text(Self.byteFormatter.string(fromByteCount: size))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Modified")
                        .foregroundStyle(.secondary)
                    if let d = state.commonDate {
                        Text(Self.dateFormatter.string(from: d))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }
    private static func typeLabel(_ t: UTType?) -> String {
        guard let t else { return "—" }
        return t.localizedDescription ?? t.identifier
    }
    private static let byteFormatter: ByteCountFormatter = {
        let b = ByteCountFormatter()
        b.countStyle = .file
        b.allowedUnits = [.useKB, .useMB, .useGB]
        return b
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Capture and Location; rows with no value are absent.
private struct CaptureSection: View {
    let state: InspectorState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.capture.isEmpty {
                Text("Capture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(state.capture) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
            if let location = state.location {
                Text("Location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(location)
                    .font(.callout)
                    .textSelection(.enabled)
                if let coordinate = state.coordinate, let url = state.previewURL {
                    Button(ShowInMaps.linkTitle) { ShowInMaps.open(coordinate, file: url) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct RatingSection: View {
    let state: InspectorState
    let onRate: (Int) -> Void
    let onFlag: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rating & Flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    let fill = (state.commonRating ?? 0) >= i
                    Button {
                        onRate(i)
                    } label: {
                        Image(systemName: fill ? "star.fill" : "star")
                            .foregroundStyle(fill ? .yellow : .secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(i) star\(i == 1 ? "" : "s")")
                }
                Button {
                    onRate(0)
                } label: {
                    Text("Clear")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            if state.count > 1 && state.commonRating == nil {
                Text("— Mixed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: Binding(
                get: { state.commonFlag ?? false },
                set: { onFlag($0) }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle((state.commonFlag ?? false) ? .orange : .secondary)
                    Text("Flagged")
                }
            }
            .toggleStyle(.checkbox)
            if state.count > 1 && state.commonFlag == nil {
                Text("— Mixed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct TagsSection: View {
    let state: InspectorState
    let onRemoveTag: (String) -> Void
    let onAddTag: () -> Void
    let registerAnchor: (NSView) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            // Chips are editable — ⓧ removes the tag, "+"
            // opens the Tags popover on this row.
            FlowLayoutContainer {
                ForEach(state.tagsUnion, id: \.self) { tag in
                    TagChip(
                        label: tag,
                        emphasized: state.tagsCommon.contains(tag)
                    ) {
                        onRemoveTag(tag)
                    }
                }
                if state.count > 0 {
                    Button(action: onAddTag) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add a tag")
                    .accessibilityLabel("Add tag")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AnchorViewReporter(report: registerAnchor))
    }
}

/// Hands the AppKit view behind the Tags row to the controller, so the
/// Tags popover can anchor on it.
private struct AnchorViewReporter: NSViewRepresentable {
    let report: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        report(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct TagChip: View {
    let label: String
    let emphasized: Bool
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove “\(label)”")
            .accessibilityLabel("Remove tag \(label)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(emphasized ? Color.accentColor.opacity(0.25)
                                  : Color.secondary.opacity(0.15))
        )
        .foregroundStyle(emphasized ? .primary : .secondary)
    }
}

/// Minimal flow layout for chips — avoids pulling in `Layout` (iOS 16+) to
/// stay deployment-target safe.
private struct FlowLayoutContainer<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading) {
            content
        }
    }
}
