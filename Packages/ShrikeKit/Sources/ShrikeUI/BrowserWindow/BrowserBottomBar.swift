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
import ShrikeCore
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
    let pathControl = CrumbPathControl()
    let slider: NSSlider

    /// A part of the path was clicked.
    var onNavigate: ((URL) -> Void)?

    /// The whole chain of folders, volume first. When the bar is too narrow
    /// `pathControl` shows only some of them (`shownSlots`).
    private(set) var pathURLs: [URL] = []
    private var entries: [PathEntry] = []
    /// What each item of `pathControl.pathItems` stands for, same order.
    private(set) var shownSlots: [PathCrumbFit.Slot] = []
    private var fittedRoom: CGFloat?
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
        pathControl.onMouseDown = { [weak self] point in
            guard let self, let crumb = self.hiddenCrumb, crumb.rect.contains(point) else { return false }
            self.showHiddenFolders()
            return true
        }

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

    /// The folders from "/" down to `folder` as the file system lists them:
    /// under `/tmp`, `/var` and `/etc` the chain goes through
    /// the real `/private` folder, as the sidebar tree does. Pure.
    nonisolated static func chainURLs(for folder: URL) -> [URL] {
        let parts = FolderTreeDataSource.lookupComponents(folder)
        var urls: [URL] = []
        var path = ""
        for part in parts {
            path = part == "/" ? "/" : (path == "/" ? "/" + part : path + "/" + part)
            urls.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return urls
    }

    /// From "/" down to `folder`, named by the path's own parts.
    nonisolated static func quickEntries(for folder: URL) -> [PathEntry] {
        chainURLs(for: folder).map { url in
            let isRoot = url.path == "/"
            return PathEntry(title: isRoot ? "/" : url.lastPathComponent, url: url, isVolume: isRoot)
        }
    }

    /// From the folder's volume down to `folder`, with Finder names.
    /// Touches the disk: call off the main thread.
    nonisolated static func finderEntries(for folder: URL) -> [PathEntry] {
        let fm = FileManager.default
        let all = chainURLs(for: folder).map { url -> PathEntry in
            let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? (url.path == "/")
            return PathEntry(title: fm.displayName(atPath: url.path), url: url, isVolume: isVolume)
        }
        // The deepest volume root starts the shown chain.
        let start = all.lastIndex(where: \.isVolume) ?? 0
        return Array(all[start...])
    }

    private func apply(_ entries: [PathEntry]) {
        self.entries = entries
        pathURLs = entries.map(\.url)
        pathControl.toolTip = folder?.path
        fittedRoom = nil
        shownSlots = []
        show(entries.indices.map(PathCrumbFit.Slot.crumb))
        if bounds.width > 0 { needsLayout = true }
    }

    private func show(_ slots: [PathCrumbFit.Slot]) {
        guard slots != shownSlots || pathControl.pathItems.count != slots.count else { return }
        let folderIcon = NSImage(named: NSImage.folderName)
        let volumeIcon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        shownSlots = slots
        pathControl.pathItems = slots.map { slot in
            let item = NSPathControlItem()
            switch slot {
            case .crumb(let i):
                // The full name: the control itself cuts only what still does not fit.
                item.title = entries[i].title
                item.image = entries[i].isVolume ? volumeIcon : folderIcon
            case .hidden:
                item.title = PathCrumbFit.ellipsis
            }
            return item
        }
    }

    public override func layout() {
        super.layout()
        fitPath()
    }

    /// The room between the status text and the slider (or the edge).
    private var pathRoom: CGFloat {
        let right = slider.isHidden ? bounds.maxX - Self.cornerInset : slider.frame.minX - Self.sideInset
        return (right - statusField.frame.maxX - Self.sideInset).rounded(.down)
    }

    /// Shows as many crumbs as fit in full: first, `…`, then the trailing ones.
    /// Items are replaced only when the chosen crumbs change.
    private func fitPath() {
        let room = pathRoom
        guard room > 0, entries.count > 2, room != fittedRoom else { return }
        fittedRoom = room
        let font = pathControl.font ?? .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        func width(_ title: String) -> CGFloat {
            (title as NSString).size(withAttributes: [.font: font]).width + PathCrumbFit.crumbChrome
        }
        let widths = entries.map { width($0.title) }
        var budget = room
        for _ in 0..<4 {
            show(PathCrumbFit.slots(widths: widths, ellipsis: width(PathCrumbFit.ellipsis), available: budget))
            // The estimate is checked against the control's own measure.
            let over = pathControl.intrinsicContentSize.width - room
            guard over > 0, shownSlots.count > 1 else { break }
            budget -= over
        }
    }

    /// The menu of the `…` crumb: the hidden folders, top first; each goes there.
    func hiddenFoldersMenu(_ range: ClosedRange<Int>) -> NSMenu {
        let menu = NSMenu()
        for i in range where entries.indices.contains(i) {
            let item = NSMenuItem(title: entries[i].title, action: #selector(hiddenFolderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entries[i].url   // a path rebuilt under the open menu cannot change it
            item.image = NSImage(named: NSImage.folderName)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        return menu
    }

    @objc func hiddenFolderChosen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { navigate(to: url) }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clicked),
              shownSlots.indices.contains(index) else { return }
        switch shownSlots[index] {
        case .crumb(let i):
            navigate(toPathIndex: i)
        case .hidden:
            showHiddenFolders()
        }
    }

    /// Tests put a stand-in here: a real pop-up menu blocks until it closes.
    var presentMenuForTesting: ((NSMenu) -> Void)?

    /// The `…` crumb's slot index and its rect in `pathControl`, if shown.
    private var hiddenCrumb: (range: ClosedRange<Int>, rect: NSRect)? {
        guard let index = shownSlots.firstIndex(where: { if case .hidden = $0 { return true }; return false }),
              case .hidden(let range) = shownSlots[index], let cell = pathControl.cell as? NSPathCell,
              cell.pathComponentCells.indices.contains(index) else { return nil }
        return (range, cell.rect(of: cell.pathComponentCells[index], withFrame: pathControl.bounds, in: pathControl))
    }

    /// The hidden folders' menu under the `…` crumb: a click and VoiceOver's press both come here.
    func showHiddenFolders() {
        guard let crumb = hiddenCrumb else { return }
        let menu = hiddenFoldersMenu(crumb.range)
        if let present = presentMenuForTesting { return present(menu) }
        menu.popUp(positioning: nil, at: NSPoint(x: crumb.rect.minX, y: pathControl.bounds.maxY), in: pathControl)
    }

    /// AppKit's own `…` crumb offers VoiceOver no press and no menu, so a
    /// button stands next to the path while folders are hidden.
    private lazy var hiddenCrumbElement: HiddenCrumbElement = {
        let element = HiddenCrumbElement(
            label: { [weak self] in self?.hiddenCrumbLabel },
            frame: { [weak self] in self?.hiddenCrumbScreenRect ?? .zero },
            press: { [weak self] in
                guard let self, self.hiddenCrumb != nil else { return false }
                // The menu blocks while open: answer the press first, open on the next turn.
                DispatchQueue.main.async { [weak self] in self?.showHiddenFolders() }
                return true
            })
        element.setAccessibilityParent(self)
        return element
    }()

    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard hiddenCrumb != nil else { return children }
        let at = children.firstIndex { ($0 as AnyObject) === pathControl.cell || ($0 as AnyObject) === pathControl }
        children.insert(hiddenCrumbElement, at: at.map { $0 + 1 } ?? children.count)
        return children
    }

    nonisolated static func hiddenFoldersLabel(_ count: Int) -> String {
        count == 1 ? "1 hidden folder" : "\(count) hidden folders"
    }

    fileprivate var hiddenCrumbLabel: String? { hiddenCrumb.map { Self.hiddenFoldersLabel($0.range.count) } }
    fileprivate var hiddenCrumbScreenRect: NSRect {
        guard let crumb = hiddenCrumb else { return .zero }
        return NSAccessibility.screenRect(fromView: pathControl, rect: crumb.rect)
    }

    /// Goes to the folder behind path part `index` (tests call this).
    func navigate(toPathIndex index: Int) {
        guard pathURLs.indices.contains(index) else { return }
        navigate(to: pathURLs[index])
    }

    private func navigate(to url: URL) {
        // The chain is written through `/private` while the
        // browser keeps its own spelling (`/tmp/…`): the shown folder is
        // compared by canonical path, so its own crumb never re-navigates.
        if let folder, CanonicalPath.of(url) == CanonicalPath.of(folder) { return }
        onNavigate?(url)
    }
}

/// The path control; a click on the `…` crumb opens the bar's menu at once
/// (the control's own click on it was never seen to ask for one).
@MainActor
final class CrumbPathControl: NSPathControl {
    var onMouseDown: ((NSPoint) -> Bool)?
    override func mouseDown(with event: NSEvent) {
        if onMouseDown?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }
}

/// VoiceOver's button for the `…` crumb; label and place follow the bar's crumbs.
final class HiddenCrumbElement: NSAccessibilityElement {
    private let label: @MainActor @Sendable () -> String?
    private let frame: @MainActor @Sendable () -> NSRect
    private let press: @MainActor @Sendable () -> Bool
    init(label: @escaping @MainActor @Sendable () -> String?, frame: @escaping @MainActor @Sendable () -> NSRect,
         press: @escaping @MainActor @Sendable () -> Bool) {
        self.label = label
        self.frame = frame
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        // A plain element reports AXEnabled false: VoiceOver would read "dimmed".
        setAccessibilityEnabled(true)
    }
    // Accessibility asks on the main thread.
    override func accessibilityLabel() -> String? { let label = label; return MainActor.assumeIsolated { label() } }
    override func accessibilityFrame() -> NSRect { let frame = frame; return MainActor.assumeIsolated { frame() } }
    override func accessibilityPerformPress() -> Bool { let press = press; return MainActor.assumeIsolated { press() } }
}

/// Which crumbs of a long path fit the bottom bar. Pure.
enum PathCrumbFit {
    enum Slot: Equatable {
        /// One folder of the chain, by its index there.
        case crumb(Int)
        /// One `…` crumb for these folders.
        case hidden(ClosedRange<Int>)
    }

    static let ellipsis = "…"
    /// Icon, spacing and the separator chevron around a crumb's title.
    static let crumbChrome: CGFloat = 34

    /// All crumbs when they fit (or `available` is not known yet, or there
    /// are only two). Else the first, `…`, and as many trailing crumbs as fit,
    /// the last (the current folder) always. Narrower still: `…` and the last,
    /// then the last alone.
    static func slots(widths: [CGFloat], ellipsis: CGFloat, available: CGFloat) -> [Slot] {
        let n = widths.count
        let all = (0..<n).map(Slot.crumb)
        guard available > 0, n > 2, widths.reduce(0, +) > available else { return all }
        let last = widths[n - 1]
        guard widths[0] + ellipsis + last <= available else {
            return ellipsis + last <= available ? [.hidden(0...(n - 2)), .crumb(n - 1)] : [.crumb(n - 1)]
        }
        var used = widths[0] + ellipsis + last
        var firstTrailing = n - 1
        while firstTrailing - 1 > 1, used + widths[firstTrailing - 1] <= available {
            firstTrailing -= 1
            used += widths[firstTrailing]
        }
        return [.crumb(0), .hidden(1...(firstTrailing - 1))] + (firstTrailing..<n).map(Slot.crumb)
    }
}
