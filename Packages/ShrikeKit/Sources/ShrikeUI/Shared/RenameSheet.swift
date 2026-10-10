//
//  RenameSheet.swift
//  ShrikeUI
//
//  The Rename sheet: only the stem is editable, the
//  extension is a fixed label, companions follow the new stem, and the
//  rules are checked on every keystroke through `FileOps.validate`.
//

import AppKit
import ShrikeCore
import ShrikeIO

/// What the sheet shows for a typed stem. Pure — safe for unit tests.
struct RenameSheetModel {

    let group: ImageGroup
    let validate: (String) -> RenameValidation

    var oldStem: String { group.primary.deletingPathExtension().lastPathComponent }
    var fileExtension: String {
        let ext = group.primary.pathExtension
        return ext.isEmpty ? "" : ".\(ext)"
    }
    var title: String { "Rename “\(group.displayName)”" }

    /// "Also renames “DSC_0042.ORF” and “DSC_0042.xmp”." (groups only).
    var companionsLine: String? {
        let names = group.allURLs.dropFirst().map { "“\($0.lastPathComponent)”" }
        guard !names.isEmpty else { return nil }
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "Also renames \(list)."
    }

    struct State: Equatable {
        let message: String?
        let canRename: Bool
    }

    func state(for stem: String) -> State {
        let result = validate(stem)
        return State(message: result.message.map { "⚠ \($0)" }, canRename: result.isValid)
    }
}

/// The sheet window. `run(on:)` returns the new stem, or nil on Cancel.
@MainActor
final class RenameSheet: NSObject, NSTextFieldDelegate {

    private let model: RenameSheetModel
    private let panel: NSPanel
    private let field = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(model: RenameSheetModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                        styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        field.stringValue = model.oldStem
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.setAccessibilityLabel("New name")
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let ext = NSTextField(labelWithString: model.fileExtension)
        ext.font = .systemFont(ofSize: 13)
        ext.textColor = .secondaryLabelColor
        let fieldRow = NSStackView(views: [field, ext])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 4

        var rows: [NSView] = [title, fieldRow]
        if let line = model.companionsLine {
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            rows.append(label)
        }
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        rows.append(errorLabel)

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        renameButton.keyEquivalent = "\r"
        renameButton.bezelColor = .controlAccentColor   // one accent
        renameButton.target = self
        renameButton.action = #selector(rename(_:))
        let buttons = NSStackView(views: [cancelButton, renameButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, buttons])
        buttonRow.orientation = .horizontal
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 420),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
        apply(model.state(for: model.oldStem))
    }

    private func apply(_ state: RenameSheetModel.State) {
        errorLabel.stringValue = state.message ?? ""
        errorLabel.isHidden = state.message == nil
        renameButton.isEnabled = state.canRename
    }

    func controlTextDidChange(_ obj: Notification) {
        apply(model.state(for: field.stringValue))
    }

    private var continuation: CheckedContinuation<String?, Never>?

    func run(on window: NSWindow) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            window.beginSheet(panel) { _ in }
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func finish(_ stem: String?) {
        guard let continuation else { return }
        self.continuation = nil
        panel.sheetParent?.endSheet(panel)
        continuation.resume(returning: stem)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    @objc private func rename(_ sender: Any?) {
        guard model.state(for: field.stringValue).canRename else { return }
        finish(field.stringValue)
    }
}

enum RenameCopy {
    /// T4: "Couldn't rename “DSC_0042.jpg”. (reason)"
    static func failed(_ group: ImageGroup, error: any Error) -> String {
        let base = "Couldn't rename “\(group.displayName)”."
        if let ops = error as? FileOpsError {
            if case .invalidName(let validation) = ops, let message = validation.message {
                return "\(base) \(message)"
            }
            if let reason = FileActionCopy.reason(for: ops) {
                return "\(base) \(reason.prefix(1).uppercased() + reason.dropFirst())."
            }
        }
        return base
    }

    static let selectOne = "Select one item to rename."
}
