//
//  LiveTooltips.swift
//  ShrikeUI
//
//  Toolbar and edit-bar tooltips that name the live preset's key:
//  "Previous Image  ·  ←". They are rebuilt when
//  the shortcut preset changes.
//

import AppKit
import ShrikeCore

@MainActor
public final class LiveTooltips {

    public static let shared = LiveTooltips()

    private struct Entry {
        weak var view: NSView?
        let command: ShrikeCommand
        let context: ShortcutContext
        let title: String?
    }

    private var entries: [Entry] = []
    private var segmentEntries: [(control: WeakSegmented, segment: Int, command: ShrikeCommand, context: ShortcutContext, title: String?)] = []
    private var itemEntries: [(item: WeakItem, command: ShrikeCommand, context: ShortcutContext, title: String?)] = []
    /// A second tooltip line per view or toolbar item (why a control is off).
    private let extraLines = NSMapTable<AnyObject, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var lastPreset: ShortcutPreset?
    private var observer: (any NSObjectProtocol)?

    private init() {}

    /// Sets `view.toolTip` now and whenever the preset changes. `title`
    /// replaces the command's title (the edit bar's "Cancel" button runs
    /// Exit Edit Mode).
    public func bind(_ view: NSView, command: ShrikeCommand, context: ShortcutContext, title: String? = nil) {
        startObserving()
        view.toolTip = composed(Self.text(command, context: context, preset: Prefs.shortcutPreset, title: title), for: view)
        entries.append(Entry(view: view, command: command, context: context, title: title))
    }

    /// Same for a toolbar item without a view (image items, group parts).
    public func bind(_ item: NSToolbarItem, command: ShrikeCommand, context: ShortcutContext, title: String? = nil) {
        startObserving()
        item.toolTip = composed(Self.text(command, context: context, preset: Prefs.shortcutPreset, title: title), for: item)
        itemEntries.append((WeakItem(item), command, context, title))
    }

    /// Same for one segment of a segmented control.
    public func bind(_ control: NSSegmentedControl, segment: Int, command: ShrikeCommand, context: ShortcutContext,
                     title: String? = nil) {
        startObserving()
        control.setToolTip(Self.text(command, context: context, preset: Prefs.shortcutPreset, title: title),
                           forSegment: segment)
        segmentEntries.append((WeakSegmented(control), segment, command, context, title))
    }

    /// The tooltip is `base + "\n" + line` while a line is set, and just `base`
    /// otherwise. A preset change rewrites the base; the line stays.
    public func setExtraLine(_ line: String?, on view: NSView) {
        setExtra(line, key: view)
        guard let entry = entries.first(where: { $0.view === view }) else { return }
        view.toolTip = composed(Self.text(entry.command, context: entry.context, preset: Prefs.shortcutPreset,
                                          title: entry.title), for: view)
    }

    /// Same for a toolbar item.
    public func setExtraLine(_ line: String?, on item: NSToolbarItem) {
        setExtra(line, key: item)
        guard let entry = itemEntries.first(where: { $0.item.value === item }) else { return }
        item.toolTip = composed(Self.text(entry.command, context: entry.context, preset: Prefs.shortcutPreset,
                                          title: entry.title), for: item)
    }

    private func setExtra(_ line: String?, key: AnyObject) {
        if let line, !line.isEmpty { extraLines.setObject(line as NSString, forKey: key) }
        else { extraLines.removeObject(forKey: key) }
    }

    private func composed(_ base: String, for key: AnyObject) -> String {
        guard let line = extraLines.object(forKey: key) else { return base }
        return base + "\n" + (line as String)
    }

    /// "Title  ·  key" for `preset`, or the title alone when unbound.
    public static func text(_ command: ShrikeCommand, context: ShortcutContext, preset: ShortcutPreset,
                            title: String? = nil) -> String {
        let name = title ?? command.title
        guard let first = ShortcutTable.bindings(for: command, context: context, preset: preset).first else {
            return name
        }
        return "\(name)  ·  \(first.displayString)"
    }

    private func startObserving() {
        guard observer == nil else { return }
        lastPreset = Prefs.shortcutPreset
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LiveTooltips.shared.refreshIfPresetChanged() }
        }
    }

    func refreshIfPresetChanged() {
        let preset = Prefs.shortcutPreset
        guard preset != lastPreset else { return }
        lastPreset = preset
        entries.removeAll { $0.view == nil }
        for entry in entries {
            guard let view = entry.view else { continue }
            view.toolTip = composed(Self.text(entry.command, context: entry.context, preset: preset, title: entry.title), for: view)
        }
        itemEntries.removeAll { $0.item.value == nil }
        for entry in itemEntries {
            guard let item = entry.item.value else { continue }
            item.toolTip = composed(Self.text(entry.command, context: entry.context, preset: preset, title: entry.title), for: item)
        }
        segmentEntries.removeAll { $0.control.value == nil }
        for entry in segmentEntries {
            entry.control.value?.setToolTip(
                Self.text(entry.command, context: entry.context, preset: preset, title: entry.title),
                forSegment: entry.segment
            )
        }
    }

    private final class WeakItem {
        weak var value: NSToolbarItem?
        init(_ value: NSToolbarItem) { self.value = value }
    }

    private final class WeakSegmented {
        weak var value: NSSegmentedControl?
        init(_ value: NSSegmentedControl) { self.value = value }
    }
}
