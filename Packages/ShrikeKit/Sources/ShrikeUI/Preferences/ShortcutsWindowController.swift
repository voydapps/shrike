//
//  ShortcutsWindowController.swift
//  ShrikeUI
//
//  Help ▸ Keyboard Shortcuts (⌘/): a searchable, non-modal window with
//  every key of the live preset (spec 25 §13.2). The rows come from
//  `ShortcutsTab.sections(for:)`, so the list cannot drift from the keymaps.
//

import AppKit
import SwiftUI
import ShrikeCore

/// The filter of the window: case- and diacritic-insensitive "contains" on
/// the command title, the key text and the section title.
enum ShortcutsFilter {

    static func filter(_ sections: [ShortcutsTab.SectionModel], query: String) -> [ShortcutsTab.SectionModel] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sections }
        func matches(_ text: String) -> Bool {
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return sections.compactMap { section in
            let sectionHit = matches(section.title)
            let rows = section.rows.filter { sectionHit || matches($0.action) || matches($0.keys) }
            return rows.isEmpty ? nil : ShortcutsTab.SectionModel(title: section.title, rows: rows)
        }
    }
}

@MainActor
final class ShortcutsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = ShortcutsWindowController()
    static let autosaveName = "shrike.shortcutsWindow"

    /// Opens Settings ▸ Shortcuts (set by the app).
    var openSettings: (() -> Void)?
    private let model = ShortcutsWindowModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Keyboard Shortcuts"
        window.minSize = NSSize(width: 400, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShortcutsWindowView(model: model, onSettings: { [weak self] in
            self?.openSettings?()
        }, onClose: { [weak self] in self?.window?.close() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isOpen: Bool { window?.isVisible == true }

    /// ⌘/: opens or focuses; closes when it is already the key window.
    func toggle() {
        if window?.isKeyWindow == true { window?.close(); return }
        show()
    }

    func show() {
        model.refresh()
        if window?.isVisible != true, !(window?.setFrameUsingName(Self.autosaveName) ?? false) {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.query = "" }

    var modelForTesting: ShortcutsWindowModel { model }
}

@MainActor
final class ShortcutsWindowModel: ObservableObject {
    @Published var query = ""
    @Published var preset: ShortcutPreset = Prefs.shortcutPreset
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        let live = Prefs.shortcutPreset
        if live != preset { preset = live }
    }

    var presetLine: String { preset == .macNative ? "Mac preset" : "FastStone preset" }
    var sections: [ShortcutsTab.SectionModel] {
        ShortcutsFilter.filter(ShortcutsTab.sections(for: preset), query: query)
    }
}

private struct ShortcutsWindowView: View {
    @ObservedObject var model: ShortcutsWindowModel
    let onSettings: () -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search shortcuts", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("Search shortcuts")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                HStack {
                    Text(model.presetLine).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Settings…", action: onSettings).buttonStyle(.link)
                }
            }
            .padding(16)
            Divider()
            if model.sections.isEmpty {
                Spacer()
                Text(verbatim: "No shortcuts match “\(model.query)”.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(model.sections, id: \.title) { section in
                        Section {
                            ForEach(section.rows, id: \.action) { row in
                                HStack {
                                    Text(row.action).font(.system(size: 13))
                                    Spacer()
                                    Text(row.keys).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(height: 28)
                                .accessibilityElement(children: .combine)
                            }
                        } header: {
                            Text(section.title).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
            }
        }
        .onAppear { searchFocused = true }
        .onExitCommand { if model.query.isEmpty { onClose() } else { model.query = "" } }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0))
        .background(Button("") { onClose() }.keyboardShortcut("w").opacity(0))
    }
}
