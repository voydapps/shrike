//
//  ExternalEditorsTab.swift
//  ShrikeUI
//
//  Settings ▸ External Editors:
//
//    # │ Editor                  │ Keys  │ Send RAW      rows 28 pt, max 9
//    1 │ [icon] Pixelmator Pro   │ ⌥⌘1   │    ☐
//    2 │ Choose App…             │ ⌥⌘2   │
//    [+] [−]                               Drag rows to reorder.
//    Shrike doesn't keep originals for changes made in other apps.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            List(selection: $model.selection) {
                ForEach(Array(model.editors.enumerated()), id: \.element.id) { slot, editor in
                    editorRow(slot: slot, editor: editor).tag(editor.id)
                }
                .onMove { model.move(from: $0, to: $1) }
                ForEach(model.editors.count..<ExternalEditorsModel.slotCount, id: \.self) { slot in
                    emptyRow(slot: slot)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .environment(\.defaultMinListRowHeight, 28)
            .frame(minHeight: 28 * 9 + 8)
            HStack(spacing: 4) {
                Button { chooseApp() } label: { Image(systemName: "plus") }
                    .disabled(model.editors.count >= ExternalEditorsModel.slotCount)
                    .help("Add an app")
                    .accessibilityLabel("Add an app")
                Button { model.removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(model.selection == nil)
                    .help("Remove the selected app")
                    .accessibilityLabel("Remove the selected app")
                Spacer()
                Text("Drag rows to reorder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            Text("Shrike doesn't keep originals for changes made in other apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { model.reload() }
    }

    // MARK: Rows

    private var header: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: 20, alignment: .trailing)
            Text("Editor").frame(maxWidth: .infinity, alignment: .leading)
            Text("Keys").frame(width: 90, alignment: .leading)
            Text("Send RAW").frame(width: 70, alignment: .center)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private func editorRow(slot: Int, editor: ExternalEditor) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(slot + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            HStack(spacing: 6) {
                if let icon = model.icons[editor.id] {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app").frame(width: 18, height: 18).foregroundStyle(.secondary)
                }
                Text(editor.displayName).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(model.keys(forSlot: slot))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { editor.sendRAW },
                set: { model.setSendRAW($0, slot: slot) }
            ))
            .labelsHidden()
            .help("When the photo has a RAW, open the RAW instead of the JPEG.")
            .accessibilityLabel("Send RAW to \(editor.displayName)")
            .frame(width: 70)
        }
        .frame(height: 28)
        .contextMenu {
            Button("Remove") { model.remove(slot: slot) }
        }
        .accessibilityElement(children: .contain)
    }

    private func emptyRow(slot: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(slot + 1)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
            Button("Choose App…") { chooseApp() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(model.keys(forSlot: slot))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            Color.clear.frame(width: 70)
        }
        .frame(height: 28)
    }

    // MARK: Open panel

    /// "+" and "Choose App…": an Open panel in /Applications. The app goes
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
