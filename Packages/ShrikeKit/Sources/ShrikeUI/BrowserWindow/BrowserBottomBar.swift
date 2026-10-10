//
//  BrowserBottomBar.swift
//  ShrikeUI
//
//  The Browser's bottom bar. The window draws the bar itself
//  (a 24 pt content border at the bottom); this view only lays out what
//  sits on it:
//    * leading:  the selection status (or the sort's progress);
//    * centre:   the folder's path, click a part to go there;
//    * trailing: the thumbnail-size slider (Grid mode only).
//

import AppKit
import Foundation

@MainActor
public final class BrowserBottomBar: NSView {

    public static let height: CGFloat = 24
    /// Between the controls.
    public static let sideInset: CGFloat = 8
    /// The bar's two ends, clear of the window's rounded corners:
    /// 16 pt on macOS 26, 8 pt before.
    static var cornerInset: CGFloat { WindowCornerInset.side }
    public static let sliderWidth: CGFloat = 96

    let statusField = NSTextField(labelWithString: "")
    let pathControl = NSPathControl()
    let slider: NSSlider

    /// A part of the path was clicked.
    var onNavigate: ((URL) -> Void)?

    /// The folders behind `pathControl.pathItems`, same order.
    private(set) var pathURLs: [URL] = []
    private var folder: URL?
    private var pathGeneration = 0
    private var pathTrailingToSlider: NSLayoutConstraint!
    private var pathTrailingToEdge: NSLayoutConstraint!

    init(slider: NSSlider) {
        self.slider = slider
        super.init(frame: .zero)

        statusField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.translatesAutoresizingMaskIntoConstraints = false
        // Long text truncates; it never widens the window.
        statusField.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        statusField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusField.setAccessibilityLabel("Selection")

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        pathControl.isEditable = false
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.setAccessibilityLabel("Folder path")

        slider.controlSize = .small
        slider.toolTip = "Thumbnail Size"
        slider.translatesAutoresizingMaskIntoConstraints = false

        for view in [statusField, pathControl, slider] as [NSView] { addSubview(view) }

        let centred = pathControl.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .init(240)
        pathTrailingToSlider = pathControl.trailingAnchor.constraint(
            lessThanOrEqualTo: slider.leadingAnchor, constant: -Self.sideInset
        )
        pathTrailingToEdge = pathControl.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -Self.cornerInset
        )
        // At the corner inset, or further in when the system's corner
        // measure (macOS 26) needs more room.
        let statusAtInset = statusField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.cornerInset)
        statusAtInset.priority = .defaultHigh
        let sliderAtInset = slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.cornerInset)
        sliderAtInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            statusAtInset,
            statusField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.cornerInset),
            statusField.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathControl.leadingAnchor.constraint(greaterThanOrEqualTo: statusField.trailingAnchor,
                                                 constant: Self.sideInset),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            centred,
            pathTrailingToSlider,
            sliderAtInset,
            slider.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.cornerInset),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: Self.sliderWidth),
        ])
        WindowCornerInset.clearCorners(of: statusField, in: self, leading: true, trailing: false)
        WindowCornerInset.clearCorners(of: slider, in: self, leading: false, trailing: true)
        WindowCornerInset.clearCorners(of: pathControl, in: self, leading: false, trailing: true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Browser status")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: Status

    func setStatus(_ text: String) {
        guard statusField.stringValue != text else { return }
        statusField.stringValue = text
        statusChanges += 1
    }

    /// Times the status text changed (tests: once per click).
    private(set) var statusChanges = 0

    /// One selected: "DSC_0042.jpg · 6000 × 4000 · 12.4 MB" (the size only
    /// when known); several: "3 selected · 48.2 MB"; none: empty.
    /// `headerSize`: the size a header read found for one item whose
    /// listing has none (JPEG / PNG).
    nonisolated static func statusText(_ selected: [BrowserItem], headerSize: (width: Int, height: Int)? = nil) -> String {
        switch selected.count {
        case 0:
            return ""
        case 1:
            let item = selected[0]
            var parts = [item.displayName]
            if let w = item.pixelWidth ?? headerSize?.width, let h = item.pixelHeight ?? headerSize?.height,
               w > 0, h > 0 {
                parts.append("\(w) × \(h)")
            }
            parts.append(bytes(item.fileSize))
            return parts.joined(separator: " · ")
        default:
            let total = selected.reduce(Int64(0)) { $0 + $1.fileSize }
            return "\(selected.count) selected · \(bytes(total))"
        }
    }

    /// "Sorting by Date Captured… 1,500 of 5,000".
    nonisolated static func sortingText(key: String, done: Int, total: Int) -> String {
        "Sorting by \(key)… \(grouped(done)) of \(grouped(total))"
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    nonisolated static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    // MARK: Slider

    func setSliderHidden(_ hidden: Bool) {
        slider.isHidden = hidden
        pathTrailingToSlider.isActive = !hidden
        pathTrailingToEdge.isActive = hidden
    }

    // MARK: Path

    /// Shows `url`'s path at once from its name parts, then swaps in the
    /// Finder names ("Macintosh HD", localized folders) read off the main
    /// thread.
    func setFolder(_ url: URL?) {
        let std = url?.standardizedFileURL
        guard std != folder else { return }
        folder = std
        pathGeneration &+= 1
        guard let std else {
            apply([])
            return
        }
        apply(Self.quickEntries(for: std))
        let generation = pathGeneration
        Task { [weak self] in
            let entries = await Task.detached(priority: .utility) { Self.finderEntries(for: std) }.value
            guard let self, self.pathGeneration == generation else { return }
            self.apply(entries)
        }
    }

    struct PathEntry: Sendable, Equatable {
        let title: String
        let url: URL
        let isVolume: Bool
    }

    /// From "/" down to `folder`, named by the path's own parts.
    nonisolated static func quickEntries(for folder: URL) -> [PathEntry] {
        var entries: [PathEntry] = []
        var url = folder
        while true {
            let isRoot = url.path == "/"
            entries.append(PathEntry(title: isRoot ? "/" : url.lastPathComponent, url: url, isVolume: isRoot))
            if isRoot { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return entries.reversed()
    }

    /// From the folder's volume down to `folder`, with Finder names.
    /// Touches the disk: call off the main thread.
    nonisolated static func finderEntries(for folder: URL) -> [PathEntry] {
        var entries: [PathEntry] = []
        var url = folder
        let fm = FileManager.default
        while true {
            let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? (url.path == "/")
            entries.append(PathEntry(title: fm.displayName(atPath: url.path), url: url, isVolume: isVolume))
            if isVolume || url.path == "/" { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return entries.reversed()
    }

    private func apply(_ entries: [PathEntry]) {
        let folderIcon = NSImage(named: NSImage.folderName)
        let volumeIcon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        pathControl.pathItems = entries.map { entry in
            let item = NSPathControlItem()
            item.title = entry.title
            item.image = entry.isVolume ? volumeIcon : folderIcon
            return item
        }
        pathURLs = entries.map(\.url)
        pathControl.toolTip = folder?.path
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clicked) else { return }
        navigate(toPathIndex: index)
    }

    /// Goes to the folder behind path part `index` (tests call this).
    func navigate(toPathIndex index: Int) {
        guard pathURLs.indices.contains(index) else { return }
        let url = pathURLs[index]
        guard url != folder else { return }
        onNavigate?(url)
    }
}
