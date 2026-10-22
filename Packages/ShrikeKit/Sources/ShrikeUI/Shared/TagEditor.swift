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
//  Tags are extended attributes: each write is one small `setxattr` per
//  file, done on the main actor so the order of writes always follows the
//  order of clicks.
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
    let before: [URL: [String]]
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
         suppressing: (any FolderChangeSuppressing)? = nil) {
        self.suppressing = suppressing
        self.groups = groups
        self.colorTags = colorTags ?? FinderTags.knownTags()
        self.undoManager = undoManager
        self.onChange = onChange
        self.onError = onError
        var tags: [URL: [String]] = [:]
        for url in Culling.imageURLs(of: groups) { tags[url] = FinderTags.read(url) }
        before = tags
        ledger = TagLedger(tags)
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

/// A 20 pt tag colour circle: filled when on, half-filled when some items
/// have it, a 2 pt `labelColor` ring when set. VoiceOver: a
/// checkbox "Red tag".
final class TagColorToggle: NSButton {

    let tag0: FinderTag

    init(tag: FinderTag) {
        self.tag0 = tag
        super.init(frame: NSRect(x: 0, y: 0, width: ChromeTypography.targetHeight, height: ChromeTypography.targetHeight))
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        allowsMixedState = true
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(tag.name) tag")
        toolTip = tag.name
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ChromeTypography.scaled(widthAnchor.constraint(equalToConstant: 28), normal: 28, large: 32),
            ChromeTypography.scaled(heightAnchor.constraint(equalToConstant: 28), normal: 28, large: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = tag0.color.nsColor ?? .systemGray
        let circle = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        let path = NSBezierPath(ovalIn: circle)
        color.withAlphaComponent(0.25).setFill()
        path.fill()
        switch state {
        case .on:
            color.setFill()
            path.fill()
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        case .mixed:
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: circle.minX, y: circle.minY,
                                      width: circle.width / 2, height: circle.height)).addClip()
            color.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        default:
            break
        }
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func accessibilityValue() -> Any? {
        switch state {
        case .on: return 1
        case .mixed: return 2
        default: return 0
        }
    }
}

// MARK: - Popover

@MainActor
final class TagsPopoverController: NSViewController, NSTokenFieldDelegate, NSPopoverDelegate {

    let session: TagEditSession
    private(set) var toggles: [TagColorToggle] = []
    let tokenField = NSTokenField()
    // Strong while shown; released in `popoverDidClose`.
    private var popover: NSPopover?

    init(session: TagEditSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
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
        root.addSubview(row)
        root.addSubview(tokenField)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tokenField.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 12),
            tokenField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tokenField.widthAnchor.constraint(equalToConstant: 260),
            tokenField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = root
        syncFromSession()
    }

    /// Shows the popover next to `anchor` (the pill, the selected cell).
    func present(relativeTo rect: NSRect, of anchor: NSView, edge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = self
        popover.delegate = self
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
        for toggle in toggles { toggle.state = session.state(of: toggle.tag0) }
        tokenField.objectValue = session.commonTags
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
