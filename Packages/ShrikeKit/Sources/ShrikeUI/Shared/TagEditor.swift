//
//  TagEditor.swift
//  ShrikeUI
//
//  Finder tags, the write side, shared by the viewer and
//  the Browser:
//
//  * `TagEditSession` — one popover session over one or more groups.
//    Writes at once (each toggle, each token add / remove) to the primary
//    and its RAW files (never sidecars or the MOV), and registers ONE undo
//    step "Tags" on the first change. Undo puts back the tags read when
//    the session opened; redo puts back the tags read at undo time.
//  * `TagsPopoverController` — 280 pt popover: 7 colour toggles (20 pt
//    circles, 8 pt apart) over an `NSTokenField` (260 pt, "Add a tag…").
//
//  Tags are extended attributes. Writes go through one serial queue off
//  the main actor, so their order always follows the order of clicks. The
//  popover reads the files' tags off the main actor too: until they arrive
//  its dots are off and disabled, so a click cannot race the read.
//

import AppKit
import ShrikeCore
import ShrikeIO

// MARK: - Session

@MainActor
final class TagEditSession {

    let groups: [ImageGroup]
    /// Red … Gray with the user's names, Finder's menu order.
    let colorTags: [FinderTag]
    /// Tags of every written file when the session opened.
    private(set) var before: [URL: [String]]
    /// False while the tags are still being read; edits are refused then.
    private(set) var isLoaded = true
    /// Runs once the tags read off the main actor have arrived.
    var onLoad: (() -> Void)?
    /// Reads the tags of `urls` off the main actor.
    typealias Reader = @Sendable ([URL]) async -> [URL: [String]]
    static let readOffMain: Reader = { urls in
        await Task.detached(priority: .userInitiated) {
            var tags: [URL: [String]] = [:]
            for url in urls { tags[url] = FinderTags.read(url) }
            return tags
        }.value
    }
    /// The optimistic model: what the files hold once the
    /// queued writes land. Shared with the undo steps, which outlive the
    /// session.
    private let ledger: TagLedger
    private(set) var current: [URL: [String]] {
        get { ledger.tags }
        set { ledger.tags = newValue }
    }
    private weak var undoManager: UndoManager?
    private(set) var didRegisterUndo = false
    /// Primaries whose tags changed (also after undo / redo).
    let onChange: @MainActor ([URL]) -> Void
    /// A "Couldn't …" toast line.
    let onError: @MainActor (String) -> Void
    /// The watchers that ignore this session's writes (the window's own and
    /// its partner's). Other windows' watchers report the xattr change, so
    /// their tag badges follow. nil ignores nothing.
    let suppressing: (any FolderChangeSuppressing)?

    /// Names used this launch, offered by the token field.
    static var recentTags: [String] = []

    init(groups: [ImageGroup], colorTags: [FinderTag]? = nil, undoManager: UndoManager?,
         onChange: @escaping @MainActor ([URL]) -> Void,
         onError: @escaping @MainActor (String) -> Void,
         suppressing: (any FolderChangeSuppressing)? = nil, read: Reader? = nil) {
        self.suppressing = suppressing
        self.groups = groups
        self.colorTags = colorTags ?? FinderTags.knownTags()
        self.undoManager = undoManager
        self.onChange = onChange
        self.onError = onError
        let urls = Culling.imageURLs(of: groups)
        guard let read else {
            var tags: [URL: [String]] = [:]
            for url in urls { tags[url] = FinderTags.read(url) }
            before = tags
            ledger = TagLedger(tags)
            return
        }
        before = [:]
        ledger = TagLedger([:])
        isLoaded = false
        Task { [weak self] in
            let tags = await read(urls)
            guard let self else { return }
            self.before = tags
            self.ledger.tags = tags
            self.isLoaded = true
            self.onLoad?()
        }
    }

    /// Writes go through `FinderTagWriter` (serial, in call order, off
    /// main). Failures come back as the usual toast, on main.
    /// `landed` runs on main once the writes are on disk (the pill and
    /// the grid re-read the tags then).
    static func enqueue(_ edits: [FinderTagEdit], suppressing: (any FolderChangeSuppressing)? = nil,
                        onError: @escaping @MainActor (String) -> Void,
                        landed: @escaping @MainActor () -> Void) {
        guard !edits.isEmpty else { return }
        // Finder tags are extended attributes; the
        // cells update through `landed`, not through the folder watcher.
        suppressing?.ignore(paths: edits.map(\.url), for: .seconds(2))
        FinderTagWriter.shared.enqueue(edits) { result in
            let failed = result.failedURLs
            Task { @MainActor in
                for url in failed { onError(failure(url)) }
                landed()
            }
        }
    }

    /// Tags every group's primary has (the first group's order).
    var commonTags: [String] {
        guard let first = groups.first else { return [] }
        let firstTags = current[first.primary] ?? []
        return firstTags.filter { name in
            groups.dropFirst().allSatisfy { Self.has(name, in: current[$0.primary] ?? []) }
        }
    }

    /// `.on` = every group has it, `.mixed` = some, `.off` = none.
    func state(of color: FinderTag) -> NSControl.StateValue {
        let count = groups.filter { Self.has(color.name, in: current[$0.primary] ?? []) }.count
        if count == 0 { return .off }
        return count == groups.count ? .on : .mixed
    }

    /// A click on a colour: sets it on all unless all have it.
    func toggle(_ color: FinderTag) {
        if state(of: color) == .on {
            remove([color.name])
        } else {
            add([color.name])
        }
    }

    func add(_ names: [String]) {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        for name in clean where !Self.has(name, in: Self.recentTags) { Self.recentTags.append(name) }
        apply { tags in
            var out = tags
            for name in clean where !Self.has(name, in: out) { out.append(name) }
            return out
        }
    }

    func remove(_ names: [String]) {
        let drop = Set(names.map { $0.lowercased() })
        guard !drop.isEmpty else { return }
        apply { $0.filter { !drop.contains($0.lowercased()) } }
    }

    private func apply(_ change: ([String]) -> [String]) {
        guard isLoaded else { return }
        var changedPrimaries: [URL] = []
        var edits: [FinderTagEdit] = []
        for group in groups {
            for url in Culling.imageURLs(of: group) {
                let old = current[url] ?? []
                let new = change(old)
                guard new != old else { continue }
                edits.append(FinderTagEdit(url: url, change: .set(new)))
                current[url] = new
                if !changedPrimaries.contains(group.primary) { changedPrimaries.append(group.primary) }
            }
        }
        guard !changedPrimaries.isEmpty else { return }
        let onChange = onChange
        Self.enqueue(edits, suppressing: suppressing, onError: onError) { onChange(changedPrimaries) }
        registerUndoIfNeeded()
    }

    private func registerUndoIfNeeded() {
        guard !didRegisterUndo, let undoManager else { return }
        didRegisterUndo = true
        Self.registerRestore(before, primaries: groups.map(\.primary), ledger: ledger,
                             manager: undoManager, onChange: onChange, onError: onError,
                             suppressing: suppressing)
    }

    /// Undo / redo: write `snapshot` back and register the opposite step.
    private static func registerRestore(
        _ snapshot: [URL: [String]], primaries: [URL], ledger: TagLedger, manager: UndoManager,
        onChange: @escaping @MainActor ([URL]) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        suppressing: (any FolderChangeSuppressing)?
    ) {
        let box = UndoBox()
        // NSUndoManager does not retain its target: the handler holds it.
        manager.registerUndo(withTarget: box) { [box, weak manager] _ in
            _ = box
            MainActor.assumeIsolated {
                var now: [URL: [String]] = [:]
                var edits: [FinderTagEdit] = []
                for (url, tags) in snapshot.sorted(by: { $0.key.path < $1.key.path }) {
                    now[url] = ledger.tags[url] ?? []
                    ledger.tags[url] = tags
                    edits.append(FinderTagEdit(url: url, change: .set(tags)))
                }
                enqueue(edits, suppressing: suppressing, onError: onError) { onChange(primaries) }
                if let manager {
                    registerRestore(now, primaries: primaries, ledger: ledger, manager: manager,
                                    onChange: onChange, onError: onError, suppressing: suppressing)
                }
            }
        }
        manager.setActionName("Tags")
    }

    private final class UndoBox {}

    /// The optimistic tag model shared by a session and its undo steps.
    final class TagLedger {
        var tags: [URL: [String]]
        init(_ tags: [URL: [String]]) { self.tags = tags }
    }

    static func failure(_ url: URL) -> String {
        "Couldn't change the tags of “\(url.lastPathComponent)”."
    }

    static func has(_ name: String, in tags: [String]) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Names offered while typing: Finder's tags + this launch's, minus
    /// the ones already on the files.
    func completions(for prefix: String) -> [String] {
        let all = FinderTags.allUserTags().map(\.name) + Self.recentTags
        var seen = Set<String>()
        let taken = Set(commonTags.map { $0.lowercased() })
        return all.filter { name in
            let key = name.lowercased()
            guard !taken.contains(key), seen.insert(key).inserted else { return false }
            return prefix.isEmpty || name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }
}

// MARK: - Colour toggle

/// What one colour dot says. Pure.
struct TagDotModel: Equatable {
    let name: String
    let color: FinderTagColor
    let state: NSControl.StateValue
    /// `Red · add` / `Red · remove` (mixed: add, a click sets it on all).
    var toolTip: String { "\(name) · \(state == .on ? "remove" : "add")" }
    /// VoiceOver: the name, a checkbox, `on` / `off` (`mixed` when only some photos have it).
    var accessibilityValue: String {
        switch state { case .on: "on"; case .mixed: "mixed"; default: "off" }
    }
    /// The check mark is white, dark on the light Gray dot.
    var checkIsDark: Bool { color == .gray }
    static let dotDiameter: CGFloat = 18
    static let hitSize: CGFloat = 24
    static let ringWidth: CGFloat = 1.5

    /// The system tag colours at full strength (never blended).
    static func fill(_ color: FinderTagColor) -> NSColor {
        switch color {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray, .none: .systemGray
        }
    }

    /// The 1 pt edge of every dot: its colour 35 % toward black, so even the
    /// light Yellow dot has a visible edge on a light popover.
    static func edge(_ color: FinderTagColor) -> NSColor {
        fill(color).blended(withFraction: 0.35, of: .black) ?? fill(color)
    }
}

/// An 18 pt tag colour dot in a 24 pt hit area: on = filled, a 1.5 pt ring and a check
/// mark; half filled when some photos have it. Tab reaches it, Space toggles.
final class TagColorToggle: NSButton {

    let tag0: FinderTag

    init(tag: FinderTag) {
        self.tag0 = tag
        super.init(frame: NSRect(x: 0, y: 0, width: TagDotModel.hitSize, height: TagDotModel.hitSize))
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        allowsMixedState = true
        focusRingType = .exterior
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(tag.name)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TagDotModel.hitSize),
            heightAnchor.constraint(equalToConstant: TagDotModel.hitSize),
        ])
        refreshModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var model: TagDotModel { TagDotModel(name: tag0.name, color: tag0.color, state: state) }
    override var state: NSControl.StateValue { didSet { refreshModel() } }
    private func refreshModel() { toolTip = model.toolTip; needsDisplay = true }

    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: dotRect.insetBy(dx: -3, dy: -3)).fill() }

    private var dotRect: CGRect {
        let d = TagDotModel.dotDiameter
        return CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = TagDotModel.fill(tag0.color)
        let circle = dotRect
        let path = NSBezierPath(ovalIn: circle)
        // Full strength in every state; the state is told by the
        // ring and the check (on) or a dash (mixed), not by paleness.
        color.setFill()
        path.fill()
        switch state {
        case .on:
            NSColor.labelColor.setStroke()
            let w = TagDotModel.ringWidth
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -(w / 2 + 1), dy: -(w / 2 + 1)))
            ring.lineWidth = w
            ring.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(.init(paletteColors: [model.checkIsDark ? NSColor.black.withAlphaComponent(0.8) : .white]))
            if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = check.size
                check.draw(in: CGRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
        case .mixed:
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                .applying(.init(paletteColors: [model.checkIsDark ? NSColor.black.withAlphaComponent(0.8) : .white]))
            if let dash = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = dash.size
                dash.draw(in: CGRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                     width: size.width, height: size.height))
            }
        default:
            break
        }
        TagDotModel.edge(tag0.color).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func accessibilityValue() -> Any? { model.accessibilityValue }
}

/// Where the Tags popover opens. Pure; all rects in one top-left space
/// (y grows down). Below the anchor, else right, else above; the popover's top never goes
/// above `content.minY + 4` (the window's content top, under the title bar).
enum TagsPopoverPlacement {
    enum Side: Equatable { case below, right, above }
    static let arrow: CGFloat = 13
    static let titleGap: CGFloat = 4

    static func place(anchor: CGRect, popover: CGSize, content: CGRect) -> (side: Side, anchor: CGRect) {
        let top = content.minY + titleGap
        if anchor.maxY + arrow + popover.height <= content.maxY {
            var a = anchor
            if a.maxY < top { a.origin.y += top - a.maxY }   // anchor under the title bar
            return (.below, a)
        }
        if anchor.maxX + arrow + popover.width <= content.maxX {
            var a = anchor
            let popTop = a.midY - popover.height / 2
            if popTop < top { a.origin.y += top - popTop }
            return (.right, a)
        }
        if anchor.minY - arrow - popover.height >= top { return (.above, anchor) }
        // Nothing fits: below, pulled up to fit the content bottom but never over the title bar.
        var a = anchor
        let over = a.maxY + arrow + popover.height - content.maxY
        a.origin.y = max(top - a.height, a.origin.y - over)
        return (.below, a)
    }

    /// The `NSRectEdge` meaning `side` in a view with the given `isFlipped`.
    static func edge(_ side: Side, flipped: Bool) -> NSRectEdge {
        switch side {
        case .below: flipped ? .maxY : .minY
        case .above: flipped ? .minY : .maxY
        case .right: .maxX
        }
    }
}

// MARK: - Popover

@MainActor
final class TagsPopoverController: NSViewController, NSTokenFieldDelegate, NSPopoverDelegate {

    let session: TagEditSession
    private(set) var toggles: [TagColorToggle] = []
    let tokenField = NSTokenField()
    private(set) var heading: NSTextField?
    // Strong while shown; released in `popoverDidClose`.
    private var popover: NSPopover?

    init(session: TagEditSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Opaque: the dots are never blended with what is behind.
        let root = OpaquePopoverBackground(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        root.wantsLayer = true
        let heading = NSTextField(labelWithString: "Tags")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        heading.translatesAutoresizingMaskIntoConstraints = false
        self.heading = heading
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        for tag in session.colorTags {
            let toggle = TagColorToggle(tag: tag)
            toggle.target = self
            toggle.action = #selector(toggleColor(_:))
            toggles.append(toggle)
            row.addArrangedSubview(toggle)
        }
        tokenField.delegate = self
        tokenField.placeholderString = "Add a tag…"
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tokenField.setAccessibilityLabel("Tags")
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(heading)
        root.addSubview(row)
        root.addSubview(tokenField)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            row.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tokenField.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 12),
            tokenField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tokenField.widthAnchor.constraint(equalToConstant: 260),
            tokenField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = root
        session.onLoad = { [weak self] in
            guard let self else { return }
            self.syncFromSession()
            // The field was disabled at open, so it could not take the focus then.
            self.view.window?.makeFirstResponder(self.tokenField)
        }
        syncFromSession()
    }

    /// Below `rect` of `anchor` (the selected cell, the photo's centre), else
    /// right, else above, never over the title bar (`TagsPopoverPlacement`).
    func present(below rect: NSRect, of anchor: NSView) {
        let stable = Self.stableAnchor(rect, of: anchor)
        let placed = Self.placement(for: stable.rect, in: stable.view, popover: view.fittingSize)
        present(relativeTo: placed.rect, of: stable.view, edge: placed.edge)
    }

    /// `rect` in `view`, placed through `TagsPopoverPlacement` in the window's content
    /// layout rect (converted to top-left and back). Shared with tests.
    static func placement(for rect: NSRect, in view: NSView, popover: NSSize) -> (rect: NSRect, edge: NSRectEdge, side: TagsPopoverPlacement.Side) {
        let h = view.bounds.height
        func topLeft(_ r: NSRect) -> NSRect { view.isFlipped ? r : NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        let contentInView: NSRect = view.window.map { view.convert($0.contentLayoutRect, from: nil) } ?? view.bounds
        let content = topLeft(contentInView.intersection(view.bounds).isEmpty ? view.bounds : contentInView.intersection(view.bounds))
        let placed = TagsPopoverPlacement.place(anchor: topLeft(rect), popover: popover, content: content)
        return (topLeft(placed.anchor), TagsPopoverPlacement.edge(placed.side, flipped: view.isFlipped), placed.side)
    }

    override func cancelOperation(_ sender: Any?) { popover?.performClose(sender) }

    /// Shows the popover next to `anchor` with a fixed edge (the inspector's Tags row).
    func present(relativeTo rect: NSRect, of anchor: NSView, edge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = self
        popover.delegate = self
        // A popover from the always-dark viewer is dark too (nil elsewhere: follows the app).
        popover.appearance = anchor.window?.appearance
        self.popover = popover
        let stable = Self.stableAnchor(rect, of: anchor)
        popover.show(relativeTo: stable.rect, of: stable.view, preferredEdge: edge)
        view.window?.makeFirstResponder(tokenField)
    }

    /// (only Esc, or Return on an empty field, closes).
    /// A popover closes at once when its positioning view leaves the
    /// window or hides, and each colour click did that: the tag change
    /// reloads the Browser's selected cell and the inspector row, and the
    /// viewer's pill auto-hides after its marks flash. So the popover is
    /// positioned on the window's content view, at the anchor's place.
    static func stableAnchor(_ rect: NSRect, of anchor: NSView) -> (view: NSView, rect: NSRect) {
        guard let content = anchor.window?.contentView, content !== anchor,
              anchor.isDescendant(of: content) else { return (anchor, rect) }
        return (content, content.convert(rect, from: anchor))
    }

    func syncFromSession() {
        for toggle in toggles {
            toggle.state = session.isLoaded ? session.state(of: toggle.tag0) : .off
            toggle.isEnabled = session.isLoaded
        }
        tokenField.isEnabled = session.isLoaded
        tokenField.objectValue = session.commonTags
        placeCaretAfterLastToken()
    }

    /// Setting `objectValue` while the field is being edited leaves ALL its tokens
    /// selected, so the next typed tag replaced the colour tag the user had just
    /// clicked. The insertion point goes after the last token.
    private func placeCaretAfterLastToken() {
        guard let editor = tokenField.currentEditor() as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }

    @objc func toggleColor(_ sender: TagColorToggle) {
        session.toggle(sender.tag0)
        syncFromSession()
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    // MARK: NSTokenFieldDelegate

    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        // objectValue can already include the proposal as plain text. Only
        // attachment-backed objects are committed tokens in the active editor.
        var represented = tokenField.objectValue as? [Any] ?? []
        if let editor = tokenField.currentEditor() as? NSTextView,
           editor.delegate === tokenField, editor.window === tokenField.window,
           let storage = editor.textStorage {
            var committedCount = 0
            var pendingIndex: Int?
            let text = storage.string as NSString
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value is NSTextAttachment {
                    committedCount += range.length
                } else if pendingIndex == nil,
                          !text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pendingIndex = committedCount
                }
            }
            let pendingCount = represented.count - committedCount
            if pendingIndex == index, pendingCount > 0, index >= 0,
               index <= represented.count, pendingCount <= represented.count - index {
                represented.removeSubrange(index..<(index + pendingCount))
            }
        }
        // AppKit owns insertion at index; never drop an occupied index merely
        // because it is the insertion point, or consult stale session tags.
        var shown = represented.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var accepted: [String] = []
        for case let text as String in tokens {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !TagEditSession.has(name, in: shown) else { continue }
            accepted.append(name)
            shown.append(name)
        }
        session.add(accepted)
        for toggle in toggles { toggle.state = session.state(of: toggle.tag0) }
        return accepted
    }

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                    indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        session.completions(for: substring)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Read after the field finishes tokenising (a new token is added
        // through `shouldAdd`; here only removals count).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyRemovals() }
        }
    }

    func applyRemovals() {
        let shown = (tokenField.objectValue as? [Any] ?? []).compactMap { $0 as? String }
        let removed = session.commonTags.filter { !TagEditSession.has($0, in: shown) }
        guard !removed.isEmpty else { return }
        session.remove(removed)
        for toggle in toggles { toggle.state = session.state(of: toggle.tag0) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return on an empty field closes.
        if selector == #selector(NSResponder.insertNewline(_:)), textView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter({ $0 != "\u{FFFC}" }).isEmpty {
            popover?.performClose(nil)
            return true
        }
        return false
    }
}

/// The Tags popover's content background: the window colour, opaque, so the
/// popover's see-through material never tints the colour dots.
final class OpaquePopoverBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
