//
//  EditingTab.swift
//  ShrikeUI
//
//  Settings › Editing: save quality, metadata, how long
//  originals are kept, and the rotation note.
//

import SwiftUI
import AppKit
import ShrikeCore
import ShrikeIO

struct EditingTab: View {

    @EnvironmentObject private var store: PreferencesStore

    /// Nil in tests and previews: the size line reads "—" and Show in
    /// Finder is disabled.
    let backupStore: BackupStore?

    static let retentionOptions: [Int] = [7, 30, 90]

    @State private var backupBytes: Int64?
    @State private var backupOverCap = false
    /// The storage limit; read when the tab is built.
    private var backupLimit: Int64 { Prefs.backupMaxBytes }
    @State private var isDeleting = false

    /// The confirmation for "Delete All Backups…". Cancel is the default: Return
    /// and Esc keep the backups. Only Shrike's own backup copies go, never the photos.
    struct DeleteAllCopy: Equatable {
        let message: String
        let information: String
        let deleteTitle: String
        init(bytes: Int64) {
            let size = PreferencesByteFormat.string(fromBytes: bytes)
            message = "Delete all backups?"
            information = "This frees \(size). Your photos are not changed. After this, Revert to Original and Undo can no longer bring back earlier versions of photos you edited. You can't undo this."
            deleteTitle = "Delete All Backups"
        }
    }

    var body: some View {
        Form {
            Section {
                QualityRow(title: "JPEG quality", value: store.editJPEGQuality)
                QualityRow(title: "HEIC quality", value: store.editHEICQuality)
                Toggle("Keep metadata when saving", isOn: store.editPreserveEXIFOnSave)
                Toggle("Remove location when saving", isOn: store.editStripGPSOnSave)
                Text("Some edits use 8-bit color. If that would lose detail, use Save Copy… to keep the original.")
                    .font(.system(size: ChromeTypography.size(12))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Saving").font(.headline)
            }

            Section {
                Picker("Keep older backups for", selection: store.backupRetentionDays) {
                    ForEach(SettingsChoices.including(store.backupRetentionDays.wrappedValue,
                                                      in: Self.retentionOptions), id: \.self) { days in
                        Text(verbatim: "\(days) days").tag(days)
                    }
                }
                Text(Self.helpText(limit: backupLimit))
                    .font(.system(size: ChromeTypography.size(12))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.usageLine(bytes: backupBytes, limit: backupLimit))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { showInFinder() }
                        .disabled(backupStore == nil)
                        .padding(.trailing, 8)   // with the stack's 8: a 16 pt gap
                    Button("Delete All Backups…", role: .destructive) { confirmDeleteAll() }
                        .foregroundStyle(.red)
                        .disabled(backupStore == nil || (backupBytes ?? 0) == 0 || isDeleting)
                }
                if backupOverCap, let line = Self.overLimitLine(limit: backupLimit) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .accessibilityHidden(true)
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: ChromeTypography.size(12)))
                }
            } header: {
                Text("Backups").font(.headline)
            }

            Section {
                Text("JPEG, HEIC, TIFF and PNG rotate without quality loss. Other file types rotate for viewing only.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Rotation").font(.headline)
            }
        }
        .formStyle(.grouped)
        .task {
            // Size computed when the tab opens, off the main thread (the
            // store is an actor).
            guard let backupStore else { return }
            let usage = await backupStore.usage()
            backupBytes = usage.usedBytes
            backupOverCap = usage.isOverCap
        }
        .preferencesResetFooter("Reset Editing to Defaults", tab: .editing)
    }

    /// "Backups use 111 MB of 10 GB."; no limit set: the old line.
    static func usageLine(bytes: Int64?, limit: Int64) -> String {
        let used = bytes.map { PreferencesByteFormat.string(fromBytes: $0) } ?? "—"
        guard limit > 0 else { return "Backups use \(used)." }
        return "Backups use \(used) of \(PreferencesByteFormat.string(fromBytes: limit))."
    }

    static func helpText(limit: Int64) -> String {
        let lead = "The original backup is kept while the original file remains at its recorded location, or while its disk is not connected. Older versions and backups of deleted files can be removed after this period "
        guard limit > 0 else { return lead + "or to meet the storage limit." }
        return lead + "or when backups use more than \(PreferencesByteFormat.string(fromBytes: limit))."
    }

    /// Shown when the store is over its limit (it can stay there: originals of photos that still exist are kept).
    static func overLimitLine(limit: Int64) -> String? {
        guard limit > 0 else { return nil }
        return "Over the \(PreferencesByteFormat.string(fromBytes: limit)) limit. The rest are backups of photos that still exist, so Shrike keeps them."
    }

    private func confirmDeleteAll() {
        guard let backupStore, let bytes = backupBytes, bytes > 0 else { return }
        let copy = DeleteAllCopy(bytes: bytes)
        isDeleting = true
        Task { @MainActor in
            let choice = await ShrikeAlert.run(
                message: copy.message, information: copy.information,
                buttons: [ShrikeAlert.Button(copy.deleteTitle, role: .destructive), .safeCancel()],
                on: NSApp?.keyWindow)
            if choice == 0 {
                _ = await backupStore.deleteAll()
                // Size and over-limit state from one read, or the "Over the … limit" line stays.
                let usage = await backupStore.usage()
                backupBytes = usage.usedBytes
                backupOverCap = usage.isOverCap
            }
            isDeleting = false
        }
    }

    private func showInFinder() {
        guard let root = backupStore?.root else { return }
        if FileManager.default.fileExists(atPath: root.path) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([root.deletingLastPathComponent()])
        }
    }
}

/// Slider 60–100, step 1, with a value field.
private struct QualityRow: View {
    let title: String
    let value: Binding<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { Double(value.wrappedValue) },
                                   set: { value.wrappedValue = Int($0.rounded()) }),
                    in: 60...100, step: 1
                )
                .accessibilityLabel(title)
                // A read-out, not a field. A text field took
                // the first focus and showed its number selected.
                Text(verbatim: "\(value.wrappedValue)")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityLabel("\(title) value")
            }
        }
    }
}
