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
    @State private var isDeleting = false

    /// The confirmation for "Delete All Backups…" (FS-11). Cancel is the default: Return
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
                Text("Some basic edits use 8-bit colour. When conversion is needed, Save Copy… protects the higher-precision original.")
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
                Text("The original backup is kept while the original file remains at its recorded location, or while its disk is not connected. Older versions and backups of deleted files can be removed after this period or to meet the storage limit.")
                    .font(.system(size: ChromeTypography.size(12))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.usageLine(bytes: backupBytes))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { showInFinder() }
                        .disabled(backupStore == nil)
                    Button("Delete All Backups…") { confirmDeleteAll() }
                        .disabled(backupStore == nil || (backupBytes ?? 0) == 0 || isDeleting)
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
            backupBytes = await backupStore.totalBytes()
        }
        .preferencesResetFooter("Reset Editing to Defaults", tab: .editing)
    }

    static func usageLine(bytes: Int64?) -> String {
        guard let bytes else { return "Backups use —." }
        return "Backups use \(PreferencesByteFormat.string(fromBytes: bytes))."
    }

    private func confirmDeleteAll() {
        guard let backupStore, let bytes = backupBytes, bytes > 0 else { return }
        let copy = DeleteAllCopy(bytes: bytes)
        isDeleting = true
        Task { @MainActor in
            let choice = await ShrikeAlert.run(
                message: copy.message, information: copy.information,
                buttons: [ShrikeAlert.Button(copy.deleteTitle, role: .destructive), .safeCancel()],
                on: NSApp.keyWindow)
            if choice == 0 {
                _ = await backupStore.deleteAll()
                backupBytes = await backupStore.totalBytes()
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
