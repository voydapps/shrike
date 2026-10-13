//
//  ThumbnailsTab.swift
//  ShrikeUI
//
//  Size picker + cache ceiling picker + current-usage readout + destructive
//  "Clear cache" button. Per
//
//  `currentDiskBytes` is re-queried on tab appear (and after "Clear cache").
//  No periodic polling — the number is user-driven and slightly stale is fine.
//

import SwiftUI
import AppKit
import ShrikeCore

struct ThumbnailsTab: View {

    @EnvironmentObject private var store: PreferencesStore
    let thumbnailCache: ThumbnailCache?

    // Specifies 180 pt default + the five-step picker. Keep the set
    // explicit so the UI doesn't drift from the backing key's documented
    // defaults.
    static let sizeOptions: [Int] = [120, 150, 180, 210, 256]
    static let ceilingOptions: [Int64] = [
        128 * 1024 * 1024,
        256 * 1024 * 1024,
        512 * 1024 * 1024,
        1024 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
    ]

    /// Spec 27 P3-6: the default comes from `Prefs`, so the hint and the code cannot disagree.
    static var cellSizeHint: String {
        "Longest edge of a grid cell, in points. The default is \(Prefs.defaultThumbnailSizePt) pt."
    }

    @State private var currentDiskBytes: Int64 = 0
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Cell size", selection: store.thumbnailSizePt) {
                    ForEach(SettingsChoices.including(store.thumbnailSizePt.wrappedValue, in: Self.sizeOptions),
                            id: \.self) { size in
                        Text(verbatim: "\(size) pt").tag(size)
                    }
                }

                Text(Self.cellSizeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Grid").font(.headline)
            }

            Section {
                Picker("Max size", selection: store.cacheDiskCeilingBytes) {
                    ForEach(SettingsChoices.including(store.cacheDiskCeilingBytes.wrappedValue,
                                                      in: Self.ceilingOptions), id: \.self) { bytes in
                        Text(PreferencesByteFormat.string(fromBytes: bytes)).tag(bytes)
                    }
                }

                LabeledContent("Current disk usage",
                               value: currentDiskBytes > 0
                                ? PreferencesByteFormat.string(fromBytes: currentDiskBytes)
                                : "—")

                HStack {
                    Spacer()
                    Button("Clear Cache…", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(thumbnailCache == nil)
                }
            } header: {
                Text("Cache").font(.headline)
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshDiskUsage()
        }
        .onChange(of: store.cacheDiskCeilingBytes.wrappedValue) { _, bytes in
            // Apply the new ceiling now; the usage readout
            // updates after the trim.
            Task { await applyCeiling(bytes) }
        }
        .confirmationDialog(
            "Clear Thumbnail Cache?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await clearCache() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(verbatim: "This will delete \(PreferencesByteFormat.string(fromBytes: currentDiskBytes)) of cached thumbnails and regenerate them as folders are reopened.")
        }
        .safeAreaInset(edge: .bottom) {
            PreferencesResetFooter(
                label: "Reset Thumbnails to Defaults",
                tab: .thumbnails
            )
            .environmentObject(store)
        }
    }

    // MARK: - Actions

    private func refreshDiskUsage() async {
        guard let cache = thumbnailCache else {
            currentDiskBytes = 0
            return
        }
        currentDiskBytes = await cache.currentDiskBytes()
    }

    private func applyCeiling(_ bytes: Int64) async {
        guard let cache = thumbnailCache else { return }
        await cache.setDiskCeiling(bytes: bytes)
        await refreshDiskUsage()
    }

    private func clearCache() async {
        guard let cache = thumbnailCache else { return }
        await cache.clearAll()
        await refreshDiskUsage()
    }
}
