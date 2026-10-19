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
        model.requestSearchFocus()
        focusSearchField()
        // The hosting view may build its text field a tick later.
        DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    }

    /// Audit 2026-10-13 (0.2.9): the SwiftUI `@FocusState` alone left the caret
    /// drawn but typing went nowhere until a click. Put the real field in the
    /// responder chain by hand, every time the window opens or becomes key.
    func focusSearchField() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let field = Self.firstEditableTextField(in: content) else { return }
        if let editor = window.firstResponder as? NSText, editor.delegate === field { return }
        window.makeFirstResponder(field)
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let hit = firstEditableTextField(in: sub) { return hit } }
        return nil
    }

    func windowWillClose(_ notification: Notification) { model.query = "" }

    /// Spec 27 P3-10 (regression vs spec 25 §13.2): the search field is focused
    /// when the window opens. `onAppear` runs before the hosting view is in a
    /// key window, so focus is asked for again once the window is key.
    func windowDidBecomeKey(_ notification: Notification) {
        model.requestSearchFocus()
        focusSearchField()
    }

    var modelForTesting: ShortcutsWindowModel { model }
}

@MainActor
final class ShortcutsWindowModel: ObservableObject {
    @Published var query = ""
    /// Bumped to ask the view to focus its search field.
    @Published private(set) var focusTick = 0
    func requestSearchFocus() { focusTick &+= 1 }
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

    /// One list row. The id carries the section: "Zoom In" exists in Viewer,
    /// Edit Mode and Compare, and rows keyed by the action alone were mixed up
    /// by the list when the filter changed (0.2.9 showed Compare's bare "+, =,
    /// ⇧+" in the Viewer rows).
    struct ListRow: Identifiable, Equatable {
        let id: String
        let action: String
        let keys: String
    }
    var listSections: [(title: String, rows: [ListRow])] {
        sections.map { section in
            (section.title, section.rows.map {
                ListRow(id: "\(section.title)/\($0.action)", action: $0.action, keys: $0.keys)
            })
        }
    }
}

private struct ShortcutsWindowView: View {
    @ObservedObject var model: ShortcutsWindowModel
    let onSettings: () -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var typography = ShortcutsWindowTypography.current

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
                    Text(model.presetLine).font(.system(size: typography.keysSize)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Settings…", action: onSettings).buttonStyle(.link)
                }
            }
            .padding(16)
            Divider()
            if model.sections.isEmpty {
                Spacer()
                Text(verbatim: "No shortcuts match “\(model.query)”.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.listSections, id: \.title) { section in
                            ShortcutsWindowSection(title: section.title, rows: section.rows,
                                                   typography: typography)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .focusable()
                .accessibilityLabel("Keyboard shortcuts")
                .accessibilityIdentifier("shortcuts.results")
            }
        }
        // Typography is an explicit input to every stable section and row;
        // cached ForEach content must not read a changing global preference.
        .onReceive(NotificationCenter.default.publisher(for: .shrikeChromePreferencesChanged)) { _ in
            typography = .current
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { _, _ in searchFocused = true }
        .onExitCommand { if model.query.isEmpty { onClose() } else { model.query = "" } }
        .background(Button("") { searchFocused = true; model.requestSearchFocus() }.keyboardShortcut("f").opacity(0))
        .background(Button("") { onClose() }.keyboardShortcut("w").opacity(0))
    }
}


private struct ShortcutsWindowTypography: Equatable {
    let actionSize: CGFloat
    let keysSize: CGFloat
    let rowHeight: CGFloat

    static var current: Self {
        Self(actionSize: ChromeTypography.size(13), keysSize: ChromeTypography.size(12),
             rowHeight: ChromeTypography.targetHeight)
    }
}

private struct ShortcutsWindowSection: View {
    let title: String
    let rows: [ShortcutsWindowModel.ListRow]
    let typography: ShortcutsWindowTypography

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: typography.actionSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    ShortcutsWindowRow(row: row, typography: typography)
                }
            }
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutsWindowRow: View {
    let row: ShortcutsWindowModel.ListRow
    let typography: ShortcutsWindowTypography

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.action)
                .font(.system(size: typography.actionSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.keys)
                .font(.system(size: typography.keysSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(minHeight: typography.rowHeight)
        .accessibilityElement(children: .combine)
    }
}
