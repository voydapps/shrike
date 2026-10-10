//
//  GoToFolderSheet.swift
//  ShrikeUI
//
//  Go ▸ Go to Folder… ⇧⌘G: a 420 pt sheet with one path
//  field. Tab completes the path like Finder (the longest common prefix
//  of the matching folder names). Go opens the folder; a file path opens
//  its folder with the file selected; anything else says "There's no
//  folder at this path." and the sheet stays open. The field remembers
//  the last path, in memory only. Every disk read runs off the main
//  thread.
//

import AppKit
import ShrikeCore

/// Where a typed path leads.
public enum GoToFolderTarget: Equatable, Sendable {
    case folder(URL)
    /// A file: show `folder` with `file` selected.
    case file(folder: URL, file: URL)

    public var folder: URL {
        switch self {
        case .folder(let url): return url
        case .file(let folder, _): return folder
        }
    }

    public var selecting: URL? {
        if case .file(_, let file) = self { return file }
        return nil
    }
}

/// The path rules. Pure apart from the disk reads, which are async and
/// run off the main thread.
public enum GoToFolder {

    public static let label = "Go to the folder:"
    public static let placeholder = "~/Pictures"
    public static let noFolderMessage = "There's no folder at this path."

    /// The last path typed in the sheet (memory only).
    @MainActor public static var lastPath = ""

    /// `~` and `~/…` expanded; a relative path is taken from `base` (the
    /// window's folder), or from Home when there is none.
    nonisolated static func expand(_ typed: String, base: URL?) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tilde = (trimmed as NSString).expandingTildeInPath
        if tilde.hasPrefix("/") { return tilde }
        let root = base?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        return (root as NSString).appendingPathComponent(tilde)
    }

    /// Resolves `typed` (off main): a folder, a file in a folder, or nil.
    nonisolated public static func resolve(_ typed: String, base: URL? = nil) async -> GoToFolderTarget? {
        let path = expand(typed, base: base)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return .folder(URL(fileURLWithPath: url.path, isDirectory: true))
        }
        return .file(folder: url.deletingLastPathComponent(), file: url)
    }

    /// Tab completion (off main): lists only the parent folder's
    /// subfolders. One match gives "…/Name/"; several give the longest
    /// common prefix of their names; nil when nothing matches or the
    /// text would not grow.
    nonisolated public static func complete(_ typed: String, base: URL? = nil) async -> String? {
        let text = typed
        let parentText: String
        let prefix: String
        if let slash = text.lastIndex(of: "/") {
            parentText = String(text[...slash])
            prefix = String(text[text.index(after: slash)...])
        } else if text == "~" {
            return "~/"
        } else {
            parentText = ""
            prefix = text
        }
        let parentPath = parentText.isEmpty
            ? (base?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
            : expand(parentText, base: base)
        guard !parentPath.isEmpty else { return nil }
        let names = subfolderNames(of: URL(fileURLWithPath: parentPath, isDirectory: true),
                                   showHidden: prefix.hasPrefix("."))
        let matches = names.filter { $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return parentText + first + "/" }
        let common = longestCommonPrefix(matches)
        guard common.count > prefix.count else { return nil }
        return parentText + common
    }

    /// Folder names in `folder` (packages such as `.app` or
    /// `.photoslibrary` are not folders here). Reads one level only.
    nonisolated static func subfolderNames(of folder: URL, showHidden: Bool) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: options) else { return [] }
        return children.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true else { return nil }
            return url.lastPathComponent
        }
    }

    /// Longest common prefix, compared without case; the letters come
    /// from the first name.
    nonisolated static func longestCommonPrefix(_ names: [String]) -> String {
        guard var common = names.first.map(Array.init) else { return "" }
        for name in names.dropFirst() {
            let chars = Array(name)
            var n = 0
            while n < common.count, n < chars.count,
                  String(common[n]).caseInsensitiveCompare(String(chars[n])) == .orderedSame {
                n += 1
            }
            common = Array(common.prefix(n))
        }
        return String(common)
    }
}

/// The sheet. `run(on:)` returns where to go, or nil on Cancel.
@MainActor
final class GoToFolderSheet: NSObject, NSTextFieldDelegate {

    static let width: CGFloat = 420

    let panel: NSPanel
    private let base: URL?
    private let field = NSTextField()
    private let errorLabel = NSTextField(labelWithString: GoToFolder.noFolderMessage)
    private let goButton = NSButton(title: "Go", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var continuation: CheckedContinuation<GoToFolderTarget?, Never>?
    /// The Go / Tab read in flight (tests await it).
    private(set) var pendingTask: Task<Void, Never>?

    /// `base`: the folder a relative path starts from.
    init(base: URL?, initialPath: String = GoToFolder.lastPath) {
        self.base = base
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        super.init()
        build(initialPath)
    }

    private func build(_ initialPath: String) {
        let label = NSTextField(labelWithString: GoToFolder.label)
        label.font = .systemFont(ofSize: 13)

        field.stringValue = initialPath
        field.placeholderString = GoToFolder.placeholder
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Folder path")
        field.setAccessibilityHelp("Type a folder path. Press Tab to complete a folder name.")

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        goButton.keyEquivalent = "\r"
        goButton.bezelColor = .controlAccentColor   // one accent
        goButton.target = self
        goButton.action = #selector(go(_:))
        let buttons = NSStackView(views: [cancelButton, goButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, buttons])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [label, field, errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
        updateGoButton()
    }

    private var typedPath: String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateGoButton() {
        goButton.isEnabled = !typedPath.isEmpty
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) {
        errorLabel.isHidden = true
        updateGoButton()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertTab(_:)) else { return false }
        guard !field.stringValue.isEmpty else { return false }   // Tab moves on
        completePath()
        return true
    }

    /// Tab: fills in the longest common prefix of the matching folders.
    func completePath() {
        let typed = field.stringValue
        let base = self.base
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            let completed = await GoToFolder.complete(typed, base: base)
            guard let self, !Task.isCancelled, self.field.stringValue == typed else { return }
            guard let completed else {
                NSSound.beep()
                return
            }
            self.field.stringValue = completed
            if let editor = self.field.currentEditor() {
                editor.selectedRange = NSRange(location: (completed as NSString).length, length: 0)
            }
            self.errorLabel.isHidden = true
            self.updateGoButton()
        }
    }

    // MARK: Run

    func run(on window: NSWindow) async -> GoToFolderTarget? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            window.beginSheet(panel) { _ in }
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func finish(_ target: GoToFolderTarget?) {
        pendingTask?.cancel()
        pendingTask = nil
        guard let continuation else { return }
        self.continuation = nil
        panel.sheetParent?.endSheet(panel)
        continuation.resume(returning: target)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    @objc private func go(_ sender: Any?) {
        let typed = typedPath
        guard !typed.isEmpty else { return }
        GoToFolder.lastPath = field.stringValue
        let base = self.base
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            let target = await GoToFolder.resolve(typed, base: base)
            guard let self, !Task.isCancelled else { return }
            guard let target else {
                self.errorLabel.isHidden = false
                NSAccessibility.post(element: self.errorLabel, notification: .announcementRequested,
                                     userInfo: [.announcement: GoToFolder.noFolderMessage,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
                return
            }
            self.finish(target)
        }
    }

    // MARK: Test seams

    var fieldForTesting: NSTextField { field }
    var goButtonForTesting: NSButton { goButton }
    var cancelButtonForTesting: NSButton { cancelButton }
    var errorLabelForTesting: NSTextField { errorLabel }
    var isRunningForTesting: Bool { continuation != nil }
    func typeForTesting(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    func goForTesting() { go(nil) }
    func cancelForTesting() { cancel(nil) }
}
