//
//  ExternalEditorsTab.swift
//  ShrikeUI
//
//  Settings ▸ External Editors:
//
//  A grouped Form (spec 27 V4): one row per configured editor (icon, name,
//  key hint, Send RAW toggle, remove), then "Add Editor…". No placeholder
//  rows; an empty state when nothing is configured.
//
//  It reads and writes `ExternalEditorRegistry` only (the old 3-slot
//  `Prefs.externalEditors` list is imported once by the registry). The
//  keys come from `ShortcutTable` (read-only). App icons load off the
//  main thread when the tab opens; the launch path never reads them.
//

import SwiftUI
import AppKit
import ShrikeCore
import ShrikeIO
import UniformTypeIdentifiers

/// The tab's state: a mirror of the registry plus the loaded icons.
@MainActor
final class ExternalEditorsModel: NSObject, ObservableObject {

    static let slotCount = ExternalEditorRegistry.maxEditors

    @Published private(set) var editors: [ExternalEditor] = []
    @Published private(set) var icons: [ExternalEditor.ID: NSImage] = [:]
    @Published var selection: ExternalEditor.ID?

    let registry: ExternalEditorRegistry

    init(registry: ExternalEditorRegistry = ExternalEditors.registry) {
        self.registry = registry
        super.init()
        editors = registry.editors
        // The registry is main-actor and posts on main.
        NotificationCenter.default.addObserver(
            self, selector: #selector(registryDidChange(_:)),
            name: ExternalEditorRegistry.didChangeNotification, object: registry
        )
    }

    @objc private func registryDidChange(_ note: Notification) { reload() }

    func reload() {
        editors = registry.editors
        if let selection, !editors.contains(where: { $0.id == selection }) { self.selection = nil }
        loadIcons()
    }

    // MARK: Rows

    func editor(inSlot slot: Int) -> ExternalEditor? {
        editors.indices.contains(slot) ? editors[slot] : nil
    }

    /// "⌥⌘1" (Mac) or "⌥⌘1, E" (FastStone): the slot's keys, read-only.
    func keys(forSlot slot: Int) -> String {
        ShortcutTable.displayString(for: ShrikeCommand.externalEditorCommands[slot],
                                    context: .viewer, preset: ShortcutTable.livePreset)
    }

    // MARK: Changes (all go to the registry)

    /// Adds the app at `url`. Returns false for something that is not an
    /// app, or when all 9 slots are full.
    @discardableResult
    func addApplication(at url: URL) -> Bool {
        guard let editor = ExternalEditor.validate(appURL: url) else { return false }
        guard let slot = try? registry.add(editor) else { return false }
        selection = registry.editor(inSlot: slot)?.id
        return true
    }

    func remove(slot: Int) {
        guard let editor = editor(inSlot: slot) else { return }
        registry.remove(id: editor.id)
    }

    func removeSelected() {
        guard let selection, let slot = registry.slot(of: selection) else { return }
        remove(slot: slot)
    }

    /// SwiftUI `onMove` → the registry's slot move.
    func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let to = destination > from ? destination - 1 : destination
        registry.move(fromSlot: from, toSlot: to)
    }

    func setSendRAW(_ on: Bool, slot: Int) {
        guard let editor = editor(inSlot: slot) else { return }
        registry.setSendRAW(on, for: editor.id)
    }

    // MARK: Icons (off the main thread)

    private var iconTask: Task<Void, Never>?

    func loadIcons() {
        let missing = editors.filter { icons[$0.id] == nil }
            .map { (id: $0.id, url: $0.applicationURL, bundle: $0.bundleIdentifier) }
        guard !missing.isEmpty else { return }
        iconTask?.cancel()
        iconTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [ExternalEditor.ID: NSImage] in
                var out: [ExternalEditor.ID: NSImage] = [:]
                let workspace = NSWorkspace.shared
                for entry in missing {
                    let url = entry.bundle.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
                        ?? entry.url
                    guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
                    out[entry.id] = workspace.icon(forFile: url.path)
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            self.icons.merge(loaded) { _, new in new }
        }
    }
}

struct ExternalEditorsTab: View {

    @StateObject private var model = ExternalEditorsModel()

    // MARK: Layout facts (spec 27 V4; pure, so tests can pin them)

    /// What the tab shows for `count` configured editors.
    struct Layout: Equatable {
        /// One row per configured editor, no placeholder slots.
        var editorRows: Int
        var showsEmptyState: Bool
        var addEnabled: Bool
    }

    static func layout(editorCount count: Int) -> Layout {
        Layout(editorRows: count, showsEmptyState: count == 0,
               addEnabled: count < ExternalEditorsModel.slotCount)
    }

    static let rowHeight: CGFloat = 36
    static let iconSize: CGFloat = 20
    static let addTitle = "Add Editor…"
    static let addDisabledHelp = "Up to 9 editors."
    static let footer = "Keys open the displayed photo in that editor. Send RAW files opens the RAW instead of the JPEG for a pair."

    /// "No editors yet. Add an app to open photos in it with ⌥⌘1." The key is slot 1's live key.
    static func emptyStateText(firstKey: String) -> String {
        "No editors yet. Add an app to open photos in it with \(firstKey)."
    }

    static func sendRAWLabel(_ name: String) -> String { "Send RAW to \(name)" }
    static func removeLabel(_ name: String) -> String { "Remove \(name)" }

    var body: some View {
        let layout = Self.layout(editorCount: model.editors.count)
        Form {
            Section {
                if layout.showsEmptyState {
                    VStack(spacing: 10) {
                        Text(Self.emptyStateText(firstKey: model.keys(forSlot: 0)))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        addButton(enabled: layout.addEnabled)
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                } else {
                    ForEach(Array(model.editors.enumerated()), id: \.element.id) { slot, editor in
                        editorRow(slot: slot, editor: editor)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                    HStack {
                        addButton(enabled: layout.addEnabled)
                        Spacer()
                    }
                    .frame(minHeight: Self.rowHeight)
                }
            } header: {
                Text("External editors").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.footer)
                    Text("Shrike doesn't keep originals for changes made in other apps.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
    }

    // MARK: Rows

    private func addButton(enabled: Bool) -> some View {
        Button(Self.addTitle) { chooseApp() }
            .disabled(!enabled)
            .help(enabled ? "" : Self.addDisabledHelp)
            .accessibilityLabel(Self.addTitle)
    }

    private func editorRow(slot: Int, editor: ExternalEditor) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = model.icons[editor.id] {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app").foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            Text(editor.displayName)
                .font(.system(size: 13))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(model.keys(forSlot: slot))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { editor.sendRAW },
                set: { model.setSendRAW($0, slot: slot) }
            ))
            .labelsHidden()
            .help("When the photo has a RAW, open the RAW instead of the JPEG.")
            .accessibilityLabel(Self.sendRAWLabel(editor.displayName))
            Button { model.remove(slot: slot) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(Self.removeLabel(editor.displayName))
                .accessibilityLabel(Self.removeLabel(editor.displayName))
        }
        .frame(minHeight: Self.rowHeight)
        .contextMenu {
            Button("Remove") { model.remove(slot: slot) }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Open panel

    /// "Add Editor…": an Open panel in /Applications. The app goes
    /// into the first free slot (the list has no gaps).
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addApplication(at: url)
    }
}
